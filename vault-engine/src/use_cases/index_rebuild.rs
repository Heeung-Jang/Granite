use std::{
    fmt,
    path::{Path, PathBuf},
};

use crate::adapters::fs::index_directory::{
    IndexDirectoryCommit, IndexDirectoryError, IndexDirectoryPathError, IndexDirectoryPaths,
    abort_index_rebuild as abort_index_rebuild_impl,
    commit_index_rebuild as commit_index_rebuild_impl, reset_rebuild_directory, validate_paths,
};
use crate::adapters::sqlite::{
    FileRecord, IndexSchemaMetadata, IndexingQueue, IndexingQueueError, IndexingQueueReason,
    MetadataStore, MetadataStoreError,
};
use crate::indexing_pipeline::{
    IndexingPipelineOptions, load_search_document_sources, run_full_rebuild_pipeline_and_commit,
};
use crate::paths::{PathError, VaultRoot};
use crate::scanner::ScanSummary;

use super::read_vault::expected_read_schema_metadata;

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

#[derive(Debug)]
pub enum ReadIndexRebuildError {
    InvalidInput(&'static str),
    Path(PathError),
    RebuildFailed(String),
}

pub type ReadIndexRebuildResult<T> = Result<T, ReadIndexRebuildError>;

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

    fn to_index_directory_paths(&self) -> IndexDirectoryPaths {
        IndexDirectoryPaths {
            vault_root: self.vault_root.clone(),
            index_root: self.index_root.clone(),
            data_directory: self.data_directory.clone(),
            rebuild_directory: self.rebuild_directory.clone(),
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
    let paths = validate_paths(&paths.to_index_directory_paths())?;
    let generation = current_generation
        .checked_add(1)
        .ok_or(IndexRebuildError::GenerationOverflow)?;

    reset_rebuild_directory(&paths.rebuild_directory, generation, reason.as_str())?;
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
    let commit = commit_index_rebuild_impl(&paths.to_index_directory_paths())?;
    Ok(IndexRebuildCommit::from(commit))
}

pub fn abort_index_rebuild(paths: &IndexRebuildPaths) -> IndexRebuildResult<()> {
    abort_index_rebuild_impl(&paths.to_index_directory_paths()).map_err(Into::into)
}

pub fn rebuild_read_index(
    vault_path: &Path,
    data_path: &Path,
    rebuild_path: &Path,
) -> ReadIndexRebuildResult<u64> {
    let root = VaultRoot::open(vault_path).map_err(ReadIndexRebuildError::Path)?;
    let index_root = data_path
        .parent()
        .ok_or(ReadIndexRebuildError::InvalidInput("data_path"))?;
    let paths = IndexRebuildPaths::new(root.canonical_root(), index_root, data_path, rebuild_path);
    let loaded = load_search_document_sources(&root)
        .map_err(|error| ReadIndexRebuildError::RebuildFailed(error.to_string()))?;
    let metadata = expected_read_schema_metadata();
    let result = run_full_rebuild_pipeline_and_commit(
        &paths,
        &loaded.sources,
        &metadata,
        &IndexingPipelineOptions::default(),
    )
    .map_err(|error| ReadIndexRebuildError::RebuildFailed(error.to_string()))?;

    Ok(result.generation)
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

impl IndexRebuildReason {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::UserRequested => "user_requested",
            Self::CorruptIndex => "corrupt_index",
            Self::SchemaMismatch => "schema_mismatch",
            Self::BackendMismatch => "backend_mismatch",
        }
    }
}

impl From<IndexDirectoryCommit> for IndexRebuildCommit {
    fn from(commit: IndexDirectoryCommit) -> Self {
        Self {
            data_directory: commit.data_directory,
            previous_data_removed: commit.previous_data_removed,
        }
    }
}

impl From<IndexDirectoryError> for IndexRebuildError {
    fn from(error: IndexDirectoryError) -> Self {
        match error {
            IndexDirectoryError::Io(error) => Self::Io(error),
            IndexDirectoryError::InvalidPath(error) => Self::InvalidPath(error.into()),
        }
    }
}

impl From<IndexDirectoryPathError> for IndexRebuildPathError {
    fn from(error: IndexDirectoryPathError) -> Self {
        match error {
            IndexDirectoryPathError::IndexRootInsideVault => Self::IndexRootInsideVault,
            IndexDirectoryPathError::DataOutsideIndexRoot => Self::DataOutsideIndexRoot,
            IndexDirectoryPathError::RebuildOutsideIndexRoot => Self::RebuildOutsideIndexRoot,
            IndexDirectoryPathError::DataOverlapsVault => Self::DataOverlapsVault,
            IndexDirectoryPathError::RebuildOverlapsVault => Self::RebuildOverlapsVault,
            IndexDirectoryPathError::DataEqualsRebuild => Self::DataEqualsRebuild,
        }
    }
}

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

impl fmt::Display for ReadIndexRebuildError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(field) => write!(formatter, "{field}: invalid path"),
            Self::Path(error) => write!(formatter, "{error}"),
            Self::RebuildFailed(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for ReadIndexRebuildError {}
