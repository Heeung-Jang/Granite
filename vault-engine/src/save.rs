use std::fmt;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::SystemTime;

use crate::paths::{FileIdentity, PathError, VaultRoot};

const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveBaseline {
    pub relative_path: String,
    pub file_identity: FileIdentity,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub content_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveRequest<'a> {
    pub baseline: &'a SaveBaseline,
    pub contents: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveOutcome {
    pub baseline: SaveBaseline,
    pub bytes_written: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveConflict {
    pub relative_path: String,
    pub kind: SaveConflictKind,
    pub expected: SaveBaseline,
    pub actual: Option<SaveConflictSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveConflictSnapshot {
    pub file_identity: FileIdentity,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub content_hash: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveConflictKind {
    Deleted,
    FileIdentityChanged,
    ContentChanged,
    MetadataChanged,
    SymlinkChanged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveIoOperation {
    CreateTemp,
    WriteTemp,
    SetTempPermissions,
    SyncTemp,
    RenameTemp,
    SyncParent,
    ReadFile,
    ReadMetadata,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SafeSaveError {
    Path(PathError),
    Conflict(Box<SaveConflict>),
    ReadOnly {
        relative_path: String,
    },
    NotRegularFile {
        relative_path: String,
    },
    Io {
        operation: SaveIoOperation,
        path: PathBuf,
        kind: std::io::ErrorKind,
    },
}

pub type SafeSaveResult<T> = Result<T, SafeSaveError>;

#[derive(Debug, Clone)]
struct FileSnapshot {
    baseline: SaveBaseline,
    absolute_path: PathBuf,
    permissions: fs::Permissions,
    readonly: bool,
}

impl SaveBaseline {
    pub fn capture(root: &VaultRoot, relative_path: &str) -> SafeSaveResult<Self> {
        Ok(capture_snapshot(root, relative_path)?.baseline)
    }
}

impl<'a> SaveRequest<'a> {
    pub fn new(baseline: &'a SaveBaseline, contents: &'a [u8]) -> Self {
        Self { baseline, contents }
    }
}

pub fn safe_save(root: &VaultRoot, request: SaveRequest<'_>) -> SafeSaveResult<SaveOutcome> {
    let current = current_snapshot(root, request.baseline)?;
    ensure_baseline_matches(request.baseline, &current)?;

    if current.readonly {
        return Err(SafeSaveError::ReadOnly {
            relative_path: request.baseline.relative_path.clone(),
        });
    }

    let temp_path = write_temp_file(&current, request.contents)?;
    let display_path = Path::new(&current.baseline.relative_path);
    rename_temp_file(&temp_path, &current.absolute_path, display_path)?;
    sync_parent(&current.absolute_path, display_path)?;

    let baseline = SaveBaseline::capture(root, &request.baseline.relative_path)?;
    Ok(SaveOutcome {
        baseline,
        bytes_written: request.contents.len() as u64,
    })
}

fn capture_snapshot(root: &VaultRoot, relative_path: &str) -> SafeSaveResult<FileSnapshot> {
    let resolved = root
        .resolve_existing_relative(relative_path)
        .map_err(SafeSaveError::Path)?;

    let symlink_metadata =
        fs::symlink_metadata(&resolved.absolute_path).map_err(|error| SafeSaveError::Io {
            operation: SaveIoOperation::ReadMetadata,
            path: resolved.relative_path.clone(),
            kind: error.kind(),
        })?;
    if symlink_metadata.file_type().is_symlink() {
        return Err(SafeSaveError::NotRegularFile {
            relative_path: relative_path_string(&resolved.relative_path),
        });
    }

    let metadata = fs::metadata(&resolved.canonical_path).map_err(|error| SafeSaveError::Io {
        operation: SaveIoOperation::ReadMetadata,
        path: resolved.relative_path.clone(),
        kind: error.kind(),
    })?;
    if !metadata.is_file() {
        return Err(SafeSaveError::NotRegularFile {
            relative_path: relative_path_string(&resolved.relative_path),
        });
    }

    let contents = fs::read(&resolved.canonical_path).map_err(|error| SafeSaveError::Io {
        operation: SaveIoOperation::ReadFile,
        path: resolved.relative_path.clone(),
        kind: error.kind(),
    })?;
    let relative_path = relative_path_string(&resolved.relative_path);
    let permissions = metadata.permissions();
    let readonly = permissions.readonly();

    Ok(FileSnapshot {
        baseline: SaveBaseline {
            relative_path,
            file_identity: resolved.file_identity,
            size_bytes: metadata.len(),
            modified: metadata.modified().ok(),
            content_hash: stable_content_hash(&contents),
        },
        absolute_path: resolved.absolute_path,
        permissions,
        readonly,
    })
}

fn current_snapshot(root: &VaultRoot, expected: &SaveBaseline) -> SafeSaveResult<FileSnapshot> {
    match capture_snapshot(root, &expected.relative_path) {
        Ok(snapshot) => Ok(snapshot),
        Err(SafeSaveError::Path(PathError::MissingPath(_))) => {
            Err(conflict(expected, SaveConflictKind::Deleted, None))
        }
        Err(SafeSaveError::Path(PathError::SymlinkEscape { .. }))
        | Err(SafeSaveError::NotRegularFile { .. }) => {
            Err(conflict(expected, SaveConflictKind::SymlinkChanged, None))
        }
        Err(error) => Err(error),
    }
}

fn ensure_baseline_matches(expected: &SaveBaseline, current: &FileSnapshot) -> SafeSaveResult<()> {
    let actual = SaveConflictSnapshot::from(&current.baseline);

    if expected.file_identity != current.baseline.file_identity {
        return Err(conflict(
            expected,
            SaveConflictKind::FileIdentityChanged,
            Some(actual),
        ));
    }

    if expected.content_hash != current.baseline.content_hash {
        return Err(conflict(
            expected,
            SaveConflictKind::ContentChanged,
            Some(actual),
        ));
    }

    if expected.size_bytes != current.baseline.size_bytes
        || expected.modified != current.baseline.modified
    {
        return Err(conflict(
            expected,
            SaveConflictKind::MetadataChanged,
            Some(actual),
        ));
    }

    Ok(())
}

fn write_temp_file(snapshot: &FileSnapshot, contents: &[u8]) -> SafeSaveResult<PathBuf> {
    let temp_path = temp_path_for(&snapshot.absolute_path);
    let display_path = Path::new(&snapshot.baseline.relative_path);
    let mut temp = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_path)
        .map_err(|error| io_error(SaveIoOperation::CreateTemp, display_path, error))?;

    if let Err(error) = temp.write_all(contents) {
        cleanup_temp_file(&temp_path);
        return Err(io_error(SaveIoOperation::WriteTemp, display_path, error));
    }

    if let Err(error) = temp.set_permissions(snapshot.permissions.clone()) {
        cleanup_temp_file(&temp_path);
        return Err(io_error(
            SaveIoOperation::SetTempPermissions,
            display_path,
            error,
        ));
    }

    if let Err(error) = temp.sync_all() {
        cleanup_temp_file(&temp_path);
        return Err(io_error(SaveIoOperation::SyncTemp, display_path, error));
    }

    drop(temp);
    Ok(temp_path)
}

fn rename_temp_file(
    temp_path: &Path,
    target_path: &Path,
    display_path: &Path,
) -> SafeSaveResult<()> {
    match fs::rename(temp_path, target_path) {
        Ok(()) => Ok(()),
        Err(error) => {
            cleanup_temp_file(temp_path);
            Err(io_error(SaveIoOperation::RenameTemp, display_path, error))
        }
    }
}

fn sync_parent(path: &Path, display_path: &Path) -> SafeSaveResult<()> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    let directory = fs::File::open(parent)
        .map_err(|error| io_error(SaveIoOperation::SyncParent, display_path, error))?;
    directory
        .sync_all()
        .map_err(|error| io_error(SaveIoOperation::SyncParent, display_path, error))
}

fn cleanup_temp_file(path: &Path) {
    let _ = fs::remove_file(path);
}

fn temp_path_for(target_path: &Path) -> PathBuf {
    let counter = TEMP_FILE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let file_name = target_path
        .file_name()
        .map(|value| value.to_string_lossy())
        .unwrap_or_else(|| "untitled.md".into());
    let temp_name = format!(
        ".{}.native-markdown-save.{}.{}.tmp",
        file_name,
        std::process::id(),
        counter
    );
    target_path.with_file_name(temp_name)
}

fn conflict(
    expected: &SaveBaseline,
    kind: SaveConflictKind,
    actual: Option<SaveConflictSnapshot>,
) -> SafeSaveError {
    SafeSaveError::Conflict(Box::new(SaveConflict {
        relative_path: expected.relative_path.clone(),
        kind,
        expected: expected.clone(),
        actual,
    }))
}

fn io_error(operation: SaveIoOperation, path: &Path, error: std::io::Error) -> SafeSaveError {
    SafeSaveError::Io {
        operation,
        path: path.to_path_buf(),
        kind: error.kind(),
    }
}

fn relative_path_string(path: &Path) -> String {
    path.components()
        .filter_map(|component| match component {
            std::path::Component::Normal(value) => Some(value.to_string_lossy()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn stable_content_hash(contents: &[u8]) -> String {
    let mut hash = FNV_OFFSET_BASIS;
    for byte in contents {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    format!("{hash:016x}")
}

impl From<&SaveBaseline> for SaveConflictSnapshot {
    fn from(baseline: &SaveBaseline) -> Self {
        Self {
            file_identity: baseline.file_identity.clone(),
            size_bytes: baseline.size_bytes,
            modified: baseline.modified,
            content_hash: baseline.content_hash.clone(),
        }
    }
}

impl fmt::Display for SafeSaveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Path(error) => write!(formatter, "safe save path error: {error}"),
            Self::Conflict(conflict) => write!(
                formatter,
                "safe save conflict for {}: {:?}",
                conflict.relative_path, conflict.kind
            ),
            Self::ReadOnly { relative_path } => {
                write!(formatter, "safe save target is read-only: {relative_path}")
            }
            Self::NotRegularFile { relative_path } => {
                write!(
                    formatter,
                    "safe save target is not a regular file: {relative_path}"
                )
            }
            Self::Io {
                operation,
                path,
                kind,
            } => write!(
                formatter,
                "safe save io error during {:?} at {}: {:?}",
                operation,
                path.display(),
                kind
            ),
        }
    }
}

impl std::error::Error for SafeSaveError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::{PermissionsExt, symlink};
    use tempfile::TempDir;

    const BENCHMARK_VAULT: &str = "/Users/heeung/Documents/Codex Vault";

    struct SaveFixture {
        _temp: TempDir,
        root_path: PathBuf,
        root: VaultRoot,
    }

    #[test]
    fn copied_save_fixture_never_uses_real_benchmark_vault() {
        let fixture = copied_save_fixture();

        assert_not_benchmark_vault(&fixture.root_path);
        assert_ne!(fixture.root.canonical_root(), Path::new(BENCHMARK_VAULT));
    }

    #[test]
    fn normal_safe_save_writes_exact_bytes_and_updates_baseline() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let original_mode = unix_mode(&target);
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let edited = b"\xEF\xBB\xBF# Home\r\nEdited with CRLF\r\n";

        let outcome =
            safe_save(&fixture.root, SaveRequest::new(&baseline, edited)).expect("safe save");

        assert_eq!(fs::read(&target).expect("read saved"), edited);
        assert_eq!(outcome.bytes_written, edited.len() as u64);
        assert_eq!(outcome.baseline.relative_path, "Home.md");
        assert_eq!(outcome.baseline.size_bytes, edited.len() as u64);
        assert_eq!(outcome.baseline.content_hash, stable_content_hash(edited));
        assert_eq!(unix_mode(&target), original_mode);
        assert_no_temp_files(&fixture.root_path);
    }

    #[test]
    fn safe_save_rejects_external_edit_without_overwriting() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::write(&target, "# External edit\n").expect("external edit");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("conflict");

        assert_conflict_kind(error, SaveConflictKind::ContentChanged);
        assert_eq!(
            fs::read_to_string(&target).expect("read target"),
            "# External edit\n"
        );
    }

    #[test]
    fn safe_save_rejects_external_delete_without_recreating() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::remove_file(&target).expect("external delete");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("deleted conflict");

        assert_conflict_kind(error, SaveConflictKind::Deleted);
        assert!(!target.exists());
    }

    #[test]
    fn safe_save_rejects_external_replace_without_overwriting() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let replacement = fixture.root_path.join("Replacement.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::write(&replacement, "# Replacement\n").expect("replacement");
        fs::rename(&replacement, &target).expect("external replace");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("identity conflict");

        assert_conflict_kind(error, SaveConflictKind::FileIdentityChanged);
        assert_eq!(
            fs::read_to_string(&target).expect("read target"),
            "# Replacement\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn safe_save_rejects_symlink_swap_outside_vault() {
        let fixture = copied_save_fixture();
        let outside = tempfile::tempdir().expect("outside");
        fs::write(outside.path().join("secret.md"), "# Secret\n").expect("secret");
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        fs::remove_file(&target).expect("remove original");
        symlink(outside.path().join("secret.md"), &target).expect("symlink");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("symlink conflict");

        assert_conflict_kind(error, SaveConflictKind::SymlinkChanged);
        assert_eq!(
            fs::read_to_string(outside.path().join("secret.md")).expect("outside unchanged"),
            "# Secret\n"
        );
    }

    #[cfg(unix)]
    #[test]
    fn safe_save_rejects_read_only_target() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let original = fs::read_to_string(&target).expect("original");
        let mut permissions = fs::metadata(&target).expect("metadata").permissions();
        permissions.set_mode(0o444);
        fs::set_permissions(&target, permissions).expect("read only");

        let error = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"))
            .expect_err("read only");

        assert_eq!(
            error,
            SafeSaveError::ReadOnly {
                relative_path: "Home.md".to_string()
            }
        );
        assert_eq!(fs::read_to_string(&target).expect("target"), original);
    }

    #[cfg(unix)]
    #[test]
    fn safe_save_preserves_file_when_temp_write_cannot_start() {
        let fixture = copied_save_fixture();
        let target = fixture.root_path.join("Home.md");
        let baseline = SaveBaseline::capture(&fixture.root, "Home.md").expect("baseline");
        let original = fs::read_to_string(&target).expect("original");
        let original_mode = fs::metadata(&fixture.root_path)
            .expect("root metadata")
            .permissions()
            .mode();
        let mut permissions = fs::metadata(&fixture.root_path)
            .expect("root metadata")
            .permissions();
        permissions.set_mode(0o555);
        fs::set_permissions(&fixture.root_path, permissions).expect("read-only directory");

        let result = safe_save(&fixture.root, SaveRequest::new(&baseline, b"# App edit\n"));

        let mut restore_permissions = fs::metadata(&fixture.root_path)
            .expect("root metadata")
            .permissions();
        restore_permissions.set_mode(original_mode);
        fs::set_permissions(&fixture.root_path, restore_permissions).expect("restore directory");

        match result.expect_err("temp create failure") {
            SafeSaveError::Io {
                operation: SaveIoOperation::CreateTemp,
                kind: std::io::ErrorKind::PermissionDenied,
                ..
            } => {}
            other => panic!("expected temp create permission error, got {other:?}"),
        }
        assert_eq!(fs::read_to_string(&target).expect("target"), original);
        assert_no_temp_files(&fixture.root_path);
    }

    #[test]
    fn atomic_replace_failure_cleans_temp_file() {
        let temp = tempfile::tempdir().expect("tempdir");
        let temp_file = temp.path().join(".Home.md.native-markdown-save.test.tmp");
        let target_directory = temp.path().join("Home.md");
        fs::write(&temp_file, "# App edit\n").expect("temp file");
        fs::create_dir(&target_directory).expect("target directory");

        let error = rename_temp_file(&temp_file, &target_directory, Path::new("Home.md"))
            .expect_err("rename failure");

        match error {
            SafeSaveError::Io {
                operation: SaveIoOperation::RenameTemp,
                ..
            } => {}
            other => panic!("expected rename temp error, got {other:?}"),
        }
        assert!(!temp_file.exists());
        assert!(target_directory.is_dir());
    }

    fn copied_save_fixture() -> SaveFixture {
        let temp = tempfile::tempdir().expect("tempdir");
        let root_path = temp.path().join("copied-save-vault");
        copy_dir(&compatibility_fixture_root(), &root_path);
        assert_not_benchmark_vault(&root_path);
        let root = VaultRoot::open(&root_path).expect("root");

        SaveFixture {
            _temp: temp,
            root_path,
            root,
        }
    }

    fn compatibility_fixture_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault")
    }

    fn copy_dir(source: &Path, destination: &Path) {
        fs::create_dir_all(destination).expect("destination");
        for entry in fs::read_dir(source).expect("read source") {
            let entry = entry.expect("entry");
            let source_path = entry.path();
            let destination_path = destination.join(entry.file_name());
            let file_type = entry.file_type().expect("file type");
            if file_type.is_dir() {
                copy_dir(&source_path, &destination_path);
            } else if file_type.is_file() {
                fs::copy(&source_path, &destination_path).expect("copy file");
            }
        }
    }

    fn assert_not_benchmark_vault(path: &Path) {
        let benchmark = Path::new(BENCHMARK_VAULT);
        assert_ne!(path, benchmark);
        assert!(!path.starts_with(benchmark));
    }

    fn assert_conflict_kind(error: SafeSaveError, expected: SaveConflictKind) {
        match error {
            SafeSaveError::Conflict(conflict) => assert_eq!(conflict.kind, expected),
            other => panic!("expected conflict {expected:?}, got {other:?}"),
        }
    }

    fn assert_no_temp_files(root_path: &Path) {
        let leaked = fs::read_dir(root_path)
            .expect("read root")
            .filter_map(Result::ok)
            .any(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .contains(".native-markdown-save.")
            });
        assert!(!leaked);
    }

    #[cfg(unix)]
    fn unix_mode(path: &Path) -> Option<u32> {
        Some(fs::metadata(path).expect("metadata").permissions().mode() & 0o777)
    }

    #[cfg(not(unix))]
    fn unix_mode(_path: &Path) -> Option<u32> {
        None
    }
}
