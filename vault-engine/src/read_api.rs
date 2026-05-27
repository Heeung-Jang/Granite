use crate::graph::{WholeVaultGraphRequest, WholeVaultGraphSnapshot};
use crate::use_cases::build_graph::build_whole_vault_graph_from_metadata;
pub use crate::use_cases::read_graph::{
    LocalGraph, LocalGraphDepth, LocalGraphEdge, LocalGraphEdgeDirection, LocalGraphNode,
    LocalGraphNodeKind, LocalGraphRequest,
};
pub use crate::use_cases::read_types::{
    ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
    ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
    ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
    ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP, ENGINE_READ_SEARCH_MODE_BODY,
    ENGINE_READ_SEARCH_MODE_FILE_NAME, ENGINE_READ_STATE_CANCELLED, ENGINE_READ_STATE_COMPLETE,
    ENGINE_READ_STATE_ERROR, ENGINE_READ_STATE_INDEX_UNAVAILABLE, ENGINE_READ_STATE_PARTIAL,
    ENGINE_READ_STATE_STALE, FileOpenMetadata, LivePreviewMetadataItem,
    LivePreviewMetadataItemKind, LivePreviewMetadataSource, LivePreviewMetadataState, PageRequest,
    READ_BACKEND_NAME, READ_BACKEND_VERSION, READ_TOKENIZER_CONFIG, ReadApiError, ReadApiResult,
    ReadOpenError, ReadOpenResult, ReadPage, ReadState, ReadValue, SearchHit,
};
pub use crate::use_cases::read_vault::{
    VaultReadApi, expected_read_schema_metadata, open_metadata_store_for_read,
    open_tantivy_index_for_read, open_vault_read_api,
};

impl VaultReadApi {
    pub fn whole_vault_graph(
        &self,
        request: WholeVaultGraphRequest,
    ) -> ReadApiResult<ReadValue<WholeVaultGraphSnapshot>> {
        let graph =
            build_whole_vault_graph_from_metadata(&self.metadata, self.generation, request)?;
        Ok(ReadValue {
            request_id: request.request_id,
            generation: self.generation,
            state: if graph.partial {
                ReadState::Partial
            } else {
                ReadState::Complete
            },
            value: graph.snapshot,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{fs, path::PathBuf, sync::Mutex};

    use crate::adapters::sqlite::{
        AttachmentRecord, FileRecord, HeadingRecord, IndexSchemaMetadata, MetadataStore,
        PropertyRecord, TagRecord, TagSource, slugify_heading,
    };
    use crate::adapters::tantivy::TantivySearchIndex;
    use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
    use crate::parser::PropertyValue;
    use crate::paths::{VaultRoot, lookup_key};
    use crate::scanner::{ScanEntry, ScanEntryKind, scan_vault};
    use crate::sqlite_fts::SearchDocument;
    use crate::use_cases::read_graph::{graph_file_node_id, graph_unresolved_node_id};
    use rusqlite::trace::{TraceEvent, TraceEventCodes};
    use tempfile::tempdir;

    static READ_API_TRACE_LOCK: Mutex<()> = Mutex::new(());
    static READ_API_TRACE_SQL: Mutex<Vec<String>> = Mutex::new(Vec::new());

    #[test]
    fn read_open_error_codes_are_stable() {
        let errors = [
            (ReadOpenError::MissingMetadata, "missing_metadata", 1),
            (ReadOpenError::CorruptMetadata, "corrupt_metadata", 2),
            (
                ReadOpenError::SchemaMismatch {
                    stored: 0,
                    expected: 1,
                },
                "schema_mismatch",
                3,
            ),
            (
                ReadOpenError::BackendMismatch {
                    stored_name: "sqlite-fts".to_string(),
                    stored_version: "metadata-v1".to_string(),
                    expected_name: READ_BACKEND_NAME.to_string(),
                    expected_version: READ_BACKEND_VERSION.to_string(),
                },
                "backend_mismatch",
                4,
            ),
            (
                ReadOpenError::TokenizerMismatch {
                    stored: "unicode61".to_string(),
                    expected: READ_TOKENIZER_CONFIG.to_string(),
                },
                "tokenizer_mismatch",
                5,
            ),
            (
                ReadOpenError::MissingTantivyIndex,
                "missing_tantivy_index",
                6,
            ),
            (
                ReadOpenError::InvalidInput("metadata_path"),
                "invalid_input",
                7,
            ),
            (ReadOpenError::Panic, "panic", 8),
        ];

        for (error, code, numeric_code) in errors {
            assert_eq!(error.abi_code(), code);
            assert_eq!(error.abi_numeric_code(), numeric_code);
        }
    }

    #[test]
    fn read_state_abi_constants_are_stable() {
        assert_eq!(ENGINE_READ_STATE_COMPLETE, 0);
        assert_eq!(ENGINE_READ_STATE_PARTIAL, 1);
        assert_eq!(ENGINE_READ_STATE_STALE, 2);
        assert_eq!(ENGINE_READ_STATE_CANCELLED, 3);
        assert_eq!(ENGINE_READ_STATE_ERROR, 4);
        assert_eq!(ENGINE_READ_STATE_INDEX_UNAVAILABLE, 5);
    }

    #[test]
    fn metadata_read_open_preserves_stored_generation() {
        let dir = tempdir().expect("tempdir");
        let metadata_path = dir.path().join("metadata.sqlite");
        let metadata = IndexSchemaMetadata::new(
            READ_BACKEND_NAME,
            READ_BACKEND_VERSION,
            READ_TOKENIZER_CONFIG,
            7,
        );
        let store = MetadataStore::open(&metadata_path, &metadata).expect("store");
        drop(store);

        let (_store, generation) =
            open_metadata_store_for_read(&metadata_path).expect("open metadata");

        assert_eq!(generation, 7);
    }

    #[test]
    fn metadata_read_open_reports_missing_corrupt_and_schema_mismatch() {
        let dir = tempdir().expect("tempdir");
        let missing_path = dir.path().join("missing.sqlite");
        assert_eq!(
            open_metadata_store_for_read(&missing_path)
                .err()
                .expect("missing"),
            ReadOpenError::MissingMetadata
        );

        let corrupt_path = dir.path().join("corrupt.sqlite");
        fs::write(&corrupt_path, b"not sqlite").expect("corrupt");
        assert_eq!(
            open_metadata_store_for_read(&corrupt_path)
                .err()
                .expect("corrupt"),
            ReadOpenError::CorruptMetadata
        );

        let schema_path = dir.path().join("schema.sqlite");
        let metadata = IndexSchemaMetadata::new(
            READ_BACKEND_NAME,
            READ_BACKEND_VERSION,
            READ_TOKENIZER_CONFIG,
            3,
        );
        let store = MetadataStore::open(&schema_path, &metadata).expect("store");
        drop(store);
        let connection = rusqlite::Connection::open(&schema_path).expect("connection");
        connection
            .execute(
                "UPDATE index_metadata SET value = '1' WHERE key = 'schema_version'",
                [],
            )
            .expect("schema version update");
        drop(connection);

        assert_eq!(
            open_metadata_store_for_read(&schema_path)
                .err()
                .expect("schema"),
            ReadOpenError::SchemaMismatch {
                stored: 1,
                expected: 2
            }
        );
    }

    #[test]
    fn tantivy_read_open_reports_missing_and_opens_existing_index() {
        let dir = tempdir().expect("tempdir");
        let missing_path = dir.path().join("missing-tantivy");
        assert_eq!(
            open_tantivy_index_for_read(&missing_path)
                .err()
                .expect("missing"),
            ReadOpenError::MissingTantivyIndex
        );

        let index_path = dir.path().join("tantivy");
        let mut index = TantivySearchIndex::open_in_dir(&index_path).expect("create index");
        index
            .replace_documents(&[SearchDocument {
                file_id: "home".to_string(),
                path: "Home.md".to_string(),
                title: "Home".to_string(),
                body: "searchable body".to_string(),
            }])
            .expect("write index");
        drop(index);

        let index = open_tantivy_index_for_read(&index_path).expect("open index");

        assert_eq!(index.search("searchable", 10).expect("search").len(), 1);
    }

    #[test]
    fn file_tree_allows_large_markdown_pages_without_attachment_rows() {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        for index in 0..150 {
            let mut file = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
            file.relative_path = PathBuf::from(format!("Bulk/{index:03}.md"));
            file.file_id = lookup_key(&file.relative_path);
            file.file_identity.inode = index as u64 + 1;
            store
                .replace_file_records(&file, &[], &[], &[], &[], &[])
                .expect("markdown file");
        }
        let attachment = FileRecord::from_scan_entry(&fixture_entry("attachments/diagram.svg"), 1);
        store
            .replace_file_records(&attachment, &[], &[], &[], &[], &[])
            .expect("attachment file");
        let search = TantivySearchIndex::open_in_ram().expect("search");
        let api = VaultReadApi::with_generation(store, search, 1);

        let page = api
            .file_tree_projection(PageRequest::with_request_id(90, 0, 150))
            .expect("file tree");

        assert_eq!(page.request_id, 90);
        assert_eq!(page.state, ReadState::Complete);
        assert_eq!(page.items.len(), 150);
        assert!(page.next_offset.is_none());
        assert!(
            page.items
                .iter()
                .all(|item| item.file.kind == ScanEntryKind::Markdown)
        );
    }

    #[test]
    fn read_api_sql_query_counts_stay_bounded_for_ui_surfaces() {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut search = TantivySearchIndex::open_in_ram().expect("search");

        let mut home = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let mut guide = FileRecord::from_scan_entry(&fixture_entry("Docs/Guide.md"), 1);
        guide.mark_search_indexed();

        let home_to_target = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let home_to_missing = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Missing Note".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: None,
            is_embed: false,
        };
        let target_to_home = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: target.file_id.clone(),
            target_text: "Home".to_string(),
            resolved_target_file_id: Some(home.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let target_to_guide = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: target.file_id.clone(),
            target_text: "Docs/Guide".to_string(),
            resolved_target_file_id: Some(guide.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: home.file_id.clone(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };
        let property = PropertyRecord::from_property_value(
            home.file_id.clone(),
            "status",
            &PropertyValue::String("active".to_string()),
        );
        let heading = HeadingRecord {
            file_id: home.file_id.clone(),
            slug: slugify_heading("Home"),
            title: "Home".to_string(),
            level: 1,
            byte_offset: Some(0),
        };
        let attachment = AttachmentRecord {
            source_file_id: home.file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };

        store
            .replace_file_records(
                &home,
                &[home_to_target, home_to_missing],
                std::slice::from_ref(&tag),
                std::slice::from_ref(&property),
                std::slice::from_ref(&heading),
                std::slice::from_ref(&attachment),
            )
            .expect("home");
        store
            .replace_file_records(
                &target,
                &[target_to_home, target_to_guide],
                &[],
                &[],
                &[],
                &[],
            )
            .expect("target");
        store
            .replace_file_records(&guide, &[], &[], &[], &[], &[])
            .expect("guide");
        search
            .replace_documents(&[
                SearchDocument {
                    file_id: home.file_id.clone(),
                    path: "Home.md".to_string(),
                    title: "Home".to_string(),
                    body: "Home body mentions compatibility.".to_string(),
                },
                SearchDocument {
                    file_id: target.file_id.clone(),
                    path: "Folder/Target.md".to_string(),
                    title: "Target".to_string(),
                    body: "Target body receives backlinks.".to_string(),
                },
            ])
            .expect("index");

        let api = VaultReadApi::with_generation(store, search, 1);
        assert_sql_count("file tree", &api, 1, || {
            api.file_tree_projection(PageRequest::new(0, 10))
                .expect("file tree")
        });
        assert_sql_count("file-name search", &api, 0, || {
            api.file_name_search("Home", PageRequest::new(0, 10))
                .expect("file-name search")
        });
        assert_sql_count("body search", &api, 0, || {
            api.body_search("compatibility", PageRequest::new(0, 10))
                .expect("body search")
        });
        assert_sql_count("outgoing by path", &api, 2, || {
            api.outgoing_links_for_path("Home.md", PageRequest::new(0, 10))
                .expect("outgoing by path")
        });
        assert_sql_count("properties by path", &api, 2, || {
            api.properties_for_path("Home.md", PageRequest::new(0, 10))
                .expect("properties by path")
        });
        assert_sql_count("attachments by path", &api, 2, || {
            api.attachments_for_path("Home.md", PageRequest::new(0, 10))
                .expect("attachments by path")
        });
        assert_sql_count("local graph one-hop", &api, 5, || {
            api.local_graph(&home.file_id, LocalGraphRequest::new(10, 10))
                .expect("one-hop graph")
        });
        assert_sql_count("local graph two-hop", &api, 8, || {
            api.local_graph(
                &home.file_id,
                LocalGraphRequest::with_depth(0, 10, 10, LocalGraphDepth::TwoHop),
            )
            .expect("two-hop graph")
        });
    }

    #[test]
    fn read_api_returns_paginated_metadata_and_search_states() {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut search = TantivySearchIndex::open_in_ram().expect("search");

        let mut home =
            crate::adapters::sqlite::FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = crate::adapters::sqlite::FileRecord::from_scan_entry(
            &fixture_entry("Folder/Target.md"),
            1,
        );
        target.mark_search_indexed();
        let mut guide = crate::adapters::sqlite::FileRecord::from_scan_entry(
            &fixture_entry("Docs/Guide.md"),
            1,
        );
        guide.mark_search_indexed();

        let link = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: Some("Details".to_string()),
            alias: None,
            is_embed: false,
        };
        let unresolved_link = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Missing Note".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: None,
            is_embed: false,
        };
        let backlink = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: target.file_id.clone(),
            target_text: "Home".to_string(),
            resolved_target_file_id: Some(home.file_id.clone()),
            heading: None,
            alias: Some("Home alias".to_string()),
            is_embed: true,
        };
        let deep_link = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: target.file_id.clone(),
            target_text: "Docs/Guide".to_string(),
            resolved_target_file_id: Some(guide.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: home.file_id.clone(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };
        let property = PropertyRecord::from_property_value(
            home.file_id.clone(),
            "status",
            &PropertyValue::String("active".to_string()),
        );
        let heading = HeadingRecord {
            file_id: home.file_id.clone(),
            slug: slugify_heading("Home"),
            title: "Home".to_string(),
            level: 1,
            byte_offset: Some(0),
        };
        let attachment = AttachmentRecord {
            source_file_id: home.file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };

        store
            .replace_file_records(
                &home,
                &[link.clone(), unresolved_link.clone()],
                std::slice::from_ref(&tag),
                std::slice::from_ref(&property),
                std::slice::from_ref(&heading),
                std::slice::from_ref(&attachment),
            )
            .expect("home records");
        store
            .replace_file_records(
                &target,
                &[deep_link.clone(), backlink.clone()],
                &[],
                &[],
                &[],
                &[],
            )
            .expect("target records");
        store
            .replace_file_records(&guide, &[], &[], &[], &[], &[])
            .expect("guide records");
        search
            .replace_documents(&[
                SearchDocument {
                    file_id: home.file_id.clone(),
                    path: "Home.md".to_string(),
                    title: "Home".to_string(),
                    body: "Home body mentions compatibility and native search.".to_string(),
                },
                SearchDocument {
                    file_id: target.file_id.clone(),
                    path: "Folder/Target.md".to_string(),
                    title: "Target".to_string(),
                    body: "Target body receives backlinks.".to_string(),
                },
                SearchDocument {
                    file_id: guide.file_id.clone(),
                    path: "Docs/Guide.md".to_string(),
                    title: "Guide".to_string(),
                    body: "Guide body is a second hop target.".to_string(),
                },
            ])
            .expect("index");

        let api = VaultReadApi::with_generation(store, search, 1);
        let first_file = api
            .file_tree(PageRequest::with_request_id(42, 0, 1))
            .expect("first file page");
        assert_eq!(first_file.request_id, 42);
        assert_eq!(first_file.generation, 1);
        assert_eq!(first_file.state, ReadState::Partial);
        assert_eq!(first_file.next_offset, Some(1));
        let open = api
            .file_open_metadata_with_request(43, &home.file_id)
            .expect("open metadata");
        assert_eq!(open.request_id, 43);
        assert_eq!(open.generation, 1);
        assert_eq!(open.state, ReadState::Complete);
        assert_eq!(
            open.value.expect("file").file.file_id,
            lookup_key("Home.md")
        );

        assert_eq!(
            api.file_name_search("Home", PageRequest::with_request_id(44, 0, 10))
                .expect("file name search")
                .state,
            ReadState::Complete
        );
        assert!(
            api.body_search("compatibility", PageRequest::new(0, 10))
                .expect("body search")
                .items
                .iter()
                .any(|hit| hit.file_id == home.file_id)
        );
        assert_eq!(
            api.body_search("!!!", PageRequest::new(0, 10))
                .expect("empty query")
                .state,
            ReadState::Error
        );
        assert_eq!(
            api.outgoing_links(&home.file_id, PageRequest::new(0, 10))
                .expect("outgoing")
                .items,
            vec![link.clone(), unresolved_link.clone()]
        );
        assert_eq!(
            api.backlinks(&target.file_id, PageRequest::new(0, 10))
                .expect("backlinks")
                .items,
            vec![link]
        );
        assert_eq!(
            api.backlinks(&home.file_id, PageRequest::new(0, 10))
                .expect("home backlinks")
                .items,
            vec![backlink.clone()]
        );
        assert_eq!(
            api.tags(&home.file_id, PageRequest::new(0, 10))
                .expect("tags")
                .items,
            vec![tag]
        );
        assert_eq!(
            api.properties(&home.file_id, PageRequest::new(0, 10))
                .expect("properties")
                .items,
            vec![property]
        );
        assert_eq!(
            api.headings(&home.file_id, PageRequest::new(0, 10))
                .expect("headings")
                .items,
            vec![heading]
        );
        assert_eq!(
            api.attachments(&home.file_id, PageRequest::new(0, 10))
                .expect("attachments")
                .items,
            vec![attachment]
        );

        let graph = api
            .local_graph(
                &home.file_id,
                LocalGraphRequest::with_request_id(60, 10, 10),
            )
            .expect("local graph");
        assert_eq!(graph.request_id, 60);
        assert_eq!(graph.generation, 1);
        assert_eq!(graph.state, ReadState::Complete);
        assert_eq!(
            graph.value.center_node_id,
            graph_file_node_id(&home.file_id)
        );
        assert!(graph.value.nodes.iter().any(|node| {
            node.node_id == graph_file_node_id(&home.file_id)
                && node.kind == LocalGraphNodeKind::Center
        }));
        assert!(graph.value.nodes.iter().any(|node| {
            node.node_id == graph_file_node_id(&target.file_id)
                && node.kind == LocalGraphNodeKind::Resolved
                && node.label == "Folder/Target.md"
        }));
        assert!(graph.value.nodes.iter().any(|node| {
            node.node_id == graph_unresolved_node_id("Missing Note")
                && node.kind == LocalGraphNodeKind::Unresolved
        }));
        assert_eq!(graph.value.nodes.len(), 3);
        assert_eq!(graph.value.edges.len(), 3);
        assert!(graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Outgoing
                && edge.source_node_id == graph_file_node_id(&home.file_id)
                && edge.target_node_id == graph_file_node_id(&target.file_id)
                && edge.hop == 1
        }));
        assert!(graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Outgoing
                && edge.target_node_id == graph_unresolved_node_id("Missing Note")
                && edge.hop == 1
        }));
        assert!(graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Backlink
                && edge.source_node_id == graph_file_node_id(&target.file_id)
                && edge.target_node_id == graph_file_node_id(&home.file_id)
                && edge.is_embed
                && edge.hop == 1
        }));

        let two_hop_graph = api
            .local_graph(
                &home.file_id,
                LocalGraphRequest::with_depth(61, 10, 10, LocalGraphDepth::TwoHop),
            )
            .expect("two hop graph");
        assert_eq!(two_hop_graph.request_id, 61);
        assert_eq!(two_hop_graph.state, ReadState::Complete);
        assert!(two_hop_graph.value.nodes.iter().any(|node| {
            node.node_id == graph_file_node_id(&guide.file_id)
                && node.kind == LocalGraphNodeKind::Resolved
                && node.label == "Docs/Guide.md"
        }));
        assert!(two_hop_graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Outgoing
                && edge.source_node_id == graph_file_node_id(&target.file_id)
                && edge.target_node_id == graph_file_node_id(&guide.file_id)
                && edge.hop == 2
        }));

        let node_capped = api
            .local_graph(&home.file_id, LocalGraphRequest::new(2, 10))
            .expect("node capped graph");
        assert_eq!(node_capped.state, ReadState::Partial);
        assert_eq!(node_capped.value.nodes.len(), 2);

        let edge_capped = api
            .local_graph(&home.file_id, LocalGraphRequest::new(10, 1))
            .expect("edge capped graph");
        assert_eq!(edge_capped.state, ReadState::Partial);
        assert_eq!(edge_capped.value.edges.len(), 1);

        let whole_graph = api
            .whole_vault_graph(WholeVaultGraphRequest::with_request_id(62, 10, 10))
            .expect("whole vault graph");
        assert_eq!(whole_graph.request_id, 62);
        assert_eq!(whole_graph.generation, 1);
        assert_eq!(whole_graph.state, ReadState::Complete);
        assert_eq!(whole_graph.value.nodes.len(), 3);
        assert_eq!(whole_graph.value.edges.len(), 3);
        assert!(whole_graph.value.nodes.iter().any(|node| {
            node.file_id.is_none()
                && node.relative_path.as_deref() == Some("Home.md")
                && node.label == "Home"
                && node.tags.is_empty()
        }));
        assert!(whole_graph.value.nodes.iter().any(|node| {
            node.file_id.is_none()
                && node.relative_path.as_deref() == Some("Docs/Guide.md")
                && node.label == "Guide"
        }));
        assert!(whole_graph.value.edges.iter().any(|edge| edge.weight == 1));

        let whole_graph_with_group_metadata = api
            .whole_vault_graph(
                WholeVaultGraphRequest::with_request_id(64, 10, 10)
                    .with_group_limits(1, 100, 10, 100),
            )
            .expect("whole vault graph with group metadata");
        assert!(
            whole_graph_with_group_metadata
                .value
                .nodes
                .iter()
                .any(|node| {
                    node.relative_path.as_deref() == Some("Home.md")
                        && node.tags == vec!["project/native"]
                })
        );

        let whole_with_unresolved = api
            .whole_vault_graph(
                WholeVaultGraphRequest::with_request_id(63, 10, 10).including_unresolved(true),
            )
            .expect("whole vault graph with unresolved");
        assert_eq!(whole_with_unresolved.state, ReadState::Complete);
        assert!(
            whole_with_unresolved
                .value
                .nodes
                .iter()
                .any(|node| node.file_id.is_none())
        );
    }

    fn fixture_entry(relative_path: &str) -> ScanEntry {
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

    fn assert_sql_count<T, F>(label: &str, api: &VaultReadApi, expected: usize, operation: F) -> T
    where
        F: FnOnce() -> T,
    {
        let (value, statements) = traced_sql(api, operation);
        assert_eq!(
            statements.len(),
            expected,
            "{label} SQL count changed: {statements:#?}"
        );
        value
    }

    fn traced_sql<T, F>(api: &VaultReadApi, operation: F) -> (T, Vec<String>)
    where
        F: FnOnce() -> T,
    {
        let _guard = READ_API_TRACE_LOCK.lock().expect("trace lock");
        READ_API_TRACE_SQL.lock().expect("trace sql").clear();
        api.metadata.connection.trace_v2(
            TraceEventCodes::SQLITE_TRACE_STMT,
            Some(record_read_api_sql),
        );
        let value = operation();
        api.metadata
            .connection
            .trace_v2(TraceEventCodes::empty(), None);
        let statements = READ_API_TRACE_SQL.lock().expect("trace sql").clone();
        (value, statements)
    }

    fn record_read_api_sql(event: TraceEvent<'_>) {
        if let TraceEvent::Stmt(_, sql) = event {
            if let Ok(mut statements) = READ_API_TRACE_SQL.lock() {
                statements.push(sql.to_string());
            }
        }
    }
}
