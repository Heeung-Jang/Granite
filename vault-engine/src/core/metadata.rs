use std::path::PathBuf;
use std::time::SystemTime;

use super::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
use super::files::FileIdentity;
use super::scan::ScanEntryKind;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexSchemaMetadata {
    pub schema_version: u32,
    pub backend_name: String,
    pub backend_version: String,
    pub tokenizer_config: String,
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRecord {
    pub file_id: String,
    pub relative_path: PathBuf,
    pub kind: ScanEntryKind,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub file_identity: FileIdentity,
    pub content_hash: Option<String>,
    pub generation: u64,
    pub status: FileIndexStatus,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileIndexStatus {
    SeenMetadata,
    Parsed,
    SearchIndexed,
    Tombstoned,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkEdgeRecord {
    pub source_file_id: String,
    pub target_text: String,
    pub resolved_target_file_id: Option<String>,
    pub heading: Option<String>,
    pub alias: Option<String>,
    pub is_embed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagRecord {
    pub file_id: String,
    pub tag: String,
    pub source: TagSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TagSource {
    Inline,
    Frontmatter,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyRecord {
    pub file_id: String,
    pub key: String,
    pub value: IndexPropertyValue,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexPropertyValue {
    String(String),
    Bool(bool),
    List(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadingRecord {
    pub file_id: String,
    pub slug: String,
    pub title: String,
    pub level: u8,
    pub byte_offset: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentRecord {
    pub source_file_id: String,
    pub source: AttachmentReferenceSource,
    pub raw_target: String,
    pub state: AttachmentResolutionState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexedFileRecords {
    pub file: FileRecord,
    pub links: Vec<LinkEdgeRecord>,
    pub tags: Vec<TagRecord>,
    pub properties: Vec<PropertyRecord>,
    pub headings: Vec<HeadingRecord>,
    pub attachments: Vec<AttachmentRecord>,
}

pub type FileMetadataRecords = IndexedFileRecords;
