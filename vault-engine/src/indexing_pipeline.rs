use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::sync_channel;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use serde::Serialize;

use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
use crate::index::{
    AttachmentRecord, FileIndexStatus, FileMetadataRecords, FileRecord, HeadingRecord,
    IndexSchemaMetadata, LinkEdgeRecord, MetadataStore, MetadataStoreError, PropertyRecord,
    TagRecord, TagSource, slugify_heading,
};
use crate::index_rebuild::{IndexRebuildError, IndexRebuildPaths, commit_index_rebuild};
use crate::indexing_queue::{
    IndexingQueue, IndexingQueueError, IndexingQueueItem, IndexingQueueReason, IndexingQueueSummary,
};
use crate::parser::{ParsedMarkdown, PropertyValue, parse_markdown};
use crate::paths::{FileIdentity, PathError, VaultRoot, lookup_key};
use crate::scanner::{ScanEntryKind, scan_vault};
use crate::sqlite_fts::SearchDocument;
use crate::tantivy_search::{
    TantivyIndexingStageMetrics, TantivySearchError, TantivySearchIndex, TantivyWriterOptions,
};

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
pub enum SnippetStorageMode {
    StoredBody,
    LazySourceExperiment,
}

impl SnippetStorageMode {
    pub fn config_name(self) -> &'static str {
        match self {
            Self::StoredBody => "stored_body",
            Self::LazySourceExperiment => "lazy_source_experiment",
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
    Stale,
    Error,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum IndexingProgressStage {
    LeaseQueue,
    ReadParse,
    MetadataWrite,
    SearchIndex,
    CommitRebuild,
}

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueueBatchIndexOptions {
    pub lease_limit: usize,
    pub max_attempts: u32,
}

impl Default for QueueBatchIndexOptions {
    fn default() -> Self {
        Self {
            lease_limit: 32,
            max_attempts: 3,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueLeaseBatch {
    pub items: Vec<QueuePipelineItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueuePipelineItem {
    pub queue_item: IndexingQueueItem,
    pub source: Option<SearchDocumentSource>,
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
    pub tier: IndexingPipelineTier,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PipelineCorpusStageMetrics {
    pub scan_micros: u64,
    pub source_collection_micros: u64,
}

pub struct TimedSearchDocument {
    pub document: SearchDocument,
    pub work_item: ParsedSearchWorkItem,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedSearchWorkItem {
    pub source_index: usize,
    pub file_id: String,
    pub relative_path: PathBuf,
    pub title: String,
    pub body_len: usize,
    pub metadata_counts: ParsedMetadataCounts,
    pub metadata_records: FileMetadataRecords,
    pub file_identity: FileIdentity,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub timing: ReadParseTiming,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ParsedMetadataCounts {
    pub link_count: usize,
    pub tag_count: usize,
    pub property_count: usize,
    pub heading_count: usize,
    pub attachment_count: usize,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ReadParseTiming {
    pub read_micros: u64,
    pub parse_micros: u64,
    pub combined_micros: u64,
    pub bytes: u64,
}

pub struct ReadParsePipelineRun {
    pub stats: PipelineCorpusStats,
    pub peak_in_flight_items: usize,
}

pub struct TantivyPipelineRun {
    pub stats: PipelineCorpusStats,
    pub peak_in_flight_items: usize,
    pub stages: TantivyIndexingStageMetrics,
}

#[derive(Default)]
pub struct PipelineCorpusStats {
    pub document_count: usize,
    pub total_document_bytes: u64,
    first_document_index: Option<usize>,
    first_document: Option<SearchDocument>,
    pub read_micros: Vec<u64>,
    pub parse_micros: Vec<u64>,
    pub combined_micros: Vec<u64>,
    pub read_parse_bytes: u64,
}

impl PipelineCorpusStats {
    pub fn record(&mut self, document: &SearchDocument) {
        self.document_count += 1;
        self.total_document_bytes += document_bytes(document);
    }

    pub fn record_timed(&mut self, timed: &TimedSearchDocument) {
        self.record(&timed.document);
        if self
            .first_document_index
            .is_none_or(|index| timed.work_item.source_index < index)
        {
            self.first_document_index = Some(timed.work_item.source_index);
            self.first_document = Some(timed.document.clone());
        }
        self.read_micros.push(timed.work_item.timing.read_micros);
        self.parse_micros.push(timed.work_item.timing.parse_micros);
        self.combined_micros
            .push(timed.work_item.timing.combined_micros);
        self.read_parse_bytes += timed.work_item.timing.bytes;
    }

    pub fn first_document(&self) -> Option<&SearchDocument> {
        self.first_document.as_ref()
    }
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
        tier: IndexingPipelineTier::Discovered,
    })
}

pub fn lease_queue_batch(
    queue: &mut IndexingQueue,
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

pub fn process_indexing_queue_batch(
    queue: &mut IndexingQueue,
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
    let options = pipeline_options.normalized();

    for queue_item in queue_items {
        generation = generation.max(queue_item.generation);
        if queue_item.reason == IndexingQueueReason::FileDeleted {
            deleted_file_ids.push(queue_item.file_id.clone());
            deleted_item_ids.push(queue_item.item_id);
            continue;
        }

        let source = match source_for_queue_item(root, &queue_item) {
            Ok(Some(source)) => source,
            Ok(None) => {
                successful_item_ids.push(queue_item.item_id);
                continue;
            }
            Err(error) => {
                record_queue_failure(
                    queue,
                    queue_item.item_id,
                    &error,
                    batch_options.max_attempts,
                )?;
                failed_count += 1;
                continue;
            }
        };

        match read_parse_source(&source) {
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
    fs::create_dir_all(&paths.rebuild_directory)?;
    let options = pipeline_options.normalized();
    let metadata_path = paths.rebuild_directory.join("metadata.sqlite");
    remove_sqlite_files(&metadata_path)?;
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
        Ok::<(), IndexingPipelineError>(())
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
    reset_directory(&tantivy_dir)?;
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

pub fn read_search_document(
    source: &SearchDocumentSource,
) -> IndexingPipelineResult<SearchDocument> {
    Ok(read_parse_source(source)?.document)
}

pub fn read_parse_source(
    source: &SearchDocumentSource,
) -> IndexingPipelineResult<TimedSearchDocument> {
    read_parse_source_at(0, source)
}

pub fn read_parse_source_at(
    source_index: usize,
    source: &SearchDocumentSource,
) -> IndexingPipelineResult<TimedSearchDocument> {
    debug_assert_eq!(source.kind, ScanEntryKind::Markdown);
    let combined_start = Instant::now();
    let (body, read_micros) = read_markdown_body(&source.absolute_path)?;
    let parse_start = Instant::now();
    let parsed = parse_markdown(&body);
    let parse_micros = duration_micros_nonzero(parse_start.elapsed());
    let combined_micros = duration_micros_nonzero(combined_start.elapsed());
    let bytes = body.len() as u64;
    let title = parsed
        .headings
        .first()
        .map(|heading| heading.text.clone())
        .unwrap_or_else(|| fallback_title(&source.relative_path));
    let metadata_counts = parsed_metadata_counts(&parsed);
    let metadata_records = parsed_metadata_records(source, &parsed);
    Ok(TimedSearchDocument {
        document: SearchDocument {
            file_id: source.file_id.clone(),
            path: source.relative_path.to_string_lossy().to_string(),
            title: title.clone(),
            body,
        },
        work_item: ParsedSearchWorkItem {
            source_index,
            file_id: source.file_id.clone(),
            relative_path: source.relative_path.clone(),
            title,
            body_len: bytes as usize,
            metadata_counts,
            metadata_records,
            file_identity: source.file_identity.clone(),
            size_bytes: source.size_bytes,
            modified: source.modified,
            timing: ReadParseTiming {
                read_micros,
                parse_micros,
                combined_micros,
                bytes,
            },
        },
    })
}

pub fn run_read_parse_pipeline<F, E>(
    sources: &[SearchDocumentSource],
    options: &IndexingPipelineOptions,
    mut consume: F,
) -> Result<ReadParsePipelineRun, E>
where
    F: FnMut(TimedSearchDocument) -> Result<(), E>,
    E: From<IndexingPipelineError>,
{
    let options = options.normalized();
    let (sender, receiver) =
        sync_channel::<IndexingPipelineResult<TimedSearchDocument>>(options.channel_capacity);
    let next_source = AtomicUsize::new(0);
    let in_flight = Arc::new(AtomicUsize::new(0));
    let peak_in_flight = Arc::new(AtomicUsize::new(0));
    let mut stats = PipelineCorpusStats::default();

    thread::scope(|scope| {
        for _ in 0..options.read_parse_workers {
            let sender = sender.clone();
            let in_flight = Arc::clone(&in_flight);
            let peak_in_flight = Arc::clone(&peak_in_flight);
            let next_source = &next_source;
            scope.spawn(move || {
                loop {
                    let index = next_source.fetch_add(1, Ordering::Relaxed);
                    let Some(source) = sources.get(index) else {
                        break;
                    };
                    let result = read_parse_source_at(index, source);
                    let current_in_flight = in_flight.fetch_add(1, Ordering::AcqRel) + 1;
                    update_peak_in_flight(&peak_in_flight, current_in_flight);
                    if sender.send(result).is_err() {
                        in_flight.fetch_sub(1, Ordering::AcqRel);
                        break;
                    }
                }
            });
        }
        drop(sender);

        for result in receiver {
            in_flight.fetch_sub(1, Ordering::AcqRel);
            let timed = result.map_err(E::from)?;
            stats.record_timed(&timed);
            consume(timed)?;
        }

        Ok::<(), E>(())
    })?;

    Ok(ReadParsePipelineRun {
        stats,
        peak_in_flight_items: peak_in_flight.load(Ordering::Acquire),
    })
}

pub fn run_tantivy_rebuild_pipeline(
    index: &mut TantivySearchIndex,
    sources: &[SearchDocumentSource],
    options: &IndexingPipelineOptions,
) -> IndexingPipelineResult<TantivyPipelineRun> {
    let options = options.normalized();
    let (sender, receiver) =
        sync_channel::<IndexingPipelineResult<TimedSearchDocument>>(options.channel_capacity);
    let next_source = AtomicUsize::new(0);
    let in_flight = Arc::new(AtomicUsize::new(0));
    let peak_in_flight = Arc::new(AtomicUsize::new(0));
    let mut stats = PipelineCorpusStats::default();

    let stages = thread::scope(|scope| {
        for _ in 0..options.read_parse_workers {
            let sender = sender.clone();
            let in_flight = Arc::clone(&in_flight);
            let peak_in_flight = Arc::clone(&peak_in_flight);
            let next_source = &next_source;
            scope.spawn(move || {
                loop {
                    let index = next_source.fetch_add(1, Ordering::Relaxed);
                    let Some(source) = sources.get(index) else {
                        break;
                    };
                    let result = read_parse_source_at(index, source);
                    let current_in_flight = in_flight.fetch_add(1, Ordering::AcqRel) + 1;
                    update_peak_in_flight(&peak_in_flight, current_in_flight);
                    if sender.send(result).is_err() {
                        in_flight.fetch_sub(1, Ordering::AcqRel);
                        break;
                    }
                }
            });
        }
        drop(sender);

        let documents = receiver.into_iter().map(|result| {
            in_flight.fetch_sub(1, Ordering::AcqRel);
            let timed = result?;
            stats.record_timed(&timed);
            Ok::<SearchDocument, IndexingPipelineError>(timed.document)
        });

        index.add_documents_for_rebuild_from_result_iter_with_options_and_stage_durations(
            documents,
            options.writer_options,
        )
    })?;

    Ok(TantivyPipelineRun {
        stats,
        peak_in_flight_items: peak_in_flight.load(Ordering::Acquire),
        stages,
    })
}

fn source_for_queue_item(
    root: &VaultRoot,
    queue_item: &IndexingQueueItem,
) -> IndexingPipelineResult<Option<SearchDocumentSource>> {
    if queue_item.reason == IndexingQueueReason::FileDeleted {
        return Ok(None);
    }
    let relative_path = queue_item.relative_path.to_string_lossy();
    let resolved = root.resolve_existing_relative(relative_path.as_ref())?;

    Ok(Some(SearchDocumentSource {
        relative_path: resolved.relative_path,
        absolute_path: resolved.absolute_path,
        file_id: queue_item.file_id.clone(),
        kind: queue_item.kind,
        size_bytes: queue_item.size_bytes,
        modified: queue_item.modified,
        file_identity: resolved.file_identity,
    }))
}

fn record_queue_failure(
    queue: &mut IndexingQueue,
    item_id: i64,
    error: &impl fmt::Display,
    max_attempts: u32,
) -> IndexingPipelineResult<()> {
    queue.record_failure(item_id, error.to_string(), max_attempts)?;
    Ok(())
}

fn record_queue_failures(
    queue: &mut IndexingQueue,
    item_ids: &[i64],
    error: &impl fmt::Display,
    max_attempts: u32,
) -> IndexingPipelineResult<()> {
    for item_id in item_ids {
        record_queue_failure(queue, *item_id, error, max_attempts)?;
    }
    Ok(())
}

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

fn merge_tantivy_metrics(
    left: TantivyIndexingStageMetrics,
    right: TantivyIndexingStageMetrics,
) -> TantivyIndexingStageMetrics {
    TantivyIndexingStageMetrics {
        add_micros: left.add_micros + right.add_micros,
        commit_micros: left.commit_micros + right.commit_micros,
        reader_reload_micros: left.reader_reload_micros + right.reader_reload_micros,
        added_document_count: left.added_document_count + right.added_document_count,
        deleted_document_count: left.deleted_document_count + right.deleted_document_count,
        skipped_document_count: left.skipped_document_count + right.skipped_document_count,
        failed_document_count: left.failed_document_count + right.failed_document_count,
    }
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

fn read_markdown_body(path: &Path) -> IndexingPipelineResult<(String, u64)> {
    let start = Instant::now();
    let body = fs::read_to_string(path)?;
    let read_micros = duration_micros_nonzero(start.elapsed());
    Ok((body, read_micros))
}

fn parsed_metadata_counts(parsed: &ParsedMarkdown) -> ParsedMetadataCounts {
    ParsedMetadataCounts {
        link_count: parsed.wikilinks.len()
            + parsed.embeds.len()
            + parsed
                .markdown_links
                .iter()
                .filter(|link| !link.image)
                .count(),
        tag_count: parsed.tags.len(),
        property_count: parsed.properties.len(),
        heading_count: parsed.headings.len(),
        attachment_count: parsed.embeds.len()
            + parsed
                .markdown_links
                .iter()
                .filter(|link| link.image)
                .count(),
    }
}

fn parsed_metadata_records(
    source: &SearchDocumentSource,
    parsed: &ParsedMarkdown,
) -> FileMetadataRecords {
    let file_id = source.file_id.clone();
    let frontmatter_tags = frontmatter_tags(parsed);
    let mut links = Vec::new();
    let mut attachments = Vec::new();

    for link in &parsed.wikilinks {
        links.push(LinkEdgeRecord {
            source_file_id: file_id.clone(),
            target_text: link.target.clone(),
            resolved_target_file_id: None,
            heading: link.heading.clone(),
            alias: link.alias.clone(),
            is_embed: false,
        });
    }

    for embed in &parsed.embeds {
        links.push(LinkEdgeRecord {
            source_file_id: file_id.clone(),
            target_text: embed.target.clone(),
            resolved_target_file_id: None,
            heading: embed.heading.clone(),
            alias: embed.alias.clone(),
            is_embed: true,
        });
        attachments.push(AttachmentRecord {
            source_file_id: file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: embed.target.clone(),
            state: AttachmentResolutionState::Unsupported,
        });
    }

    for link in &parsed.markdown_links {
        if link.image {
            attachments.push(AttachmentRecord {
                source_file_id: file_id.clone(),
                source: AttachmentReferenceSource::MarkdownImage,
                raw_target: link.target.clone(),
                state: AttachmentResolutionState::Unsupported,
            });
        } else {
            links.push(LinkEdgeRecord {
                source_file_id: file_id.clone(),
                target_text: link.target.clone(),
                resolved_target_file_id: None,
                heading: None,
                alias: Some(link.text.clone()),
                is_embed: false,
            });
            if !link.target.ends_with(".md") {
                attachments.push(AttachmentRecord {
                    source_file_id: file_id.clone(),
                    source: AttachmentReferenceSource::MarkdownLink,
                    raw_target: link.target.clone(),
                    state: AttachmentResolutionState::Unsupported,
                });
            }
        }
    }

    FileMetadataRecords {
        file: FileRecord {
            file_id: file_id.clone(),
            relative_path: source.relative_path.clone(),
            kind: source.kind,
            size_bytes: source.size_bytes,
            modified: source.modified,
            file_identity: source.file_identity.clone(),
            content_hash: None,
            generation: 0,
            status: FileIndexStatus::Parsed,
            last_error: None,
        },
        links,
        tags: parsed
            .tags
            .iter()
            .map(|tag| TagRecord {
                file_id: file_id.clone(),
                tag: tag.clone(),
                source: if frontmatter_tags.contains(tag) {
                    TagSource::Frontmatter
                } else {
                    TagSource::Inline
                },
            })
            .collect(),
        properties: parsed
            .properties
            .iter()
            .map(|(key, value)| PropertyRecord::from_property_value(file_id.clone(), key, value))
            .collect(),
        headings: parsed
            .headings
            .iter()
            .map(|heading| HeadingRecord {
                file_id: file_id.clone(),
                slug: slugify_heading(&heading.text),
                title: heading.text.clone(),
                level: heading.level,
                byte_offset: None,
            })
            .collect(),
        attachments,
    }
}

fn frontmatter_tags(parsed: &ParsedMarkdown) -> Vec<String> {
    match parsed.properties.get("tags") {
        Some(PropertyValue::String(value)) => vec![value.clone()],
        Some(PropertyValue::List(values)) => values.clone(),
        _ => Vec::new(),
    }
}

fn update_peak_in_flight(peak: &AtomicUsize, candidate: usize) {
    let mut current = peak.load(Ordering::Acquire);
    while candidate > current {
        match peak.compare_exchange(current, candidate, Ordering::AcqRel, Ordering::Acquire) {
            Ok(_) => break,
            Err(observed) => current = observed,
        }
    }
}

fn fallback_title(relative_path: &Path) -> String {
    relative_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Untitled")
        .to_string()
}

fn document_bytes(document: &SearchDocument) -> u64 {
    document.path.len() as u64 + document.title.len() as u64 + document.body.len() as u64
}

fn remove_file_if_exists(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn remove_sqlite_files(path: &Path) -> std::io::Result<()> {
    remove_file_if_exists(path)?;
    remove_file_if_exists(&path.with_extension("sqlite-wal"))?;
    remove_file_if_exists(&path.with_extension("sqlite-shm"))?;
    Ok(())
}

fn reset_directory(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_dir_all(path)?;
    }
    fs::create_dir_all(path)
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
    use crate::index::{FileIndexStatus, IndexSchemaMetadata};
    use crate::indexing_queue::{IndexingQueueReason, IndexingQueueStatus};
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
                .row_count(crate::index::MetadataTable::Files)
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
    fn full_rebuild_commits_only_after_stores_succeed() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md"]);
        let paths = rebuild_paths(temp.path());
        std::fs::create_dir_all(&paths.data_directory).expect("data");
        std::fs::write(paths.data_directory.join("old.index"), "old").expect("old data");
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
        assert!(!paths.data_directory.join("old.index").exists());
        assert!(paths.data_directory.join("metadata.sqlite").exists());
        assert!(paths.data_directory.join("tantivy").exists());
    }

    #[test]
    fn failed_rebuild_keeps_active_data_uncommitted() {
        let temp = tempdir().expect("tempdir");
        let root = fixture_vault(temp.path(), &["Home.md"]);
        let paths = rebuild_paths(temp.path());
        std::fs::create_dir_all(&paths.data_directory).expect("data");
        std::fs::write(paths.data_directory.join("old.index"), "old").expect("old data");
        std::fs::create_dir_all(&paths.rebuild_directory).expect("rebuild");
        std::fs::write(paths.rebuild_directory.join("tantivy"), "not a directory")
            .expect("tantivy blocker");
        let loaded = load_search_document_sources(&root).expect("sources");

        let result = run_full_rebuild_pipeline_and_commit(
            &paths,
            &loaded.sources,
            &IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 6),
            &IndexingPipelineOptions::serial(),
        );

        assert!(matches!(result, Err(IndexingPipelineError::Io(_))));
        assert!(paths.data_directory.join("old.index").exists());
        assert!(paths.rebuild_directory.exists());
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
}
