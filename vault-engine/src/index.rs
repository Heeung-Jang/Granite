use std::path::PathBuf;

use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};

use crate::paths::lookup_key;
use crate::scanner::ScanEntry;

pub const INDEX_SCHEMA_VERSION: u32 = 2;
pub const MAX_INDEX_ERROR_CHARS: usize = 512;

pub use crate::adapters::sqlite::metadata_store::{
    MetadataStore, MetadataStoreError, MetadataStoreResult, MetadataTable,
};
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::sqlite::reads as sqlite_reads;
    use crate::adapters::sqlite::schema::{create_schema, write_schema_metadata};
    use crate::attachments::{
        AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
    };
    use crate::parser::PropertyValue;
    use crate::paths::VaultRoot;
    use crate::scanner::{ScanEntryKind, scan_vault};
    use rusqlite::{Connection, params};
    use std::{
        path::{Path, PathBuf},
        time::Instant,
    };

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

    #[test]
    fn metadata_store_inserts_updates_and_deletes_fixture_records() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut file = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        file.mark_parsed("hash-home");

        let link = LinkEdgeRecord {
            source_file_id: file.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some("folder/target.md".to_string()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: file.file_id.clone(),
            tag: "home".to_string(),
            source: TagSource::Frontmatter,
        };
        let property = PropertyRecord::from_property_value(
            file.file_id.clone(),
            "status",
            &PropertyValue::String("active".to_string()),
        );
        let heading = HeadingRecord {
            file_id: file.file_id.clone(),
            slug: slugify_heading("Home"),
            title: "Home".to_string(),
            level: 1,
            byte_offset: Some(0),
        };
        let attachment = AttachmentRecord {
            source_file_id: file.file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };

        store
            .replace_file_records(
                &file,
                &[link],
                &[tag],
                &[property],
                &[heading],
                &[attachment],
            )
            .expect("insert records");

        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 1);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 1);
        assert_eq!(store.row_count(MetadataTable::Tags).expect("tags"), 1);
        assert_eq!(
            store
                .row_count(MetadataTable::Properties)
                .expect("properties"),
            1
        );
        assert_eq!(
            store.row_count(MetadataTable::Headings).expect("headings"),
            1
        );
        assert_eq!(
            store
                .row_count(MetadataTable::Attachments)
                .expect("attachments"),
            1
        );

        file.mark_search_indexed();
        store
            .replace_file_records(&file, &[], &[], &[], &[], &[])
            .expect("update records");
        let stored = store
            .get_file(&file.file_id)
            .expect("get file")
            .expect("stored file");
        assert_eq!(stored.status, FileIndexStatus::SearchIndexed);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 0);

        store.delete_file(&file.file_id).expect("delete file");
        assert!(
            store
                .get_file(&file.file_id)
                .expect("get deleted")
                .is_none()
        );
        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 0);
    }

    #[test]
    fn metadata_store_bulk_loads_fixture_records() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut home = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let link = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: home.file_id.clone(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };

        store
            .bulk_load_file_records(&[
                IndexedFileRecords {
                    file: home.clone(),
                    links: vec![link],
                    tags: vec![tag],
                    properties: Vec::new(),
                    headings: Vec::new(),
                    attachments: Vec::new(),
                },
                IndexedFileRecords {
                    file: target.clone(),
                    links: Vec::new(),
                    tags: Vec::new(),
                    properties: Vec::new(),
                    headings: Vec::new(),
                    attachments: Vec::new(),
                },
            ])
            .expect("bulk load");

        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 2);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 1);
        assert_eq!(
            store
                .backlink_projections(&target.file_id, 0, 10)
                .expect("backlinks")
                .len(),
            1
        );
        assert!(projection_index_exists(
            &store.connection,
            "idx_links_source_file_id"
        ));
    }

    #[test]
    fn metadata_store_returns_whole_vault_graph_bulk_records() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v2", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut home = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let mut orphan = FileRecord::from_scan_entry(&fixture_entry("Docs/Guide.md"), 1);
        orphan.mark_parsed("hash-guide");
        let mut old_generation =
            FileRecord::from_scan_entry(&fixture_entry("Folder/Duplicate.md"), 0);
        old_generation.mark_search_indexed();
        let mut attachment =
            FileRecord::from_scan_entry(&fixture_entry("attachments/diagram.svg"), 1);
        attachment.mark_search_indexed();

        let resolved = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let unresolved = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "ÄMissing".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: None,
            is_embed: false,
        };
        let unresolved_case_variant = LinkEdgeRecord {
            target_text: "ämissing".to_string(),
            ..unresolved.clone()
        };
        let attachment_link = LinkEdgeRecord {
            source_file_id: attachment.file_id.clone(),
            target_text: "Home".to_string(),
            resolved_target_file_id: Some(home.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let stale_link = LinkEdgeRecord {
            source_file_id: old_generation.file_id.clone(),
            target_text: "Docs/Guide".to_string(),
            resolved_target_file_id: Some(orphan.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };

        store
            .replace_file_records(
                &home,
                &[
                    resolved.clone(),
                    resolved.clone(),
                    unresolved.clone(),
                    unresolved.clone(),
                    unresolved_case_variant,
                ],
                &[
                    TagRecord {
                        file_id: home.file_id.clone(),
                        tag: "project/native".to_string(),
                        source: TagSource::Inline,
                    },
                    TagRecord {
                        file_id: home.file_id.clone(),
                        tag: "work".to_string(),
                        source: TagSource::Frontmatter,
                    },
                ],
                &[],
                &[],
                &[],
            )
            .expect("home records");
        store
            .replace_file_records(&target, &[], &[], &[], &[], &[])
            .expect("target records");
        store
            .replace_file_records(&orphan, &[], &[], &[], &[], &[])
            .expect("orphan records");
        store
            .replace_file_records(&old_generation, &[stale_link], &[], &[], &[], &[])
            .expect("old records");
        store
            .replace_file_records(&attachment, &[attachment_link], &[], &[], &[], &[])
            .expect("attachment records");

        let files = store.graph_files(1, 10).expect("graph files");
        let file_ids = files
            .iter()
            .map(|file| file.file_id.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        let expected_file_ids = [
            orphan.file_id.as_str(),
            target.file_id.as_str(),
            home.file_id.as_str(),
        ]
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(file_ids, expected_file_ids);
        assert_eq!(
            files
                .iter()
                .find(|file| file.file_id == home.file_id)
                .expect("home graph file")
                .relative_path,
            home.relative_path
        );
        assert!(!files.iter().any(|file| file.file_id == attachment.file_id));
        assert!(
            !files
                .iter()
                .any(|file| file.file_id == old_generation.file_id)
        );

        let resolved_edges = store.graph_resolved_edges(1, 10).expect("resolved edges");
        assert_eq!(resolved_edges.len(), 1);
        assert_eq!(resolved_edges[0].source_file_id, home.file_id);
        assert_eq!(resolved_edges[0].source_relative_path, home.relative_path);
        assert_eq!(resolved_edges[0].target_file_id, target.file_id);
        assert_eq!(resolved_edges[0].target_relative_path, target.relative_path);
        assert_eq!(resolved_edges[0].weight, 2);

        let unresolved_edges = store
            .graph_unresolved_edges(1, 10)
            .expect("unresolved edges");
        assert_eq!(unresolved_edges.len(), 1);
        assert_eq!(unresolved_edges[0].source_file_id, home.file_id);
        assert_eq!(unresolved_edges[0].source_relative_path, home.relative_path);
        assert_eq!(unresolved_edges[0].target_text, "ÄMissing");
        assert_eq!(unresolved_edges[0].weight, 3);

        let orphans = store.graph_orphan_files(1, false, 10).expect("orphans");
        assert_eq!(
            orphans,
            vec![GraphFileRecord {
                file_id: orphan.file_id.clone(),
                relative_path: orphan.relative_path.clone(),
            }]
        );

        let tags = store
            .graph_tags_for_files(std::slice::from_ref(&home.file_id), 10)
            .expect("graph tags");
        assert_eq!(tags.len(), 2);
        assert!(tags.iter().all(|tag| tag.file_id == home.file_id));
        assert_eq!(
            store
                .graph_visible_node_count(1, false, false)
                .expect("resolved node count"),
            2
        );
        assert_eq!(
            store
                .graph_visible_node_count(1, true, true)
                .expect("full node count"),
            4
        );
        assert_eq!(
            store
                .graph_visible_edge_count(1, false)
                .expect("resolved edge count"),
            1
        );
        assert_eq!(
            store
                .graph_visible_edge_count(1, true)
                .expect("full edge count"),
            2
        );

        let plans = store.graph_query_plan_summaries(1).expect("plans");
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::Files)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::ResolvedEdges)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::UnresolvedEdges)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::OrphansResolvedOnly)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::OrphansWithUnresolved)
        );
        assert!(plans.iter().any(|plan| plan.stage == GraphQueryStage::Tags));
        assert!(plans.iter().all(|plan| !plan.detail.contains("Home.md")));
        let unresolved_plan_details = plans
            .iter()
            .filter(|plan| plan.stage == GraphQueryStage::UnresolvedEdges)
            .map(|plan| plan.detail.as_str())
            .collect::<Vec<_>>();
        assert!(
            unresolved_plan_details
                .iter()
                .any(|detail| detail.contains("idx_links_unresolved_source_target_key"))
        );
        assert!(
            unresolved_plan_details
                .iter()
                .all(|detail| !detail.contains("USE TEMP B-TREE FOR GROUP BY"))
        );
        let edge_count_plan_sql = format!(
            "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM ({} UNION ALL {})",
            sqlite_reads::GRAPH_RESOLVED_EDGE_GROUPS_SQL,
            sqlite_reads::GRAPH_UNRESOLVED_EDGE_GROUPS_SQL
        );
        let mut statement = store
            .connection
            .prepare(&edge_count_plan_sql)
            .expect("edge count plan");
        let edge_count_plan_details = statement
            .query_map(params![1_i64], |row| row.get::<_, String>(3))
            .expect("edge count plan rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("edge count plan details");
        assert!(
            edge_count_plan_details
                .iter()
                .any(|detail| detail.contains("idx_links_unresolved_source_target_key"))
        );
        assert!(
            edge_count_plan_details
                .iter()
                .all(|detail| !detail.contains("USE TEMP B-TREE FOR GROUP BY"))
        );
    }

    #[test]
    fn metadata_store_replaces_file_records_batch() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let home = metadata_records_for_file("Home.md", 1);
        let guide = metadata_records_for_file("Docs/Guide.md", 1);

        store
            .replace_file_records_batch(&[home.clone(), guide.clone()])
            .expect("batch insert");

        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 2);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 2);
        assert_eq!(store.row_count(MetadataTable::Tags).expect("tags"), 2);
        assert_eq!(
            store
                .row_count(MetadataTable::Properties)
                .expect("properties"),
            2
        );
        assert_eq!(
            store.row_count(MetadataTable::Headings).expect("headings"),
            2
        );
        assert_eq!(
            store
                .row_count(MetadataTable::Attachments)
                .expect("attachments"),
            2
        );
    }

    #[test]
    fn metadata_schema_has_projection_indexes() {
        let connection = Connection::open_in_memory().expect("connection");
        create_schema(&connection).expect("schema");
        let mut statement = connection
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index'")
            .expect("index query");
        let indexes = statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("index rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("index names");

        for expected in [
            "idx_files_relative_path",
            "idx_files_kind_status_generation",
            "idx_links_source_file_id",
            "idx_links_resolved_target_file_id",
            "idx_links_resolved_pair",
            "idx_links_unresolved_target_text",
            "idx_links_unresolved_source_target_key",
            "idx_tags_file_id",
            "idx_tags_tag",
            "idx_properties_file_id",
            "idx_headings_file_id",
            "idx_attachments_source_file_id",
        ] {
            assert!(
                indexes.iter().any(|index| index == expected),
                "missing index {expected}"
            );
        }
    }

    #[test]
    fn metadata_projections_return_display_ready_rows() {
        let ProjectionFixture {
            store,
            home,
            target,
            guide,
            ..
        } = projection_fixture();

        let lookup = store.lookup_file("Home.md").expect("lookup").expect("home");
        assert_eq!(lookup.file_id, home.file_id);
        assert_eq!(lookup.display_path, "Home.md");
        assert!(store.lookup_file("Missing.md").expect("missing").is_none());

        let tree = store.file_tree_projection(0, 2).expect("file tree");
        assert_eq!(
            tree.iter()
                .map(|item| item.display_path.as_str())
                .collect::<Vec<_>>(),
            vec!["Docs/Guide.md", "Folder/Target.md"]
        );
        assert!(
            tree.iter()
                .all(|item| item.file.kind == ScanEntryKind::Markdown)
        );
        assert!(
            store
                .file_tree_projection(0, 10)
                .expect("markdown tree")
                .iter()
                .all(|item| item.display_path.ends_with(".md"))
        );

        let backlinks = store
            .backlink_projections(&target.file_id, 0, 10)
            .expect("backlinks");
        assert_eq!(backlinks.len(), 1);
        assert_eq!(backlinks[0].source_file_id, home.file_id);
        assert_eq!(
            backlinks[0].source_relative_path.as_deref(),
            Some(Path::new("Home.md"))
        );
        assert_eq!(backlinks[0].target_text, "Folder/Target");

        let outgoing = store
            .outgoing_link_projections(&home.file_id, 0, 10)
            .expect("outgoing");
        assert_eq!(outgoing.len(), 2);
        assert!(outgoing.iter().any(|link| {
            link.target_file_id.as_deref() == Some(target.file_id.as_str())
                && link.target_relative_path.as_deref() == Some(Path::new("Folder/Target.md"))
        }));
        assert!(outgoing.iter().any(|link| {
            link.target_text == "Missing Note" && link.target_relative_path.is_none()
        }));

        let tags = store.tags(&home.file_id, 0, 10).expect("current tags");
        assert_eq!(tags.len(), 2);
        let tag_notes = store
            .tag_note_projections("project/native", 0, 2)
            .expect("tag notes");
        assert_eq!(tag_notes.len(), 2);
        assert_eq!(tag_notes[0].relative_path, PathBuf::from("Docs/Guide.md"));
        assert_eq!(
            tag_notes[1].relative_path,
            PathBuf::from("Folder/Target.md")
        );
        assert_eq!(
            store
                .tag_note_projections("project/native", 0, 10)
                .expect("deduped tag notes")
                .len(),
            3
        );

        let properties = store
            .property_projections(&home.file_id, 0, 10)
            .expect("properties");
        assert_eq!(
            properties
                .iter()
                .map(|property| (property.key.as_str(), property.display_value.as_str()))
                .collect::<Vec<_>>(),
            vec![("active", "true"), ("status", "stable"), ("tags", "a, b")]
        );

        let attachments = store
            .attachment_projections(&home.file_id, 0, 10)
            .expect("attachments");
        assert_eq!(attachments.len(), 6);
        assert!(attachments.iter().any(|attachment| {
            attachment.raw_target == "assets/image.png"
                && attachment.resolved_relative_path.as_deref()
                    == Some(Path::new("assets/image.png"))
        }));
        assert!(
            attachments
                .iter()
                .any(|attachment| matches!(attachment.state, AttachmentResolutionState::Missing))
        );
        assert!(attachments.iter().any(|attachment| matches!(
            attachment.state,
            AttachmentResolutionState::Duplicate { .. }
        )));
        assert!(
            attachments
                .iter()
                .any(|attachment| matches!(attachment.state, AttachmentResolutionState::Remote))
        );
        assert!(
            attachments.iter().any(|attachment| matches!(
                attachment.state,
                AttachmentResolutionState::Rejected(_)
            ))
        );
        assert!(
            attachments.iter().any(|attachment| matches!(
                attachment.state,
                AttachmentResolutionState::Unsupported
            ))
        );

        assert_eq!(guide.relative_path, PathBuf::from("Docs/Guide.md"));
    }

    #[test]
    fn projection_queries_are_bounded_smoke() {
        let ProjectionFixture {
            store,
            home,
            target,
            ..
        } = projection_fixture();
        let started = Instant::now();

        assert!(store.file_tree_projection(0, 2).expect("tree").len() <= 2);
        assert!(
            store
                .backlink_projections(&target.file_id, 0, 2)
                .expect("backlinks")
                .len()
                <= 2
        );
        assert!(
            store
                .outgoing_link_projections(&home.file_id, 0, 2)
                .expect("outgoing")
                .len()
                <= 2
        );
        assert!(
            store
                .tag_note_projections("project/native", 0, 2)
                .expect("tags")
                .len()
                <= 2
        );
        assert!(
            store
                .property_projections(&home.file_id, 0, 2)
                .expect("properties")
                .len()
                <= 2
        );
        assert!(
            store
                .attachment_projections(&home.file_id, 0, 2)
                .expect("attachments")
                .len()
                <= 2
        );

        assert!(started.elapsed().as_millis() < 250);
    }

    #[test]
    fn metadata_store_batch_is_atomic_on_mid_batch_failure() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let original_home = metadata_records_for_file("Home.md", 1);
        store
            .replace_file_records_batch(std::slice::from_ref(&original_home))
            .expect("initial insert");

        let mut changed_home = metadata_records_for_file("Home.md", 2);
        changed_home.file.mark_search_indexed();
        let mut invalid_guide = metadata_records_for_file("Docs/Guide.md", 2);
        invalid_guide.links[0].source_file_id = "missing.md".to_string();

        let result = store.replace_file_records_batch(&[changed_home, invalid_guide]);

        assert!(matches!(result, Err(MetadataStoreError::Sqlite(_))));
        let stored_home = store
            .get_file(&original_home.file.file_id)
            .expect("home lookup")
            .expect("home remains");
        assert_eq!(stored_home.status, FileIndexStatus::Parsed);
        assert_eq!(stored_home.generation, 1);
        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 1);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 1);
    }

    #[test]
    fn metadata_store_reports_schema_mismatch() {
        let expected = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let stored = IndexSchemaMetadata::new("sqlite", "metadata-v2", "none", 1);
        let connection = Connection::open_in_memory().expect("connection");
        create_schema(&connection).expect("schema");
        write_schema_metadata(&connection, &stored).expect("metadata");

        let result = MetadataStore::from_connection(connection, &expected);

        assert!(matches!(
            result,
            Err(MetadataStoreError::SchemaMismatch { .. })
        ));
    }

    struct ProjectionFixture {
        store: MetadataStore,
        home: FileRecord,
        target: FileRecord,
        guide: FileRecord,
    }

    fn projection_fixture() -> ProjectionFixture {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut home = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let mut guide = FileRecord::from_scan_entry(&fixture_entry("Docs/Guide.md"), 1);
        guide.mark_search_indexed();
        let attachment = FileRecord::from_scan_entry(&fixture_entry("attachments/diagram.svg"), 1);

        let resolved_link = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let missing_link = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Missing Note".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: Some("Missing".to_string()),
            is_embed: true,
        };
        let home_tags = [
            TagRecord {
                file_id: home.file_id.clone(),
                tag: "project/native".to_string(),
                source: TagSource::Inline,
            },
            TagRecord {
                file_id: home.file_id.clone(),
                tag: "project/native".to_string(),
                source: TagSource::Frontmatter,
            },
        ];
        let properties = [
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "status",
                &PropertyValue::String("stable".to_string()),
            ),
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "active",
                &PropertyValue::Bool(true),
            ),
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "tags",
                &PropertyValue::List(vec!["a".to_string(), "b".to_string()]),
            ),
        ];
        let attachments = [
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "assets/image.png".to_string(),
                state: AttachmentResolutionState::Resolved {
                    relative_path: PathBuf::from("assets/image.png"),
                },
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownImage,
                raw_target: "missing.png".to_string(),
                state: AttachmentResolutionState::Missing,
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "duplicate.png".to_string(),
                state: AttachmentResolutionState::Duplicate {
                    candidates: vec![
                        PathBuf::from("a/duplicate.png"),
                        PathBuf::from("b/duplicate.png"),
                    ],
                },
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownLink,
                raw_target: "https://example.com/image.png".to_string(),
                state: AttachmentResolutionState::Remote,
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownImage,
                raw_target: "../escape.png".to_string(),
                state: AttachmentResolutionState::Rejected(AttachmentRejectReason::OutsideVault),
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownLink,
                raw_target: "note.md".to_string(),
                state: AttachmentResolutionState::Unsupported,
            },
        ];

        store
            .replace_file_records(
                &home,
                &[resolved_link, missing_link],
                &home_tags,
                &properties,
                &[],
                &attachments,
            )
            .expect("home");
        for file in [&target, &guide] {
            let tags = [TagRecord {
                file_id: file.file_id.clone(),
                tag: "project/native".to_string(),
                source: TagSource::Frontmatter,
            }];
            store
                .replace_file_records(file, &[], &tags, &[], &[], &[])
                .expect("tagged file");
        }
        store
            .replace_file_records(&attachment, &[], &[], &[], &[], &[])
            .expect("attachment");

        ProjectionFixture {
            store,
            home,
            target,
            guide,
        }
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

    fn metadata_records_for_file(relative_path: &str, generation: u64) -> FileMetadataRecords {
        let mut file = FileRecord::from_scan_entry(&fixture_entry(relative_path), generation);
        file.mark_parsed(format!("hash-{relative_path}"));
        FileMetadataRecords {
            links: vec![LinkEdgeRecord {
                source_file_id: file.file_id.clone(),
                target_text: "Folder/Target".to_string(),
                resolved_target_file_id: Some("folder/target.md".to_string()),
                heading: None,
                alias: None,
                is_embed: false,
            }],
            tags: vec![TagRecord {
                file_id: file.file_id.clone(),
                tag: "home".to_string(),
                source: TagSource::Frontmatter,
            }],
            properties: vec![PropertyRecord::from_property_value(
                file.file_id.clone(),
                "status",
                &PropertyValue::String("active".to_string()),
            )],
            headings: vec![HeadingRecord {
                file_id: file.file_id.clone(),
                slug: slugify_heading("Home"),
                title: "Home".to_string(),
                level: 1,
                byte_offset: Some(0),
            }],
            attachments: vec![AttachmentRecord {
                source_file_id: file.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "attachments/diagram.svg".to_string(),
                state: AttachmentResolutionState::Resolved {
                    relative_path: PathBuf::from("attachments/diagram.svg"),
                },
            }],
            file,
        }
    }

    fn projection_index_exists(connection: &Connection, name: &str) -> bool {
        connection
            .query_row(
                "SELECT EXISTS (
                    SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?1
                )",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .expect("index exists query")
            == 1
    }
}
