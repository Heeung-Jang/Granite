pub use crate::adapters::tantivy::{
    DEFAULT_TANTIVY_WRITER_MEMORY_BUDGET_BYTES, TantivyIndexingStageMetrics, TantivySearchError,
    TantivySearchIndex, TantivySearchResult, TantivyWriterOptions, generate_lazy_source_snippet,
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::tantivy::safe_tantivy_query;
    use crate::core::search::SearchDocument;
    use crate::indexing_pipeline::SnippetStorageMode;
    use crate::paths::VaultRoot;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;

    #[test]
    fn safe_tantivy_query_bounds_and_quotes_user_input() {
        assert_eq!(
            safe_tantivy_query("Home OR title:*"),
            Some("\"Home\" \"OR\" \"title\"".to_string())
        );
        assert_eq!(safe_tantivy_query("   !!!   "), None);
    }

    #[test]
    fn writer_options_default_preserves_current_memory_budget() {
        assert_eq!(
            TantivyWriterOptions::default().memory_budget_bytes,
            DEFAULT_TANTIVY_WRITER_MEMORY_BUDGET_BYTES
        );
        assert_eq!(TantivyWriterOptions::default().writer_thread_count, None);
    }

    #[test]
    fn indexes_fixture_with_explicit_single_writer_thread() {
        let mut index = TantivySearchIndex::open_in_ram().expect("index");
        let stages = index
            .replace_documents_with_options_and_stage_durations(
                &fixture_documents(),
                TantivyWriterOptions {
                    writer_thread_count: Some(1),
                    ..Default::default()
                },
            )
            .expect("replace docs");

        assert_eq!(stages.added_document_count, 4);
        assert_eq!(stages.deleted_document_count, 4);
        assert!(stages.add_micros > 0);
        assert!(index.search("Guide", 10).expect("search").len() == 1);
    }

    #[test]
    fn add_documents_for_rebuild_indexes_fresh_index_without_deletes() {
        let mut index = TantivySearchIndex::open_in_ram().expect("index");
        let stages = index
            .add_documents_for_rebuild_from_result_iter_with_stage_durations(
                fixture_documents()
                    .into_iter()
                    .map(Ok::<SearchDocument, TantivySearchError>),
            )
            .expect("rebuild add");

        assert_eq!(stages.added_document_count, 4);
        assert_eq!(stages.deleted_document_count, 0);
        assert!(
            index
                .search("compatibility fixture", 10)
                .expect("search")
                .len()
                == 1
        );
    }

    #[test]
    fn indexes_fixture_shape_and_searches_filename_and_body() {
        let mut index = TantivySearchIndex::open_in_ram().expect("index");
        index
            .replace_documents(&fixture_documents())
            .expect("replace docs");

        let file_results = index.search("Guide", 10).expect("file search");
        assert!(
            file_results
                .iter()
                .any(|result| result.path == "Docs/Guide.md")
        );

        let body_results = index
            .search("compatibility fixture", 10)
            .expect("body search");
        assert!(body_results.iter().any(|result| result.path == "Home.md"));
        assert!(body_results.iter().any(|result| !result.snippet.is_empty()));
    }

    #[test]
    fn lazy_source_experiment_indexes_body_without_stored_snippets() {
        let mut index = TantivySearchIndex::open_in_ram_with_snippet_mode(
            SnippetStorageMode::LazySourceExperiment,
        )
        .expect("index");
        index
            .replace_documents(&fixture_documents())
            .expect("replace docs");

        let body_results = index
            .search("compatibility fixture", 10)
            .expect("body search");

        assert!(body_results.iter().any(|result| result.path == "Home.md"));
        assert!(body_results.iter().all(|result| result.snippet.is_empty()));
    }

    #[test]
    fn lazy_source_snippet_validates_path_and_file_identity() {
        let dir = tempfile::tempdir().expect("tempdir");
        let vault = dir.path().join("vault");
        fs::create_dir_all(&vault).expect("vault");
        fs::write(
            vault.join("Home.md"),
            "# Home\nExpected lazy snippet phrase inside source.",
        )
        .expect("note");
        let root = VaultRoot::open(&vault).expect("root");
        let resolved = root
            .resolve_existing_relative("Home.md")
            .expect("resolved note");

        let snippet = generate_lazy_source_snippet(
            &root,
            "Home.md",
            &resolved.file_identity,
            7,
            7,
            "lazy phrase",
            80,
        )
        .expect("snippet")
        .expect("snippet text");
        assert!(snippet.contains("lazy snippet phrase"));

        assert!(
            generate_lazy_source_snippet(
                &root,
                "Home.md",
                &resolved.file_identity,
                7,
                8,
                "lazy phrase",
                80
            )
            .expect("generation check")
            .is_none()
        );

        fs::remove_file(vault.join("Home.md")).expect("remove note");
        fs::write(vault.join("Home.md"), "# Home\nChanged content").expect("changed");
        assert!(
            generate_lazy_source_snippet(
                &root,
                "Home.md",
                &resolved.file_identity,
                7,
                7,
                "Changed",
                80
            )
            .expect("stale check")
            .is_none()
        );
        assert!(matches!(
            generate_lazy_source_snippet(
                &root,
                "../outside.md",
                &resolved.file_identity,
                7,
                7,
                "x",
                80
            ),
            Err(TantivySearchError::Path(_))
        ));
        assert!(matches!(
            generate_lazy_source_snippet(
                &root,
                &vault.join("Home.md").display().to_string(),
                &resolved.file_identity,
                7,
                7,
                "x",
                80
            ),
            Err(TantivySearchError::Path(_))
        ));

        #[cfg(unix)]
        {
            let outside = dir.path().join("outside.md");
            fs::write(&outside, "outside lazy phrase").expect("outside note");
            symlink(&outside, vault.join("Outside.md")).expect("outside symlink");
            assert!(matches!(
                generate_lazy_source_snippet(
                    &root,
                    "Outside.md",
                    &resolved.file_identity,
                    7,
                    7,
                    "lazy",
                    80
                ),
                Err(TantivySearchError::Path(_))
            ));
        }
    }

    #[test]
    fn delete_by_file_id_plus_insert_updates_document() {
        let mut index = TantivySearchIndex::open_in_ram().expect("index");
        index
            .replace_documents(&[SearchDocument {
                file_id: "note.md".to_string(),
                path: "Note.md".to_string(),
                title: "Old".to_string(),
                body: "old body".to_string(),
            }])
            .expect("initial");
        index
            .replace_documents(&[SearchDocument {
                file_id: "note.md".to_string(),
                path: "Note.md".to_string(),
                title: "New".to_string(),
                body: "fresh body".to_string(),
            }])
            .expect("update");

        assert!(index.search("fresh", 10).expect("fresh").len() == 1);
        assert!(index.search("old", 10).expect("old").is_empty());
    }

    #[test]
    fn reports_fixture_query_p95_and_file_backed_index_size() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut index = TantivySearchIndex::open_in_dir(dir.path()).expect("index");
        index
            .replace_documents(&fixture_documents())
            .expect("replace docs");

        let measurement = index
            .measure_queries(
                &[
                    "Home".to_string(),
                    "Target".to_string(),
                    "attachments".to_string(),
                ],
                10,
            )
            .expect("measurement");

        assert_eq!(measurement.sample_count, 3);
        assert!(measurement.index_size_bytes > 0);
    }

    fn fixture_documents() -> Vec<SearchDocument> {
        vec![
            SearchDocument {
                file_id: "home.md".to_string(),
                path: "Home.md".to_string(),
                title: "Home".to_string(),
                body: "Welcome to the compatibility fixture vault.".to_string(),
            },
            SearchDocument {
                file_id: "docs/guide.md".to_string(),
                path: "Docs/Guide.md".to_string(),
                title: "Guide".to_string(),
                body: "Guide links back to Home.".to_string(),
            },
            SearchDocument {
                file_id: "folder/target.md".to_string(),
                path: "Folder/Target.md".to_string(),
                title: "Target".to_string(),
                body: "This note is the resolved target for heading links.".to_string(),
            },
            SearchDocument {
                file_id: "attachments.md".to_string(),
                path: "Attachments.md".to_string(),
                title: "Attachments".to_string(),
                body: "Image embed and PDF attachment references.".to_string(),
            },
        ]
    }
}
