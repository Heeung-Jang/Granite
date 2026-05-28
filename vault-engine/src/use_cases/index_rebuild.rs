use std::{
    fmt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use super::indexing_pipeline::{
    IndexingPipelineError, IndexingPipelineOptions, IndexingPipelineResult, IndexingPipelineTier,
    IndexingTierTransition, ProductionIndexingPipelineResult, ProductionIndexingStageMetrics,
    SearchDocumentSource, load_search_document_sources,
};
use crate::adapters::fs::index_directory::{
    IndexDirectoryCommit, IndexDirectoryError, IndexDirectoryPathError, IndexDirectoryPaths,
    commit_index_rebuild as commit_index_rebuild_impl, reset_pipeline_rebuild_directory,
    reset_tantivy_rebuild_directory,
};
#[cfg(test)]
use crate::adapters::fs::index_directory::{
    abort_index_rebuild as abort_index_rebuild_impl, reset_rebuild_directory, validate_paths,
};
use crate::adapters::fs::path_resolver::VaultRoot;
#[cfg(test)]
use crate::adapters::sqlite::{FileRecord, IndexingQueue, IndexingQueueReason, MetadataStoreError};
use crate::adapters::sqlite::{IndexSchemaMetadata, IndexingQueueError, MetadataStore};
use crate::adapters::tantivy::{TantivyIndexingStageMetrics, TantivySearchIndex};
use crate::core::paths::PathError;
#[cfg(test)]
use crate::core::scan::ScanSummary;

use super::read_parse_documents::{PipelineCorpusStats, run_read_parse_pipeline};
use super::read_vault::expected_read_schema_metadata;
use super::rebuild_tantivy::run_tantivy_rebuild_pipeline;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexRebuildPaths {
    pub vault_root: PathBuf,
    pub index_root: PathBuf,
    pub data_directory: PathBuf,
    pub rebuild_directory: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg(test)]
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
#[cfg(test)]
pub enum IndexRebuildReason {
    UserRequested,
    CorruptIndex,
    SchemaMismatch,
    BackendMismatch,
}

#[cfg(test)]
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
    MissingEngineOwnedMarker,
    UnexpectedIndexDirectoryEntry,
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

#[cfg(test)]
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

    reset_rebuild_directory(&paths, generation, reason.as_str())?;
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

#[cfg(test)]
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

#[cfg(test)]
pub fn abort_index_rebuild(paths: &IndexRebuildPaths) -> IndexRebuildResult<()> {
    abort_index_rebuild_impl(&paths.to_index_directory_paths()).map_err(Into::into)
}

pub fn run_full_rebuild_pipeline(
    paths: &IndexRebuildPaths,
    sources: &[SearchDocumentSource],
    metadata: &IndexSchemaMetadata,
    pipeline_options: &IndexingPipelineOptions,
) -> IndexingPipelineResult<ProductionIndexingPipelineResult> {
    let started = Instant::now();
    let mut tier_transitions = vec![tier_transition(
        IndexingPipelineTier::Discovered,
        started.elapsed(),
    )];
    reset_pipeline_rebuild_directory(&paths.to_index_directory_paths())
        .map_err(index_directory_error_for_pipeline)?;
    let options = pipeline_options.normalized();
    let metadata_path = paths.rebuild_directory.join("metadata.sqlite");
    let mut metadata_store = MetadataStore::open(&metadata_path, metadata)?;
    let batch_size = options.metadata_batch_size;
    let mut pending = Vec::with_capacity(batch_size);
    let mut sqlite_metadata_write_micros = 0;

    run_read_parse_pipeline(sources, &options, |timed| {
        let mut records = timed.work_item.metadata_records;
        records.file.generation = metadata.generation;
        records.file.mark_search_indexed();
        pending.push(records);
        if pending.len() >= batch_size {
            let start = Instant::now();
            metadata_store.replace_file_records_batch(&pending)?;
            sqlite_metadata_write_micros += duration_micros_nonzero(start.elapsed());
            pending.clear();
        }
        Ok::<(), super::indexing_pipeline::IndexingPipelineError>(())
    })?;

    if !pending.is_empty() {
        let start = Instant::now();
        metadata_store.replace_file_records_batch(&pending)?;
        sqlite_metadata_write_micros += duration_micros_nonzero(start.elapsed());
    }
    tier_transitions.push(tier_transition(
        IndexingPipelineTier::MetadataReady,
        started.elapsed(),
    ));

    let tantivy_dir = paths.rebuild_directory.join("tantivy");
    reset_tantivy_rebuild_directory(&paths.to_index_directory_paths())
        .map_err(index_directory_error_for_pipeline)?;
    let mut tantivy = TantivySearchIndex::open_in_dir(&tantivy_dir)?;
    tier_transitions.push(tier_transition(
        IndexingPipelineTier::BodyIndexing,
        started.elapsed(),
    ));
    let tantivy_run = run_tantivy_rebuild_pipeline(&mut tantivy, sources, &options)?;
    let time_to_usable_micros = duration_micros_nonzero(started.elapsed());
    tier_transitions.push(IndexingTierTransition {
        tier: IndexingPipelineTier::FilenameReady,
        elapsed_micros: time_to_usable_micros,
    });
    tier_transitions.push(IndexingTierTransition {
        tier: IndexingPipelineTier::Complete,
        elapsed_micros: time_to_usable_micros,
    });

    Ok(production_result_with_timing(
        metadata.generation,
        tantivy_run.stages.added_document_count,
        tantivy_run.stages.failed_document_count,
        tantivy_run.stats,
        sqlite_metadata_write_micros,
        tantivy_run.stages,
        tier_transitions,
        Some(time_to_usable_micros),
    ))
}

pub fn run_full_rebuild_pipeline_and_commit(
    paths: &IndexRebuildPaths,
    sources: &[SearchDocumentSource],
    metadata: &IndexSchemaMetadata,
    pipeline_options: &IndexingPipelineOptions,
) -> IndexingPipelineResult<ProductionIndexingPipelineResult> {
    let result = run_full_rebuild_pipeline(paths, sources, metadata, pipeline_options)?;
    commit_index_rebuild(paths)?;
    Ok(result)
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

fn production_result_with_timing(
    generation: u64,
    processed_count: usize,
    failed_count: usize,
    stats: PipelineCorpusStats,
    sqlite_metadata_write_micros: u64,
    tantivy: TantivyIndexingStageMetrics,
    tier_transitions: Vec<IndexingTierTransition>,
    time_to_usable_micros: Option<u64>,
) -> ProductionIndexingPipelineResult {
    ProductionIndexingPipelineResult::with_timing(
        generation,
        processed_count,
        failed_count,
        tier_transitions,
        time_to_usable_micros,
        ProductionIndexingStageMetrics {
            read_parse_sample_count: stats.read_micros.len(),
            read_parse_total_bytes: stats.read_parse_bytes,
            read_parse_peak_in_flight_items: 0,
            sqlite_metadata_write_micros,
            tantivy,
        },
    )
}

fn tier_transition(tier: IndexingPipelineTier, elapsed: Duration) -> IndexingTierTransition {
    IndexingTierTransition {
        tier,
        elapsed_micros: duration_micros_nonzero(elapsed),
    }
}

fn duration_micros(duration: Duration) -> u64 {
    duration.as_micros().min(u128::from(u64::MAX)) as u64
}

fn duration_micros_nonzero(duration: Duration) -> u64 {
    duration_micros(duration).max(1)
}

fn index_directory_error_for_pipeline(error: IndexDirectoryError) -> IndexingPipelineError {
    match error {
        IndexDirectoryError::Io(error) => IndexingPipelineError::Io(error),
        IndexDirectoryError::InvalidPath(error) => {
            IndexingPipelineError::Rebuild(IndexRebuildError::InvalidPath(error.into()))
        }
    }
}

#[cfg(test)]
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

#[cfg(test)]
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
            IndexDirectoryPathError::MissingEngineOwnedMarker => Self::MissingEngineOwnedMarker,
            IndexDirectoryPathError::UnexpectedIndexDirectoryEntry => {
                Self::UnexpectedIndexDirectoryEntry
            }
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
