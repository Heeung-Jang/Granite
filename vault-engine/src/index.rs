use std::path::PathBuf;
use std::time::SystemTime;

use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
use crate::parser::PropertyValue;
use crate::paths::{FileIdentity, lookup_key};
use crate::scanner::{ScanEntry, ScanEntryKind};

pub const INDEX_SCHEMA_VERSION: u32 = 1;
pub const MAX_INDEX_ERROR_CHARS: usize = 512;

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

impl PropertyRecord {
    pub fn from_property_value(
        file_id: impl Into<String>,
        key: impl Into<String>,
        value: &PropertyValue,
    ) -> Self {
        let value = match value {
            PropertyValue::String(value) => IndexPropertyValue::String(value.clone()),
            PropertyValue::Bool(value) => IndexPropertyValue::Bool(*value),
            PropertyValue::List(values) => IndexPropertyValue::List(values.clone()),
        };

        Self {
            file_id: file_id.into(),
            key: key.into(),
            value,
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
    use crate::paths::VaultRoot;
    use crate::scanner::scan_vault;
    use std::path::PathBuf;

    #[test]
    fn fixture_file_transitions_from_seen_to_search_indexed() {
        let entry = fixture_entry("Home.md");
        let mut record = FileRecord::from_scan_entry(&entry, 1);

        assert_eq!(record.status, FileIndexStatus::SeenMetadata);
        assert_eq!(record.generation, 1);
        assert_eq!(record.file_id, "home.md");
        assert!(record.content_hash.is_none());

        record.mark_parsed("hash-home");
        assert_eq!(record.status, FileIndexStatus::Parsed);
        assert_eq!(record.content_hash.as_deref(), Some("hash-home"));

        record.mark_search_indexed();
        assert_eq!(record.status, FileIndexStatus::SearchIndexed);
        assert!(record.last_error.is_none());
    }

    #[test]
    fn fixture_file_can_be_tombstoned() {
        let entry = fixture_entry("Home.md");
        let mut record = FileRecord::from_scan_entry(&entry, 1);

        record.mark_tombstoned(2);

        assert_eq!(record.status, FileIndexStatus::Tombstoned);
        assert_eq!(record.generation, 2);
        assert!(record.last_error.is_none());
    }

    #[test]
    fn fixture_file_can_enter_error_state_with_bounded_error() {
        let entry = fixture_entry("Home.md");
        let mut record = FileRecord::from_scan_entry(&entry, 1);
        let error = "x".repeat(MAX_INDEX_ERROR_CHARS + 20);

        record.mark_error(&error);

        assert_eq!(record.status, FileIndexStatus::Error);
        assert_eq!(
            record.last_error.as_ref().expect("error").chars().count(),
            MAX_INDEX_ERROR_CHARS
        );
    }

    #[test]
    fn schema_metadata_and_related_records_are_represented() {
        let metadata = IndexSchemaMetadata::new("sqlite", "3.0", "unicode61", 7);
        assert_eq!(metadata.schema_version, INDEX_SCHEMA_VERSION);
        assert_eq!(metadata.generation, 7);

        let property = PropertyRecord::from_property_value(
            "home.md",
            "tags",
            &PropertyValue::List(vec!["home".to_string(), "project/native".to_string()]),
        );
        assert_eq!(
            property.value,
            IndexPropertyValue::List(vec!["home".to_string(), "project/native".to_string()])
        );

        let heading = HeadingRecord {
            file_id: "home.md".to_string(),
            slug: slugify_heading("Deep Heading"),
            title: "Deep Heading".to_string(),
            level: 2,
            byte_offset: None,
        };
        assert_eq!(heading.slug, "deep-heading");

        let link = LinkEdgeRecord {
            source_file_id: "home.md".to_string(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some("folder/target.md".to_string()),
            heading: Some("Deep Heading".to_string()),
            alias: None,
            is_embed: false,
        };
        assert_eq!(
            link.resolved_target_file_id.as_deref(),
            Some("folder/target.md")
        );

        let tag = TagRecord {
            file_id: "home.md".to_string(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };
        assert_eq!(tag.source, TagSource::Inline);

        let attachment = AttachmentRecord {
            source_file_id: "attachments.md".to_string(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };
        assert!(matches!(
            attachment.state,
            AttachmentResolutionState::Resolved { .. }
        ));
    }

    fn fixture_entry(relative_path: &str) -> crate::scanner::ScanEntry {
        let root_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault");
        let root = VaultRoot::open(root_path).expect("root");
        let scan = scan_vault(&root).expect("scan");
        scan.entries
            .into_iter()
            .find(|entry| entry.relative_path == PathBuf::from(relative_path))
            .expect("fixture entry")
    }
}
