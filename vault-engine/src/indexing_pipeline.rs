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
    LinkEdgeRecord, PropertyRecord, TagRecord, TagSource, slugify_heading,
};
use crate::parser::{ParsedMarkdown, PropertyValue, parse_markdown};
use crate::paths::{FileIdentity, VaultRoot, lookup_key};
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
pub enum SnippetStorageMode {
    StoredBody,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexingPipelineTier {
    Complete,
    Error,
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
    pub stages: ProductionIndexingStageMetrics,
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
            stages,
        }
    }
}

#[derive(Debug)]
pub enum IndexingPipelineError {
    Io(std::io::Error),
    Scan(String),
    Tantivy(TantivySearchError),
}

pub type IndexingPipelineResult<T> = Result<T, IndexingPipelineError>;

#[derive(Debug, Clone)]
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
    })
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

impl fmt::Display for IndexingPipelineError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "indexing pipeline io error: {error}"),
            Self::Scan(error) => write!(formatter, "indexing pipeline scan error: {error}"),
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

fn duration_micros(duration: Duration) -> u64 {
    duration.as_micros().min(u128::from(u64::MAX)) as u64
}

fn duration_micros_nonzero(duration: Duration) -> u64 {
    duration_micros(duration).max(1)
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
