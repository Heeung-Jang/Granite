use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::adapters::fs::path_resolver::VaultRoot;
use crate::adapters::fs::path_resolver::is_unsupported_hardlinked_file;
use crate::core::paths::{PathError, normalize_relative_path};
use crate::use_cases::save_note::{SafeSaveError, SafeSaveResult, SaveBaseline, SaveIoOperation};

const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

static TEMP_FILE_COUNTER: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone)]
pub(crate) struct FileSnapshot {
    pub(crate) baseline: SaveBaseline,
    pub(crate) absolute_path: PathBuf,
    pub(crate) permissions: fs::Permissions,
    pub(crate) readonly: bool,
}

pub(crate) fn capture_snapshot(
    root: &VaultRoot,
    relative_path: &str,
) -> SafeSaveResult<FileSnapshot> {
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
    if is_unsupported_hardlinked_file(&metadata) {
        return Err(SafeSaveError::Path(PathError::UnsupportedHardlink(
            resolved.relative_path.clone(),
        )));
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

pub(crate) fn write_new_note(
    root: &VaultRoot,
    relative_path: &str,
    contents: &[u8],
) -> SafeSaveResult<()> {
    let relative_path = normalize_relative_path(relative_path).map_err(SafeSaveError::Path)?;
    let absolute_path = root.canonical_root().join(&relative_path);
    let display_path = relative_path.as_path();
    if absolute_path.exists() {
        return Err(SafeSaveError::Io {
            operation: SaveIoOperation::CreateNewNote,
            path: relative_path,
            kind: std::io::ErrorKind::AlreadyExists,
        });
    }

    let Some(parent) = absolute_path.parent() else {
        return Err(SafeSaveError::Path(PathError::OutsideVault(relative_path)));
    };
    let canonical_parent = fs::canonicalize(parent).map_err(|error| SafeSaveError::Io {
        operation: SaveIoOperation::ReadMetadata,
        path: relative_path.clone(),
        kind: error.kind(),
    })?;
    if !canonical_parent.starts_with(root.canonical_root()) {
        return Err(SafeSaveError::Path(PathError::SymlinkEscape {
            input: relative_path.clone(),
            canonical: canonical_parent,
        }));
    }

    let temp_path = temp_path_for(&absolute_path);
    let mut temp = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp_path)
        .map_err(|error| io_error(SaveIoOperation::CreateTemp, display_path, error))?;
    if let Err(error) = temp.write_all(contents) {
        cleanup_temp_file(&temp_path);
        return Err(io_error(SaveIoOperation::WriteTemp, display_path, error));
    }
    if let Err(error) = temp.sync_all() {
        cleanup_temp_file(&temp_path);
        return Err(io_error(SaveIoOperation::SyncTemp, display_path, error));
    }
    drop(temp);

    match fs::hard_link(&temp_path, &absolute_path) {
        Ok(()) => {
            cleanup_temp_file(&temp_path);
            sync_parent(&absolute_path, display_path)
        }
        Err(error) => {
            cleanup_temp_file(&temp_path);
            Err(io_error(SaveIoOperation::LinkNewNote, display_path, error))
        }
    }
}

pub(crate) fn read_snapshot_contents(snapshot: &FileSnapshot) -> SafeSaveResult<Vec<u8>> {
    fs::read(&snapshot.absolute_path).map_err(|error| SafeSaveError::Io {
        operation: SaveIoOperation::ReadFile,
        path: PathBuf::from(&snapshot.baseline.relative_path),
        kind: error.kind(),
    })
}

pub(crate) fn write_temp_file(snapshot: &FileSnapshot, contents: &[u8]) -> SafeSaveResult<PathBuf> {
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

pub(crate) fn rename_temp_file(
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

pub(crate) fn sync_parent(path: &Path, display_path: &Path) -> SafeSaveResult<()> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    let directory = fs::File::open(parent)
        .map_err(|error| io_error(SaveIoOperation::SyncParent, display_path, error))?;
    directory
        .sync_all()
        .map_err(|error| io_error(SaveIoOperation::SyncParent, display_path, error))
}

pub(crate) fn stable_content_hash(contents: &[u8]) -> String {
    let mut hash = FNV_OFFSET_BASIS;
    for byte in contents {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    format!("{hash:016x}")
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
