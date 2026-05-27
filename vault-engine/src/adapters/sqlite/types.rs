use std::path::PathBuf;

use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};

use crate::paths::lookup_key;
use crate::scanner::ScanEntry;

pub const INDEX_SCHEMA_VERSION: u32 = 2;
pub const MAX_INDEX_ERROR_CHARS: usize = 512;

pub use crate::core::metadata::{
    AttachmentRecord, FileIndexStatus, FileMetadataRecords, FileRecord, HeadingRecord,
    IndexPropertyValue, IndexSchemaMetadata, IndexedFileRecords, LinkEdgeRecord, PropertyRecord,
    TagRecord, TagSource,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphFileRecord {
    pub file_id: String,
    pub relative_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphResolvedEdgeRecord {
    pub source_file_id: String,
    pub source_relative_path: PathBuf,
    pub target_file_id: String,
    pub target_relative_path: PathBuf,
    pub weight: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphUnresolvedEdgeRecord {
    pub source_file_id: String,
    pub source_relative_path: PathBuf,
    pub target_text: String,
    pub weight: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphTagRecord {
    pub file_id: String,
    pub tag: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphQueryStage {
    Files,
    ResolvedEdges,
    ResolvedEdgesCompact,
    UnresolvedEdges,
    OrphansResolvedOnly,
    OrphansWithUnresolved,
    Tags,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphQueryPlanSummary {
    pub stage: GraphQueryStage,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileLookupProjection {
    pub file_id: String,
    pub relative_path: PathBuf,
    pub display_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTreeProjection {
    pub file: FileRecord,
    pub display_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkProjection {
    pub source_file_id: String,
    pub source_relative_path: Option<PathBuf>,
    pub target_file_id: Option<String>,
    pub target_relative_path: Option<PathBuf>,
    pub target_text: String,
    pub heading: Option<String>,
    pub alias: Option<String>,
    pub is_embed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagNoteProjection {
    pub file_id: String,
    pub relative_path: PathBuf,
    pub tag: String,
    pub source: TagSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyProjection {
    pub file_id: String,
    pub key: String,
    pub value: IndexPropertyValue,
    pub display_value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentProjection {
    pub source_file_id: String,
    pub raw_target: String,
    pub source: AttachmentReferenceSource,
    pub state: AttachmentResolutionState,
    pub resolved_relative_path: Option<PathBuf>,
}

impl IndexSchemaMetadata {
    pub fn new(
        backend_name: impl Into<String>,
        backend_version: impl Into<String>,
        tokenizer_config: impl Into<String>,
        generation: u64,
    ) -> Self {
        Self {
            schema_version: INDEX_SCHEMA_VERSION,
            backend_name: backend_name.into(),
            backend_version: backend_version.into(),
            tokenizer_config: tokenizer_config.into(),
            generation,
        }
    }
}

impl FileRecord {
    pub fn from_scan_entry(entry: &ScanEntry, generation: u64) -> Self {
        Self {
            file_id: lookup_key(&entry.relative_path),
            relative_path: entry.relative_path.clone(),
            kind: entry.kind,
            size_bytes: entry.size_bytes,
            modified: entry.modified,
            file_identity: entry.file_identity.clone(),
            content_hash: None,
            generation,
            status: FileIndexStatus::SeenMetadata,
            last_error: None,
        }
    }

    pub fn mark_seen_metadata(&mut self, entry: &ScanEntry, generation: u64) {
        self.relative_path = entry.relative_path.clone();
        self.kind = entry.kind;
        self.size_bytes = entry.size_bytes;
        self.modified = entry.modified;
        self.file_identity = entry.file_identity.clone();
        self.generation = generation;
        self.status = FileIndexStatus::SeenMetadata;
        self.last_error = None;
    }

    pub fn mark_parsed(&mut self, content_hash: impl Into<String>) {
        self.content_hash = Some(content_hash.into());
        self.status = FileIndexStatus::Parsed;
        self.last_error = None;
    }

    pub fn mark_search_indexed(&mut self) {
        self.status = FileIndexStatus::SearchIndexed;
        self.last_error = None;
    }

    pub fn mark_tombstoned(&mut self, generation: u64) {
        self.generation = generation;
        self.status = FileIndexStatus::Tombstoned;
        self.last_error = None;
    }

    pub fn mark_error(&mut self, error: impl AsRef<str>) {
        self.status = FileIndexStatus::Error;
        self.last_error = Some(truncate_index_error(error.as_ref()));
    }
}

pub fn slugify_heading(title: &str) -> String {
    title
        .trim()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
}

fn truncate_index_error(error: &str) -> String {
    let trimmed = error.trim();
    if trimmed.chars().count() <= MAX_INDEX_ERROR_CHARS {
        return trimmed.to_string();
    }

    trimmed.chars().take(MAX_INDEX_ERROR_CHARS).collect()
}
