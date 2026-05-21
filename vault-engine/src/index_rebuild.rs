use std::fmt;
use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::index::{FileRecord, IndexSchemaMetadata, MetadataStore, MetadataStoreError};
use crate::indexing_queue::{IndexingQueue, IndexingQueueError, IndexingQueueReason};
use crate::scanner::ScanSummary;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexRebuildPaths {
    pub vault_root: PathBuf,
    pub index_root: PathBuf,
    pub data_directory: PathBuf,
    pub rebuild_directory: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexRebuildStart {
    pub reason: IndexRebuildReason,
    pub generation: u64,
    pub cancelled_items: usize,
    pub enqueued_items: usize,
    pub rebuild_directory: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexRebuildCommit {
    pub data_directory: PathBuf,
    pub previous_data_removed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexRebuildReason {
    UserRequested,
    CorruptIndex,
    SchemaMismatch,
    BackendMismatch,
}

pub enum MetadataOpenRecovery {
    Opened(MetadataStore),
    RebuildStarted(IndexRebuildStart),
}

#[derive(Debug)]
pub enum IndexRebuildError {
    Io(std::io::Error),
    Queue(IndexingQueueError),
    InvalidPath(IndexRebuildPathError),
    GenerationOverflow,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexRebuildPathError {
    IndexRootInsideVault,
    DataOutsideIndexRoot,
    RebuildOutsideIndexRoot,
    DataOverlapsVault,
    RebuildOverlapsVault,
    DataEqualsRebuild,
}

pub type IndexRebuildResult<T> = Result<T, IndexRebuildError>;

impl IndexRebuildPaths {
    pub fn new(
        vault_root: impl Into<PathBuf>,
        index_root: impl Into<PathBuf>,
        data_directory: impl Into<PathBuf>,
        rebuild_directory: impl Into<PathBuf>,
    ) -> Self {
        Self {
            vault_root: vault_root.into(),
            index_root: index_root.into(),
            data_directory: data_directory.into(),
            rebuild_directory: rebuild_directory.into(),
        }
    }
}

pub fn start_index_rebuild(
    queue: &mut IndexingQueue,
    scan: &ScanSummary,
    paths: &IndexRebuildPaths,
    current_generation: u64,
    reason: IndexRebuildReason,
) -> IndexRebuildResult<IndexRebuildStart> {
    let paths = validate_paths(paths)?;
    let generation = current_generation
        .checked_add(1)
        .ok_or(IndexRebuildError::GenerationOverflow)?;

    reset_rebuild_directory(&paths.rebuild_directory, generation, reason)?;
    let cancelled_items = queue.cancel_generation(current_generation)?;

    let mut enqueued_items = 0;
    for entry in &scan.entries {
        let file = FileRecord::from_scan_entry(entry, generation);
        queue.enqueue_file(&file, IndexingQueueReason::Rebuild)?;
        enqueued_items += 1;
    }

    Ok(IndexRebuildStart {
        reason,
        generation,
        cancelled_items,
        enqueued_items,
        rebuild_directory: paths.rebuild_directory,
    })
}

pub fn open_metadata_or_start_rebuild(
    metadata_path: impl AsRef<Path>,
    expected: &IndexSchemaMetadata,
    queue: &mut IndexingQueue,
    scan: &ScanSummary,
    paths: &IndexRebuildPaths,
    current_generation: u64,
) -> IndexRebuildResult<MetadataOpenRecovery> {
    match MetadataStore::open(metadata_path, expected) {
        Ok(store) => Ok(MetadataOpenRecovery::Opened(store)),
        Err(error) => {
            let reason = rebuild_reason_for_metadata_error(&error);
            let rebuild = start_index_rebuild(queue, scan, paths, current_generation, reason)?;
            Ok(MetadataOpenRecovery::RebuildStarted(rebuild))
        }
    }
}

pub fn commit_index_rebuild(paths: &IndexRebuildPaths) -> IndexRebuildResult<IndexRebuildCommit> {
    let paths = validate_paths(paths)?;
    let previous_directory = paths.index_root.join("previous-data");
    ensure_no_vault_overlap(&previous_directory, &paths.vault_root)
        .map_err(IndexRebuildError::InvalidPath)?;

    if previous_directory.exists() {
        remove_path(&previous_directory)?;
    }

    let previous_data_removed = if paths.data_directory.exists() {
        fs::rename(&paths.data_directory, &previous_directory)?;
        true
    } else {
        false
    };

    match fs::rename(&paths.rebuild_directory, &paths.data_directory) {
        Ok(()) => {}
        Err(error) => {
            if previous_directory.exists() && !paths.data_directory.exists() {
                let _ = fs::rename(&previous_directory, &paths.data_directory);
            }
            return Err(IndexRebuildError::Io(error));
        }
    }

    if previous_directory.exists() {
        remove_path(&previous_directory)?;
    }

    Ok(IndexRebuildCommit {
        data_directory: paths.data_directory,
        previous_data_removed,
    })
}

pub fn abort_index_rebuild(paths: &IndexRebuildPaths) -> IndexRebuildResult<()> {
    let paths = validate_paths(paths)?;
    if paths.rebuild_directory.exists() {
        remove_path(&paths.rebuild_directory)?;
    }
    Ok(())
}

fn reset_rebuild_directory(
    rebuild_directory: &Path,
    generation: u64,
    reason: IndexRebuildReason,
) -> IndexRebuildResult<()> {
    if rebuild_directory.exists() {
        remove_path(rebuild_directory)?;
    }
    fs::create_dir_all(rebuild_directory)?;
    fs::write(
        rebuild_directory.join("rebuild.json"),
        format!(
            "{{\"generation\":{generation},\"reason\":\"{}\"}}\n",
            reason.as_str()
        ),
    )?;
    Ok(())
}

fn validate_paths(paths: &IndexRebuildPaths) -> IndexRebuildResult<IndexRebuildPaths> {
    let vault_root = normalize_path(&paths.vault_root)?;
    let index_root = normalize_path(&paths.index_root)?;
    let data_directory = normalize_path(&paths.data_directory)?;
    let rebuild_directory = normalize_path(&paths.rebuild_directory)?;

    if index_root == vault_root || index_root.starts_with(&vault_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::IndexRootInsideVault,
        ));
    }
    if !data_directory.starts_with(&index_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::DataOutsideIndexRoot,
        ));
    }
    if !rebuild_directory.starts_with(&index_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::RebuildOutsideIndexRoot,
        ));
    }
    if paths_overlap(&data_directory, &vault_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::DataOverlapsVault,
        ));
    }
    if paths_overlap(&rebuild_directory, &vault_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::RebuildOverlapsVault,
        ));
    }
    if data_directory == rebuild_directory {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::DataEqualsRebuild,
        ));
    }

    Ok(IndexRebuildPaths {
        vault_root,
        index_root,
        data_directory,
        rebuild_directory,
    })
}

fn rebuild_reason_for_metadata_error(error: &MetadataStoreError) -> IndexRebuildReason {
    match error {
        MetadataStoreError::SchemaMismatch { stored, expected } => {
            if stored.backend_name != expected.backend_name
                || stored.backend_version != expected.backend_version
            {
                IndexRebuildReason::BackendMismatch
            } else {
                IndexRebuildReason::SchemaMismatch
            }
        }
        MetadataStoreError::Sqlite(_) | MetadataStoreError::InvalidStoredValue(_) => {
            IndexRebuildReason::CorruptIndex
        }
    }
}

fn remove_path(path: &Path) -> IndexRebuildResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn normalize_path(path: &Path) -> IndexRebuildResult<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(value) => normalized.push(value),
        }
    }
    Ok(normalized)
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
    left == right || left.starts_with(right) || right.starts_with(left)
}

fn ensure_no_vault_overlap(path: &Path, vault_root: &Path) -> Result<(), IndexRebuildPathError> {
    if paths_overlap(path, vault_root) {
        return Err(IndexRebuildPathError::DataOverlapsVault);
    }
    Ok(())
}

impl IndexRebuildReason {
    fn as_str(self) -> &'static str {
        match self {
            Self::UserRequested => "user_requested",
            Self::CorruptIndex => "corrupt_index",
            Self::SchemaMismatch => "schema_mismatch",
            Self::BackendMismatch => "backend_mismatch",
        }
    }
}

impl fmt::Display for IndexRebuildError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "index rebuild io error: {error}"),
            Self::Queue(error) => write!(formatter, "index rebuild queue error: {error}"),
            Self::InvalidPath(error) => write!(formatter, "invalid index rebuild path: {error:?}"),
            Self::GenerationOverflow => write!(formatter, "index rebuild generation overflow"),
        }
    }
}

impl std::error::Error for IndexRebuildError {}

impl From<std::io::Error> for IndexRebuildError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<IndexingQueueError> for IndexRebuildError {
    fn from(error: IndexingQueueError) -> Self {
        Self::Queue(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::IndexSchemaMetadata;
    use crate::indexing_queue::IndexingQueueStatus;
    use crate::paths::FileIdentity;
    use crate::scanner::{ScanEntry, ScanEntryKind};
    use std::time::{Duration, UNIX_EPOCH};
    use tempfile::TempDir;

    #[test]
    fn user_rebuild_cancels_generation_and_queues_new_work_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        fs::write(fixture.paths.data_directory.join("old.index"), "old").expect("old index");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fs::write(fixture.paths.rebuild_directory.join("stale.tmp"), "stale")
            .expect("stale rebuild");
        let scan = synthetic_scan(2, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &FileRecord::from_scan_entry(&scan.entries[0], 1),
                IndexingQueueReason::InitialScan,
            )
            .expect("old item");

        let start = start_index_rebuild(
            &mut queue,
            &scan,
            &fixture.paths,
            1,
            IndexRebuildReason::UserRequested,
        )
        .expect("start rebuild");

        assert_eq!(start.reason, IndexRebuildReason::UserRequested);
        assert_eq!(start.generation, 2);
        assert_eq!(start.cancelled_items, 1);
        assert_eq!(start.enqueued_items, 2);
        assert!(fixture.paths.data_directory.join("old.index").exists());
        assert!(!fixture.paths.rebuild_directory.join("stale.tmp").exists());
        assert!(
            fixture
                .paths
                .rebuild_directory
                .join("rebuild.json")
                .exists()
        );
        assert_eq!(fixture.read_vault_note(), "private");

        let leased = queue.lease_batch(10).expect("lease");
        assert_eq!(leased.len(), 2);
        assert!(leased.iter().all(|item| item.generation == 2));
        assert!(
            leased
                .iter()
                .all(|item| item.reason == IndexingQueueReason::Rebuild)
        );
        assert!(
            leased
                .iter()
                .all(|item| item.status == IndexingQueueStatus::InProgress)
        );
    }

    #[test]
    fn commit_rebuild_swaps_data_and_removes_previous_inside_index_root() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        fs::write(fixture.paths.data_directory.join("old.index"), "old").expect("old index");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fs::write(fixture.paths.rebuild_directory.join("new.index"), "new").expect("new index");

        let commit = commit_index_rebuild(&fixture.paths).expect("commit rebuild");

        assert_eq!(commit.data_directory, fixture.paths.data_directory);
        assert!(commit.previous_data_removed);
        assert!(!fixture.paths.rebuild_directory.exists());
        assert!(!fixture.paths.data_directory.join("old.index").exists());
        assert_eq!(
            fs::read_to_string(fixture.paths.data_directory.join("new.index")).expect("new index"),
            "new"
        );
        assert!(!fixture.paths.index_root.join("previous-data").exists());
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn rejects_rebuild_data_directory_that_overlaps_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        let bad_paths = IndexRebuildPaths::new(
            &fixture.vault_root,
            fixture.temp.path(),
            &fixture.vault_root,
            fixture.temp.path().join("rebuild"),
        );
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let result = start_index_rebuild(
            &mut queue,
            &scan,
            &bad_paths,
            1,
            IndexRebuildReason::UserRequested,
        );

        assert!(matches!(
            result,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataOverlapsVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn corrupt_metadata_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        fs::write(&metadata_path, "not sqlite").expect("corrupt metadata");
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover corrupt metadata");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::CorruptIndex);
        assert_eq!(start.generation, 2);
        assert_eq!(start.enqueued_items, 1);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn compatible_metadata_opens_without_starting_rebuild() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let store = MetadataStore::open(&metadata_path, &expected).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("open compatible metadata");

        let MetadataOpenRecovery::Opened(_) = recovery else {
            panic!("expected opened metadata");
        };
        assert!(!fixture.paths.rebuild_directory.exists());
        assert_eq!(queue.summary().expect("queue").pending, 0);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn schema_mismatch_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let stored = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tokenizer-v1", 1);
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tokenizer-v2", 1);
        let store = MetadataStore::open(&metadata_path, &stored).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover schema mismatch");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::SchemaMismatch);
        assert_eq!(start.generation, 2);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn snippet_storage_mismatch_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let stored = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "stored_body", 1);
        let expected =
            IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "lazy_source_experiment", 1);
        let store = MetadataStore::open(&metadata_path, &stored).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover snippet mismatch");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::SchemaMismatch);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn backend_mismatch_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let stored = IndexSchemaMetadata::new("sqlite-fts", "metadata-v1", "tantivy", 1);
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let store = MetadataStore::open(&metadata_path, &stored).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover backend mismatch");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::BackendMismatch);
        assert_eq!(start.generation, 2);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    struct RebuildFixture {
        temp: TempDir,
        vault_root: PathBuf,
        paths: IndexRebuildPaths,
    }

    impl RebuildFixture {
        fn new() -> Self {
            let temp = tempfile::tempdir().expect("tempdir");
            let vault_root = temp.path().join("vault");
            let index_root = temp.path().join("support").join("Indexes").join("vault-id");
            let data_directory = index_root.join("data");
            let rebuild_directory = index_root.join("rebuild");
            fs::create_dir_all(&vault_root).expect("vault");
            let paths =
                IndexRebuildPaths::new(&vault_root, index_root, data_directory, rebuild_directory);
            Self {
                temp,
                vault_root,
                paths,
            }
        }

        fn write_vault_note(&self, content: &str) {
            fs::write(self.vault_root.join("Note.md"), content).expect("vault note");
        }

        fn read_vault_note(&self) -> String {
            fs::read_to_string(self.vault_root.join("Note.md")).expect("vault note")
        }
    }

    fn synthetic_scan(count: usize, generation_seed: u64) -> ScanSummary {
        let entries = (0..count)
            .map(|index| ScanEntry {
                relative_path: PathBuf::from(format!("Note-{index:05}.md")),
                kind: ScanEntryKind::Markdown,
                size_bytes: 10,
                modified: Some(UNIX_EPOCH + Duration::from_secs(generation_seed)),
                file_identity: FileIdentity {
                    device: 1,
                    inode: index as u64 + 100,
                },
            })
            .collect::<Vec<_>>();
        ScanSummary {
            markdown_files: entries.len(),
            entries,
            attachment_files: 0,
            other_files: 0,
            skipped_directories: 0,
            skipped_symlinks: 0,
        }
    }
}
