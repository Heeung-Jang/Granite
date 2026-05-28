#[cfg(test)]
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::path::PathBuf;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use serde::Serialize;

use crate::adapters::fs::path_resolver::VaultRoot;
use crate::adapters::fs::scanner::scan_vault;
#[cfg(test)]
use crate::adapters::sqlite::IndexingQueueSummary;
use crate::adapters::sqlite::{IndexingQueueError, MetadataStoreError};
#[cfg(test)]
use crate::adapters::sqlite::{IndexingQueueReason, MetadataStore};
#[cfg(test)]
use crate::adapters::tantivy::TantivySearchIndex;
use crate::adapters::tantivy::{
    TantivyIndexingStageMetrics, TantivySearchError, TantivyWriterOptions,
};
use crate::core::files::FileIdentity;
#[cfg(test)]
use crate::core::links::{NoteTarget, NoteTargetIndex};
use crate::core::paths::{PathError, lookup_key};
use crate::core::scan::ScanEntryKind;
pub use crate::core::search::SnippetStorageMode;
use crate::use_cases::index_rebuild::IndexRebuildError;
pub use crate::use_cases::index_rebuild::run_full_rebuild_pipeline;
#[cfg(test)]
pub use crate::use_cases::index_rebuild::run_full_rebuild_pipeline_and_commit;
#[cfg(test)]
pub use crate::use_cases::process_indexing_queue::{
    QueueBatchIndexOptions, QueueLeaseBatch, QueuePipelineItem, lease_queue_batch,
    process_indexing_queue_batch,
};
#[cfg(test)]
use crate::use_cases::process_indexing_queue::{
    record_queue_failure, record_queue_failures, source_for_queue_item,
};
#[cfg(test)]
pub use crate::use_cases::read_parse_documents::read_parse_source;
#[cfg(test)]
use crate::use_cases::read_parse_documents::read_parse_source_at_with_note_targets;
pub use crate::use_cases::read_parse_documents::{
    PipelineCorpusStats, read_search_document, run_read_parse_pipeline,
};
#[cfg(test)]
use crate::use_cases::rebuild_tantivy::merge_tantivy_metrics;
pub use crate::use_cases::rebuild_tantivy::run_tantivy_rebuild_pipeline;

pub const MAX_DEFAULT_READ_PARSE_WORKERS: usize = 4;
const DEFAULT_CHANNEL_CAPACITY: usize = 32;
const DEFAULT_METADATA_BATCH_SIZE: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexingMode {
    FullRebuild,
    IncrementalReplace,
}

#[derive(Debug, Clone)]
pub struct IndexingPipelineOptions {
    pub mode: IndexingMode,
    pub read_parse_workers: usize,
    pub channel_capacity: usize,
    pub writer_options: TantivyWriterOptions,
    pub metadata_batch_size: usize,
    pub snippet_storage_mode: SnippetStorageMode,
}

impl Default for IndexingPipelineOptions {
    fn default() -> Self {
        let workers = thread::available_parallelism()
            .map(usize::from)
            .unwrap_or(1)
            .clamp(1, MAX_DEFAULT_READ_PARSE_WORKERS);
        Self {
            mode: IndexingMode::FullRebuild,
            read_parse_workers: workers,
            channel_capacity: DEFAULT_CHANNEL_CAPACITY,
            writer_options: TantivyWriterOptions::default(),
            metadata_batch_size: DEFAULT_METADATA_BATCH_SIZE,
            snippet_storage_mode: SnippetStorageMode::StoredBody,
        }
    }
}

impl IndexingPipelineOptions {
    pub fn serial() -> Self {
        Self {
            read_parse_workers: 1,
            ..Default::default()
        }
    }

    pub fn normalized(&self) -> Self {
        Self {
            mode: self.mode,
            read_parse_workers: self
                .read_parse_workers
                .clamp(1, MAX_DEFAULT_READ_PARSE_WORKERS),
            channel_capacity: self.channel_capacity.max(1),
            writer_options: self.writer_options,
            metadata_batch_size: self.metadata_batch_size.max(1),
            snippet_storage_mode: self.snippet_storage_mode,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IndexingPipelineTier {
    Discovered,
    MetadataReady,
    FilenameReady,
    BodyIndexing,
    Complete,
    #[cfg(test)]
    Stale,
    Error,
}

#[cfg(test)]
#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IndexingProgressStage {
    LeaseQueue,
    ReadParse,
    MetadataWrite,
    SearchIndex,
    CommitRebuild,
}

#[cfg(test)]
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct IndexingProgressSnapshot {
    pub generation: u64,
    pub tier: IndexingPipelineTier,
    pub stage: IndexingProgressStage,
    pub pending_count: usize,
    pub in_progress_count: usize,
    pub completed_count: usize,
    pub failed_count: usize,
    pub cancelled_count: usize,
}

#[cfg(test)]
impl IndexingProgressSnapshot {
    pub fn from_queue_summary(
        generation: u64,
        tier: IndexingPipelineTier,
        stage: IndexingProgressStage,
        summary: IndexingQueueSummary,
    ) -> Self {
        Self {
            generation,
            tier,
            stage,
            pending_count: summary.pending,
            in_progress_count: summary.in_progress,
            completed_count: summary.completed,
            failed_count: summary.failed,
            cancelled_count: summary.cancelled,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProductionIndexingStageMetrics {
    pub read_parse_sample_count: usize,
    pub read_parse_total_bytes: u64,
    pub read_parse_peak_in_flight_items: usize,
    pub sqlite_metadata_write_micros: u64,
    pub tantivy: TantivyIndexingStageMetrics,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductionIndexingPipelineResult {
    pub generation: u64,
    pub processed_count: usize,
    pub failed_count: usize,
    pub tier: IndexingPipelineTier,
    pub tier_transitions: Vec<IndexingTierTransition>,
    pub time_to_usable_micros: Option<u64>,
    pub stages: ProductionIndexingStageMetrics,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IndexingTierTransition {
    pub tier: IndexingPipelineTier,
    pub elapsed_micros: u64,
}

impl ProductionIndexingPipelineResult {
    #[cfg(test)]
    pub fn new(
        generation: u64,
        processed_count: usize,
        failed_count: usize,
        stages: ProductionIndexingStageMetrics,
    ) -> Self {
        Self {
            generation,
            processed_count,
            failed_count,
            tier: if failed_count == 0 {
                IndexingPipelineTier::Complete
            } else {
                IndexingPipelineTier::Error
            },
            tier_transitions: Vec::new(),
            time_to_usable_micros: None,
            stages,
        }
    }

    pub fn with_timing(
        generation: u64,
        processed_count: usize,
        failed_count: usize,
        tier_transitions: Vec<IndexingTierTransition>,
        time_to_usable_micros: Option<u64>,
        stages: ProductionIndexingStageMetrics,
    ) -> Self {
        let tier = tier_transitions
            .last()
            .map(|transition| transition.tier)
            .unwrap_or(if failed_count == 0 {
                IndexingPipelineTier::Complete
            } else {
                IndexingPipelineTier::Error
            });
        Self {
            generation,
            processed_count,
            failed_count,
            tier,
            tier_transitions,
            time_to_usable_micros,
            stages,
        }
    }
}

#[derive(Debug)]
pub enum IndexingPipelineError {
    Io(std::io::Error),
    Path(PathError),
    Scan(String),
    Rebuild(IndexRebuildError),
    Metadata(MetadataStoreError),
    Queue(IndexingQueueError),
    Tantivy(TantivySearchError),
}

pub type IndexingPipelineResult<T> = Result<T, IndexingPipelineError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchDocumentSource {
    pub relative_path: PathBuf,
    pub absolute_path: PathBuf,
    pub file_id: String,
    pub kind: ScanEntryKind,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub file_identity: FileIdentity,
}

pub struct LoadedSearchDocumentSources {
    pub sources: Vec<SearchDocumentSource>,
    pub stages: PipelineCorpusStageMetrics,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PipelineCorpusStageMetrics {
    pub scan_micros: u64,
    pub source_collection_micros: u64,
}

pub fn load_search_document_sources(
    root: &VaultRoot,
) -> IndexingPipelineResult<LoadedSearchDocumentSources> {
    let scan_start = Instant::now();
    let scan =
        scan_vault(root).map_err(|error| IndexingPipelineError::Scan(format!("{error:?}")))?;
    let scan_micros = duration_micros_nonzero(scan_start.elapsed());
    let source_collection_start = Instant::now();
    let sources = scan
        .entries
        .into_iter()
        .filter(|entry| entry.kind == ScanEntryKind::Markdown)
        .map(|entry| {
            let relative_path = entry.relative_path;
            let absolute_path = root.canonical_root().join(&relative_path);
            SearchDocumentSource {
                file_id: lookup_key(&relative_path),
                relative_path,
                absolute_path,
                kind: entry.kind,
                size_bytes: entry.size_bytes,
                modified: entry.modified,
                file_identity: entry.file_identity,
            }
        })
        .collect();
    let source_collection_micros = duration_micros_nonzero(source_collection_start.elapsed());

    Ok(LoadedSearchDocumentSources {
        sources,
        stages: PipelineCorpusStageMetrics {
            scan_micros,
            source_collection_micros,
        },
    })
}

#[cfg(test)]
pub(crate) fn lease_queue_batch_impl(
    queue: &mut crate::adapters::sqlite::IndexingQueue,
    root: &VaultRoot,
    limit: usize,
) -> IndexingPipelineResult<QueueLeaseBatch> {
    let queue_items = queue.lease_batch(limit)?;
    let mut items = Vec::with_capacity(queue_items.len());
    for queue_item in queue_items {
        let source = source_for_queue_item(root, &queue_item)?;
        items.push(QueuePipelineItem { queue_item, source });
    }
    Ok(QueueLeaseBatch { items })
}

#[cfg(test)]
pub(crate) fn process_indexing_queue_batch_impl(
    queue: &mut crate::adapters::sqlite::IndexingQueue,
    metadata_store: &mut MetadataStore,
    tantivy_index: &mut TantivySearchIndex,
    root: &VaultRoot,
    batch_options: QueueBatchIndexOptions,
    pipeline_options: &IndexingPipelineOptions,
) -> IndexingPipelineResult<ProductionIndexingPipelineResult> {
    let queue_items = queue.lease_batch(batch_options.lease_limit)?;
    let mut generation = 0;
    let mut processed_count = 0;
    let mut failed_count = 0;
    let mut stats = PipelineCorpusStats::default();
    let mut metadata_records = Vec::new();
    let mut documents = Vec::new();
    let mut successful_item_ids = Vec::new();
    let mut deleted_file_ids = Vec::new();
    let mut deleted_item_ids = Vec::new();
    let mut parse_items = Vec::new();
    let mut batch_sources = Vec::new();
    let options = pipeline_options.normalized();

    for queue_item in queue_items {
        generation = generation.max(queue_item.generation);
        if queue_item.reason == IndexingQueueReason::FileDeleted {
            deleted_file_ids.push(queue_item.file_id.clone());
            deleted_item_ids.push(queue_item.item_id);
            continue;
        }

        match source_for_queue_item(root, &queue_item) {
            Ok(Some(source)) => {
                batch_sources.push(source.clone());
                parse_items.push((queue_item, source));
            }
            Ok(None) => {
                successful_item_ids.push(queue_item.item_id);
            }
            Err(error) => {
                record_queue_failure(
                    queue,
                    queue_item.item_id,
                    &error,
                    batch_options.max_attempts,
                )?;
                failed_count += 1;
            }
        }
    }

    let note_targets =
        note_target_index_for_queue(metadata_store, &batch_sources, &deleted_file_ids)?;

    for (queue_item, source) in parse_items {
        match read_parse_source_at_with_note_targets(0, &source, Some(&note_targets)) {
            Ok(timed) => {
                stats.record_timed(&timed);
                let mut records = timed.work_item.metadata_records;
                records.file.generation = queue_item.generation;
                records.file.mark_search_indexed();
                metadata_records.push(records);
                documents.push(timed.document);
                successful_item_ids.push(queue_item.item_id);
            }
            Err(error) => {
                record_queue_failure(
                    queue,
                    queue_item.item_id,
                    &error,
                    batch_options.max_attempts,
                )?;
                failed_count += 1;
            }
        }
    }

    let mut sqlite_metadata_write_micros = 0;
    if !metadata_records.is_empty() {
        let start = Instant::now();
        if let Err(error) = metadata_store.replace_file_records_batch(&metadata_records) {
            record_queue_failures(
                queue,
                &successful_item_ids,
                &error,
                batch_options.max_attempts,
            )?;
            failed_count += successful_item_ids.len();
            return Ok(production_result(
                generation,
                processed_count,
                failed_count,
                stats,
                0,
                TantivyIndexingStageMetrics::default(),
            ));
        }
        sqlite_metadata_write_micros = duration_micros_nonzero(start.elapsed());
    }

    let mut tantivy_stages = TantivyIndexingStageMetrics::default();
    if !documents.is_empty() {
        match tantivy_index
            .replace_documents_with_options_and_stage_durations(&documents, options.writer_options)
        {
            Ok(stages) => tantivy_stages = merge_tantivy_metrics(tantivy_stages, stages),
            Err(error) => {
                record_queue_failures(
                    queue,
                    &successful_item_ids,
                    &error,
                    batch_options.max_attempts,
                )?;
                failed_count += successful_item_ids.len();
                return Ok(production_result(
                    generation,
                    processed_count,
                    failed_count,
                    stats,
                    sqlite_metadata_write_micros,
                    tantivy_stages,
                ));
            }
        }
    }

    if !deleted_file_ids.is_empty() {
        for file_id in &deleted_file_ids {
            if let Err(error) = metadata_store.delete_file(file_id) {
                record_queue_failures(
                    queue,
                    &deleted_item_ids,
                    &error,
                    batch_options.max_attempts,
                )?;
                failed_count += deleted_item_ids.len();
                return Ok(production_result(
                    generation,
                    processed_count,
                    failed_count,
                    stats,
                    sqlite_metadata_write_micros,
                    tantivy_stages,
                ));
            }
        }
        match tantivy_index.delete_documents_by_file_ids_with_options_and_stage_durations(
            &deleted_file_ids,
            options.writer_options,
        ) {
            Ok(stages) => tantivy_stages = merge_tantivy_metrics(tantivy_stages, stages),
            Err(error) => {
                record_queue_failures(
                    queue,
                    &deleted_item_ids,
                    &error,
                    batch_options.max_attempts,
                )?;
                failed_count += deleted_item_ids.len();
                return Ok(production_result(
                    generation,
                    processed_count,
                    failed_count,
                    stats,
                    sqlite_metadata_write_micros,
                    tantivy_stages,
                ));
            }
        }
    }

    for item_id in successful_item_ids.iter().chain(deleted_item_ids.iter()) {
        queue.complete(*item_id)?;
        processed_count += 1;
    }

    Ok(production_result(
        generation,
        processed_count,
        failed_count,
        stats,
        sqlite_metadata_write_micros,
        tantivy_stages,
    ))
}

#[cfg(test)]
fn note_target_index_for_queue(
    metadata_store: &MetadataStore,
    batch_sources: &[SearchDocumentSource],
    deleted_file_ids: &[String],
) -> IndexingPipelineResult<NoteTargetIndex> {
    const PAGE_SIZE: usize = 4_096;

    let deleted_file_ids = deleted_file_ids.iter().cloned().collect::<HashSet<_>>();
    let mut targets = HashMap::<String, PathBuf>::new();
    let mut offset = 0;
    loop {
        let files = metadata_store.list_markdown_files(offset, PAGE_SIZE)?;
        if files.is_empty() {
            break;
        }
        offset += files.len();
        for file in files {
            if !deleted_file_ids.contains(&file.file_id) {
                targets.insert(file.file_id, file.relative_path);
            }
        }
    }

    for source in batch_sources {
        if !deleted_file_ids.contains(&source.file_id) {
            targets.insert(source.file_id.clone(), source.relative_path.clone());
        }
    }

    Ok(NoteTargetIndex::from_targets(targets.iter().map(
        |(file_id, relative_path)| NoteTarget {
            file_id,
            relative_path,
        },
    )))
}

#[cfg(test)]
fn production_result(
    generation: u64,
    processed_count: usize,
    failed_count: usize,
    stats: PipelineCorpusStats,
    sqlite_metadata_write_micros: u64,
    tantivy: TantivyIndexingStageMetrics,
) -> ProductionIndexingPipelineResult {
    ProductionIndexingPipelineResult::new(
        generation,
        processed_count,
        failed_count,
        ProductionIndexingStageMetrics {
            read_parse_sample_count: stats.read_micros.len(),
            read_parse_total_bytes: stats.read_parse_bytes,
            read_parse_peak_in_flight_items: 0,
            sqlite_metadata_write_micros,
            tantivy,
        },
    )
}

impl fmt::Display for IndexingPipelineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "indexing pipeline io error: {error}"),
            Self::Path(error) => write!(formatter, "indexing pipeline path error: {error}"),
            Self::Scan(error) => write!(formatter, "indexing pipeline scan error: {error}"),
            Self::Rebuild(error) => write!(formatter, "indexing pipeline rebuild error: {error}"),
            Self::Metadata(error) => {
                write!(formatter, "indexing pipeline metadata error: {error}")
            }
            Self::Queue(error) => write!(formatter, "indexing pipeline queue error: {error}"),
            Self::Tantivy(error) => write!(formatter, "indexing pipeline tantivy error: {error}"),
        }
    }
}

impl std::error::Error for IndexingPipelineError {}

impl From<std::io::Error> for IndexingPipelineError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<PathError> for IndexingPipelineError {
    fn from(error: PathError) -> Self {
        Self::Path(error)
    }
}

impl From<IndexRebuildError> for IndexingPipelineError {
    fn from(error: IndexRebuildError) -> Self {
        Self::Rebuild(error)
    }
}

impl From<MetadataStoreError> for IndexingPipelineError {
    fn from(error: MetadataStoreError) -> Self {
        Self::Metadata(error)
    }
}

impl From<IndexingQueueError> for IndexingPipelineError {
    fn from(error: IndexingQueueError) -> Self {
        Self::Queue(error)
    }
}

impl From<TantivySearchError> for IndexingPipelineError {
    fn from(error: TantivySearchError) -> Self {
        Self::Tantivy(error)
    }
}

fn duration_micros(duration: Duration) -> u64 {
    duration.as_micros().min(u128::from(u64::MAX)) as u64
}

fn duration_micros_nonzero(duration: Duration) -> u64 {
    duration_micros(duration).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::fs::index_directory::mark_engine_owned_for_test;
    use crate::adapters::sqlite::{
        FileIndexStatus, FileRecord, IndexSchemaMetadata, IndexingQueue,
    };
    use crate::adapters::sqlite::{IndexingQueueReason, IndexingQueueStatus};
    use crate::use_cases::index_rebuild::{
        IndexRebuildError, IndexRebuildPathError, IndexRebuildPaths,
    };
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};
    use tempfile::tempdir;

    #[test]
    fn production_pipeline_result_marks_success_and_partial_tiers() {
        let success = ProductionIndexingPipelineResult::new(
            7,
            3,
            0,
            ProductionIndexingStageMetrics {
                read_parse_sample_count: 3,
                read_parse_total_bytes: 128,
                ..Default::default()
            },
        );
        let partial = ProductionIndexingPipelineResult::new(
            7,
            2,
            1,
            ProductionIndexingStageMetrics {
                read_parse_sample_count: 3,
                read_parse_total_bytes: 128,
                ..Default::default()
            },
        );

        assert_eq!(success.generation, 7);
        assert_eq!(success.processed_count, 3);
        assert_eq!(success.failed_count, 0);
        assert_eq!(success.tier, IndexingPipelineTier::Complete);
        assert_eq!(partial.processed_count, 2);
        assert_eq!(partial.failed_count, 1);
        assert_eq!(partial.tier, IndexingPipelineTier::Error);
    }

    #[test]
    fn tier_serialization_covers_all_values() {
        let tiers = [
            (IndexingPipelineTier::Discovered, "\"discovered\""),
            (IndexingPipelineTier::MetadataReady, "\"metadata_ready\""),
            (IndexingPipelineTier::FilenameReady, "\"filename_ready\""),
            (IndexingPipelineTier::BodyIndexing, "\"body_indexing\""),
            (IndexingPipelineTier::Complete, "\"complete\""),
            (IndexingPipelineTier::Stale, "\"stale\""),
            (IndexingPipelineTier::Error, "\"error\""),
        ];

        for (tier, serialized) in tiers {
            assert_eq!(serde_json::to_string(&tier).expect("tier json"), serialized);
        }
    }

    #[test]
    fn snippet_storage_mode_defaults_to_stored_body_and_names_experiment() {
        assert_eq!(
            IndexingPipelineOptions::default().snippet_storage_mode,
            SnippetStorageMode::StoredBody
        );
        assert_eq!(SnippetStorageMode::StoredBody.config_name(), "stored_body");
        assert_eq!(
            SnippetStorageMode::LazySourceExperiment.config_name(),
            "lazy_source_experiment"
        );
    }

    #[test]
    fn queue_adapter_leases_limit_and_preserves_generation_reason() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md", "Guide.md", "Later.md"]);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &file_record(&root, "Home.md", 3),
                IndexingQueueReason::FileCreated,
            )
            .expect("home");
        queue
            .enqueue_file(
                &file_record(&root, "Guide.md", 3),
                IndexingQueueReason::FileChanged,
            )
            .expect("guide");
        queue
            .enqueue_file(
                &file_record(&root, "Later.md", 3),
                IndexingQueueReason::OwnSave,
            )
            .expect("later");

        let batch = lease_queue_batch(&mut queue, &root, 2).expect("lease");

        assert_eq!(batch.items.len(), 2);
        assert_eq!(batch.items[0].queue_item.generation, 3);
        assert_eq!(
            batch.items[0].queue_item.reason,
            IndexingQueueReason::FileCreated
        );
        assert!(batch.items[0].source.is_some());
        assert_eq!(queue.summary().expect("summary").in_progress, 2);
    }

    #[test]
    fn queue_item_source_rejects_db_tampered_paths_before_read_parse() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Safe.md"]);
        let absolute_path = root
            .canonical_root()
            .join("Safe.md")
            .to_string_lossy()
            .to_string();

        assert_tampered_queue_path_matches(&root, &absolute_path, |error| {
            matches!(error, PathError::AbsolutePath(_))
        });
        assert_tampered_queue_path_matches(&root, "../outside.md", |error| {
            matches!(error, PathError::OutsideVault(_))
        });
        assert_tampered_queue_path_matches(&root, "bad\0path.md", |error| {
            matches!(error, PathError::ContainsNul)
        });
        assert_tampered_queue_path_matches(
            &root,
            "file:///etc/passwd",
            |error| matches!(error, PathError::UrlScheme(scheme) if scheme == "file"),
        );
        assert_tampered_queue_path_matches(
            &root,
            "https://example.com/Note.md",
            |error| matches!(error, PathError::UrlScheme(scheme) if scheme == "https"),
        );
        assert_tampered_queue_path_matches(
            &root,
            "obsidian://open?vault=Codex",
            |error| matches!(error, PathError::UrlScheme(scheme) if scheme == "obsidian"),
        );
    }

    #[cfg(unix)]
    #[test]
    fn queue_item_source_rejects_symlinked_db_tampered_paths() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Safe.md"]);
        let outside = temp.path().join("outside");
        std::fs::create_dir_all(&outside).expect("outside dir");
        std::fs::write(outside.join("Secret.md"), "# Secret").expect("outside note");

        symlink(&outside, root.canonical_root().join("LinkedParent")).expect("symlinked parent");
        assert_tampered_queue_path_matches(&root, "LinkedParent/Secret.md", |error| {
            matches!(error, PathError::SymlinkEscape { .. })
        });

        symlink(
            outside.join("Secret.md"),
            root.canonical_root().join("SecretLink.md"),
        )
        .expect("symlinked note");
        assert_tampered_queue_path_matches(&root, "SecretLink.md", |error| {
            matches!(error, PathError::SymlinkEscape { .. })
        });
    }

    #[cfg(unix)]
    #[test]
    fn queue_item_source_rejects_hardlinked_notes() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Safe.md"]);
        let outside = temp.path().join("outside");
        std::fs::create_dir_all(&outside).expect("outside dir");
        std::fs::write(outside.join("Shared.md"), "# Secret").expect("outside note");
        let hardlinked_path = root.canonical_root().join("Shared.md");
        std::fs::hard_link(outside.join("Shared.md"), &hardlinked_path).expect("hardlink");
        let metadata = std::fs::metadata(&hardlinked_path).expect("metadata");
        let file = FileRecord {
            file_id: lookup_key(Path::new("Shared.md")),
            relative_path: PathBuf::from("Shared.md"),
            kind: ScanEntryKind::Markdown,
            size_bytes: metadata.len(),
            modified: metadata.modified().ok(),
            file_identity: FileIdentity::from_metadata(&metadata),
            content_hash: None,
            generation: 1,
            status: FileIndexStatus::SeenMetadata,
            last_error: None,
        };
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(&file, IndexingQueueReason::FileChanged)
            .expect("enqueue hardlink");

        let error = lease_queue_batch(&mut queue, &root, 1).expect_err("hardlink");

        assert!(matches!(
            error,
            IndexingPipelineError::Path(PathError::UnsupportedHardlink(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn read_parse_source_rejects_hardlinked_markdown_body() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Safe.md"]);
        let outside = temp.path().join("outside");
        std::fs::create_dir_all(&outside).expect("outside dir");
        std::fs::write(outside.join("Shared.md"), "# Secret").expect("outside note");
        let hardlinked_path = root.canonical_root().join("Shared.md");
        std::fs::hard_link(outside.join("Shared.md"), &hardlinked_path).expect("hardlink");
        let metadata = std::fs::metadata(&hardlinked_path).expect("metadata");
        let source = SearchDocumentSource {
            file_id: lookup_key(Path::new("Shared.md")),
            relative_path: PathBuf::from("Shared.md"),
            absolute_path: hardlinked_path,
            kind: ScanEntryKind::Markdown,
            size_bytes: metadata.len(),
            modified: metadata.modified().ok(),
            file_identity: FileIdentity::from_metadata(&metadata),
        };

        let error = match read_parse_source(&source) {
            Ok(_) => panic!("expected hardlinked read to fail"),
            Err(error) => error,
        };

        assert!(matches!(
            error,
            IndexingPipelineError::Io(error) if error.kind() == std::io::ErrorKind::PermissionDenied
        ));
    }

    #[test]
    fn process_queue_batch_marks_created_and_changed_files_complete() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md", "Guide.md"]);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &file_record(&root, "Home.md", 1),
                IndexingQueueReason::FileCreated,
            )
            .expect("home");
        queue
            .enqueue_file(
                &file_record(&root, "Guide.md", 1),
                IndexingQueueReason::FileChanged,
            )
            .expect("guide");
        let mut metadata_store = metadata_store();
        let mut tantivy = TantivySearchIndex::open_in_ram().expect("tantivy");

        let result = process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            QueueBatchIndexOptions {
                lease_limit: 2,
                max_attempts: 2,
            },
            &IndexingPipelineOptions::serial(),
        )
        .expect("process");

        assert_eq!(result.processed_count, 2);
        assert_eq!(result.failed_count, 0);
        assert_eq!(result.tier, IndexingPipelineTier::Complete);
        assert_eq!(queue.summary().expect("summary").completed, 2);
        assert_eq!(
            metadata_store
                .row_count(crate::adapters::sqlite::MetadataTable::Files)
                .expect("files"),
            2
        );
        assert_eq!(
            metadata_store
                .get_file(&lookup_key(Path::new("Home.md")))
                .expect("get")
                .expect("home")
                .status,
            FileIndexStatus::SearchIndexed
        );
        assert_eq!(tantivy.search("Home", 10).expect("search").len(), 1);
    }

    #[test]
    fn process_queue_batch_deletes_metadata_and_search_hits() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md"]);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        let home_generation_one = file_record(&root, "Home.md", 1);
        queue
            .enqueue_file(&home_generation_one, IndexingQueueReason::FileCreated)
            .expect("home");
        let mut metadata_store = metadata_store();
        let mut tantivy = TantivySearchIndex::open_in_ram().expect("tantivy");
        process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            QueueBatchIndexOptions::default(),
            &IndexingPipelineOptions::serial(),
        )
        .expect("initial process");
        assert_eq!(tantivy.search("Home", 10).expect("search").len(), 1);

        std::fs::remove_file(root.canonical_root().join("Home.md")).expect("delete file");
        let mut home_generation_two = home_generation_one;
        home_generation_two.mark_tombstoned(2);
        queue
            .enqueue_file(&home_generation_two, IndexingQueueReason::FileDeleted)
            .expect("delete enqueue");

        let result = process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            QueueBatchIndexOptions::default(),
            &IndexingPipelineOptions::serial(),
        )
        .expect("delete process");

        assert_eq!(result.processed_count, 1);
        assert_eq!(result.failed_count, 0);
        assert!(
            metadata_store
                .get_file(&lookup_key(Path::new("Home.md")))
                .expect("get")
                .is_none()
        );
        assert_eq!(tantivy.search("Home", 10).expect("search").len(), 0);
    }

    #[test]
    fn process_queue_batch_resolves_links_to_persisted_markdown_outside_batch() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md", "Target.md"]);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        let mut metadata_store = metadata_store();
        let mut tantivy = TantivySearchIndex::open_in_ram().expect("tantivy");
        queue
            .enqueue_file(
                &file_record(&root, "Target.md", 1),
                IndexingQueueReason::FileCreated,
            )
            .expect("target");
        process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            QueueBatchIndexOptions::default(),
            &IndexingPipelineOptions::serial(),
        )
        .expect("target process");
        std::fs::write(
            root.canonical_root().join("Home.md"),
            "# Home\n\n[[Target]]\n",
        )
        .expect("edit home");
        queue
            .enqueue_file(
                &file_record(&root, "Home.md", 2),
                IndexingQueueReason::FileChanged,
            )
            .expect("home");

        let result = process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            QueueBatchIndexOptions::default(),
            &IndexingPipelineOptions::serial(),
        )
        .expect("home process");

        assert_eq!(result.failed_count, 0);
        let links = metadata_store
            .outgoing_links(&lookup_key(Path::new("Home.md")), 0, 10)
            .expect("home links");
        assert_eq!(links.len(), 1);
        assert_eq!(
            links[0].resolved_target_file_id.as_deref(),
            Some(lookup_key(Path::new("Target.md")).as_str())
        );
    }

    #[test]
    fn process_queue_batch_does_not_resolve_links_to_deleted_markdown() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md", "Target.md"]);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        let mut metadata_store = metadata_store();
        let mut tantivy = TantivySearchIndex::open_in_ram().expect("tantivy");
        let target_generation_one = file_record(&root, "Target.md", 1);
        queue
            .enqueue_file(&target_generation_one, IndexingQueueReason::FileCreated)
            .expect("target");
        process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            QueueBatchIndexOptions::default(),
            &IndexingPipelineOptions::serial(),
        )
        .expect("target process");
        std::fs::remove_file(root.canonical_root().join("Target.md")).expect("delete target");
        std::fs::write(
            root.canonical_root().join("Home.md"),
            "# Home\n\n[[Target]]\n",
        )
        .expect("edit home");
        let mut deleted_target = target_generation_one;
        deleted_target.mark_tombstoned(2);
        queue
            .enqueue_file(&deleted_target, IndexingQueueReason::FileDeleted)
            .expect("delete enqueue");
        queue
            .enqueue_file(
                &file_record(&root, "Home.md", 2),
                IndexingQueueReason::FileChanged,
            )
            .expect("home");

        let result = process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            QueueBatchIndexOptions::default(),
            &IndexingPipelineOptions::serial(),
        )
        .expect("process");

        assert_eq!(result.failed_count, 0);
        assert!(
            metadata_store
                .get_file(&lookup_key(Path::new("Target.md")))
                .expect("target lookup")
                .is_none()
        );
        let links = metadata_store
            .outgoing_links(&lookup_key(Path::new("Home.md")), 0, 10)
            .expect("home links");
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].resolved_target_file_id, None);
    }

    #[test]
    fn process_queue_batch_records_retryable_failures() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &[]);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &missing_file_record("Missing.md", 1),
                IndexingQueueReason::FileChanged,
            )
            .expect("missing");
        let mut metadata_store = metadata_store();
        let mut tantivy = TantivySearchIndex::open_in_ram().expect("tantivy");
        let batch_options = QueueBatchIndexOptions {
            lease_limit: 1,
            max_attempts: 2,
        };

        let retry = process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            batch_options,
            &IndexingPipelineOptions::serial(),
        )
        .expect("retry");
        let item = queue
            .get_by_file_id(&lookup_key(Path::new("Missing.md")))
            .expect("lookup")
            .expect("item");
        assert_eq!(retry.failed_count, 1);
        assert_eq!(item.status, IndexingQueueStatus::Pending);
        assert_eq!(item.attempts, 1);

        let failed = process_indexing_queue_batch(
            &mut queue,
            &mut metadata_store,
            &mut tantivy,
            &root,
            batch_options,
            &IndexingPipelineOptions::serial(),
        )
        .expect("failed");
        let item = queue
            .get_by_file_id(&lookup_key(Path::new("Missing.md")))
            .expect("lookup")
            .expect("item");
        assert_eq!(failed.failed_count, 1);
        assert_eq!(item.status, IndexingQueueStatus::Failed);
        assert_eq!(item.attempts, 2);
        assert!(item.last_error.is_some());
    }

    #[test]
    fn interrupted_queue_batch_recovers_and_leases_again() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md"]);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &file_record(&root, "Home.md", 1),
                IndexingQueueReason::InitialScan,
            )
            .expect("home");
        let first = lease_queue_batch(&mut queue, &root, 1).expect("lease");
        let item_id = first.items[0].queue_item.item_id;

        assert_eq!(queue.recover_interrupted().expect("recover"), 1);
        let second = lease_queue_batch(&mut queue, &root, 1).expect("lease again");

        assert_eq!(second.items[0].queue_item.item_id, item_id);
        assert_eq!(
            second.items[0].queue_item.status,
            IndexingQueueStatus::InProgress
        );
    }

    #[test]
    fn full_rebuild_writes_artifacts_under_rebuild_directory() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md", "Guide.md"]);
        let paths = rebuild_paths(temp.path());
        std::fs::create_dir_all(&paths.data_directory).expect("data");
        std::fs::write(paths.data_directory.join("old.index"), "old").expect("old data");
        let loaded = load_search_document_sources(&root).expect("sources");

        let result = run_full_rebuild_pipeline(
            &paths,
            &loaded.sources,
            &IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 4),
            &IndexingPipelineOptions::serial(),
        )
        .expect("rebuild");

        assert_eq!(result.processed_count, 2);
        assert_eq!(result.tier, IndexingPipelineTier::Complete);
        assert!(result.time_to_usable_micros.is_some_and(|value| value > 0));
        let tiers = result
            .tier_transitions
            .iter()
            .map(|transition| transition.tier)
            .collect::<Vec<_>>();
        assert_eq!(
            tiers,
            vec![
                IndexingPipelineTier::Discovered,
                IndexingPipelineTier::MetadataReady,
                IndexingPipelineTier::BodyIndexing,
                IndexingPipelineTier::FilenameReady,
                IndexingPipelineTier::Complete,
            ]
        );
        assert!(paths.data_directory.join("old.index").exists());
        assert!(paths.rebuild_directory.join("metadata.sqlite").exists());
        assert!(paths.rebuild_directory.join("tantivy").exists());
    }

    #[test]
    fn full_rebuild_persists_resolved_wikilink_metadata() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md", "Target.md"]);
        std::fs::write(
            root.canonical_root().join("Home.md"),
            "# Home\n\n[[Target]]\n",
        )
        .expect("edit home");
        let paths = rebuild_paths(temp.path());
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 4);
        let loaded = load_search_document_sources(&root).expect("sources");

        let result = run_full_rebuild_pipeline(
            &paths,
            &loaded.sources,
            &metadata,
            &IndexingPipelineOptions::serial(),
        )
        .expect("rebuild");

        assert_eq!(result.failed_count, 0);
        let metadata_store =
            MetadataStore::open(paths.rebuild_directory.join("metadata.sqlite"), &metadata)
                .expect("metadata");
        let links = metadata_store
            .outgoing_links(&lookup_key(Path::new("Home.md")), 0, 10)
            .expect("home links");
        assert_eq!(links.len(), 1);
        assert_eq!(
            links[0].resolved_target_file_id.as_deref(),
            Some(lookup_key(Path::new("Target.md")).as_str())
        );
    }

    #[test]
    fn full_rebuild_commits_only_after_stores_succeed() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md"]);
        let paths = rebuild_paths(temp.path());
        mark_engine_owned_for_test(&paths.data_directory).expect("data");
        std::fs::write(paths.data_directory.join("indexing-queue.sqlite"), "old")
            .expect("old data");
        let loaded = load_search_document_sources(&root).expect("sources");

        let result = run_full_rebuild_pipeline_and_commit(
            &paths,
            &loaded.sources,
            &IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 5),
            &IndexingPipelineOptions::serial(),
        )
        .expect("rebuild commit");

        assert_eq!(result.processed_count, 1);
        assert!(!paths.rebuild_directory.exists());
        assert!(!paths.data_directory.join("indexing-queue.sqlite").exists());
        assert!(paths.data_directory.join("metadata.sqlite").exists());
        assert!(paths.data_directory.join("tantivy").exists());
    }

    #[test]
    fn failed_rebuild_keeps_active_data_uncommitted_when_rebuild_has_unknown_root_file() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md"]);
        let paths = rebuild_paths(temp.path());
        mark_engine_owned_for_test(&paths.data_directory).expect("data");
        std::fs::write(paths.data_directory.join("metadata.sqlite"), "old").expect("old data");
        std::fs::create_dir_all(&paths.rebuild_directory).expect("rebuild");
        std::fs::write(paths.rebuild_directory.join("stale.tmp"), "stale")
            .expect("unknown rebuild file");
        let loaded = load_search_document_sources(&root).expect("sources");

        let result = run_full_rebuild_pipeline_and_commit(
            &paths,
            &loaded.sources,
            &IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 6),
            &IndexingPipelineOptions::serial(),
        );

        assert!(matches!(
            result,
            Err(IndexingPipelineError::Rebuild(
                IndexRebuildError::InvalidPath(
                    IndexRebuildPathError::UnexpectedIndexDirectoryEntry
                )
            ))
        ));
        assert_eq!(
            std::fs::read_to_string(paths.data_directory.join("metadata.sqlite"))
                .expect("old data"),
            "old"
        );
        assert_eq!(
            std::fs::read_to_string(paths.rebuild_directory.join("stale.tmp"))
                .expect("unknown rebuild file"),
            "stale"
        );
        assert!(!paths.data_directory.join("stale.tmp").exists());
    }

    #[test]
    fn full_rebuild_resets_known_markerless_rebuild_artifacts_without_touching_vault() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md"]);
        let paths = rebuild_paths(temp.path());
        mark_engine_owned_for_test(&paths.data_directory).expect("data");
        std::fs::write(paths.data_directory.join("indexing-queue.sqlite"), "old")
            .expect("old data");
        std::fs::create_dir_all(&paths.rebuild_directory).expect("rebuild");
        std::fs::write(
            paths.rebuild_directory.join("metadata.sqlite"),
            "stale metadata",
        )
        .expect("stale metadata");
        std::fs::create_dir_all(paths.rebuild_directory.join("tantivy")).expect("tantivy");
        std::fs::write(
            paths.rebuild_directory.join("tantivy").join("stale"),
            "stale",
        )
        .expect("stale tantivy");
        let loaded = load_search_document_sources(&root).expect("sources");

        let result = run_full_rebuild_pipeline_and_commit(
            &paths,
            &loaded.sources,
            &IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 6),
            &IndexingPipelineOptions::serial(),
        )
        .expect("rebuild commit");

        assert_eq!(result.processed_count, 1);
        assert!(!paths.data_directory.join("indexing-queue.sqlite").exists());
        assert!(paths.data_directory.join("metadata.sqlite").exists());
        assert!(paths.data_directory.join("tantivy").exists());
        assert!(!paths.data_directory.join("tantivy").join("stale").exists());
        assert!(!paths.data_directory.join("rebuild.json").exists());
        assert!(!paths.rebuild_directory.exists());
    }

    #[test]
    fn progress_snapshot_serializes_counts_and_redacted_stage_only() {
        let snapshot = IndexingProgressSnapshot::from_queue_summary(
            9,
            IndexingPipelineTier::Complete,
            IndexingProgressStage::MetadataWrite,
            IndexingQueueSummary {
                pending: 1,
                in_progress: 2,
                completed: 3,
                failed: 4,
                cancelled: 5,
            },
        );

        let json = serde_json::to_string(&snapshot).expect("json");

        assert!(json.contains("metadata_write"));
        assert!(json.contains("\"pending_count\":1"));
        assert!(!json.contains(".md"));
        assert!(!json.contains("Home"));
        assert!(!json.contains("/"));

        let stages = [
            (IndexingProgressStage::LeaseQueue, "lease_queue"),
            (IndexingProgressStage::ReadParse, "read_parse"),
            (IndexingProgressStage::MetadataWrite, "metadata_write"),
            (IndexingProgressStage::SearchIndex, "search_index"),
            (IndexingProgressStage::CommitRebuild, "commit_rebuild"),
        ];
        for (stage, serialized) in stages {
            assert_eq!(
                serde_json::to_string(&stage).expect("stage json"),
                format!("\"{serialized}\"")
            );
        }
    }

    fn metadata_store() -> MetadataStore {
        MetadataStore::open_in_memory(&IndexSchemaMetadata::new(
            "sqlite",
            "metadata-v1",
            "none",
            1,
        ))
        .expect("metadata store")
    }

    fn fixture_vault(parent: &Path, files: &[&str]) -> VaultRoot {
        let vault = parent.join("vault");
        std::fs::create_dir_all(&vault).expect("vault dir");
        for file in files {
            std::fs::write(
                vault.join(file),
                format!("# {}\nBody", file.trim_end_matches(".md")),
            )
            .expect("write fixture");
        }
        VaultRoot::open(&vault).expect("vault root")
    }

    fn rebuild_paths(parent: &Path) -> IndexRebuildPaths {
        let index_root = parent.join("support").join("Indexes").join("vault-id");
        IndexRebuildPaths::new(
            parent.join("vault"),
            &index_root,
            index_root.join("data"),
            index_root.join("rebuild"),
        )
    }

    fn file_record(root: &VaultRoot, relative_path: &str, generation: u64) -> FileRecord {
        let resolved = root
            .resolve_existing_relative(relative_path)
            .expect("resolved path");
        let metadata = std::fs::metadata(&resolved.absolute_path).expect("metadata");
        FileRecord {
            file_id: lookup_key(&PathBuf::from(relative_path)),
            relative_path: PathBuf::from(relative_path),
            kind: ScanEntryKind::Markdown,
            size_bytes: metadata.len(),
            modified: metadata.modified().ok(),
            file_identity: resolved.file_identity,
            content_hash: None,
            generation,
            status: FileIndexStatus::SeenMetadata,
            last_error: None,
        }
    }

    fn missing_file_record(relative_path: &str, generation: u64) -> FileRecord {
        FileRecord {
            file_id: lookup_key(&PathBuf::from(relative_path)),
            relative_path: PathBuf::from(relative_path),
            kind: ScanEntryKind::Markdown,
            size_bytes: 0,
            modified: None,
            file_identity: FileIdentity {
                device: 0,
                inode: 0,
            },
            content_hash: None,
            generation,
            status: FileIndexStatus::SeenMetadata,
            last_error: None,
        }
    }

    fn assert_tampered_queue_path_matches(
        root: &VaultRoot,
        tampered_relative_path: &str,
        predicate: impl FnOnce(&PathError) -> bool,
    ) {
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        let file = file_record(root, "Safe.md", 1);
        queue
            .enqueue_file(&file, IndexingQueueReason::FileChanged)
            .expect("enqueue safe file");
        queue
            .tamper_relative_path_for_test(&file.file_id, tampered_relative_path)
            .expect("tamper path");

        let error = lease_queue_batch(&mut queue, root, 1).expect_err("reject tampered path");

        let IndexingPipelineError::Path(path_error) = error else {
            panic!("expected path error for {tampered_relative_path:?}");
        };
        assert!(
            predicate(&path_error),
            "unexpected path error for {tampered_relative_path:?}: {path_error:?}"
        );
    }
}
