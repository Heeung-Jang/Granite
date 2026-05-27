use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::sync_channel;
use std::thread;
use std::time::{Duration, Instant, SystemTime};

use crate::adapters::fs::markdown_reader::read_markdown_body;
use crate::adapters::sqlite::{
    AttachmentRecord, FileIndexStatus, FileMetadataRecords, FileRecord, HeadingRecord,
    LinkEdgeRecord, PropertyRecord, TagRecord, TagSource, slugify_heading,
};
use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
use crate::indexing_pipeline::{
    IndexingPipelineError, IndexingPipelineOptions, IndexingPipelineResult, SearchDocumentSource,
};
use crate::parser::{ParsedMarkdown, PropertyValue, parse_markdown};
use crate::paths::FileIdentity;
use crate::scanner::ScanEntryKind;
use crate::sqlite_fts::SearchDocument;

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
