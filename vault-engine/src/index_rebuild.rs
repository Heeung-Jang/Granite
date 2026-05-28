#[cfg(test)]
mod tests {
    use crate::adapters::fs::index_directory::mark_engine_owned_for_test;
    use crate::adapters::sqlite::{
        FileRecord, IndexSchemaMetadata, IndexingQueue, IndexingQueueReason, IndexingQueueStatus,
        MetadataStore, MetadataTable,
    };
    use crate::core::files::FileIdentity;
    use crate::core::scan::{ScanEntry, ScanEntryKind, ScanSummary};
    use crate::use_cases::index_rebuild::{
        IndexRebuildError, IndexRebuildPathError, IndexRebuildPaths, IndexRebuildReason,
        IndexRebuildStart, MetadataOpenRecovery, abort_index_rebuild, commit_index_rebuild,
        open_metadata_or_start_rebuild, start_index_rebuild,
    };
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;
    use std::time::{Duration, UNIX_EPOCH};
    use tempfile::TempDir;

    #[test]
    fn user_rebuild_cancels_generation_and_queues_new_work_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        fs::write(fixture.paths.data_directory.join("old.index"), "old").expect("old index");
        fixture.create_engine_directory(&fixture.paths.rebuild_directory);
        fs::write(fixture.paths.rebuild_directory.join("stale.tmp"), "stale")
            .expect("stale rebuild");
        let scan = synthetic_scan(2, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &FileRecord::from_scan_entry(&scan.entries[0], 1),
                IndexingQueueReason::InitialScan,
            )
            .expect("old item");

        let start = start_index_rebuild(
            &mut queue,
            &scan,
            &fixture.paths,
            1,
            IndexRebuildReason::UserRequested,
        )
        .expect("start rebuild");

        assert_eq!(start.reason, IndexRebuildReason::UserRequested);
        assert_eq!(start.generation, 2);
        assert_eq!(start.cancelled_items, 1);
        assert_eq!(start.enqueued_items, 2);
        assert!(fixture.paths.data_directory.join("old.index").exists());
        assert!(!fixture.paths.rebuild_directory.join("stale.tmp").exists());
        assert!(
            fixture
                .paths
                .rebuild_directory
                .join("rebuild.json")
                .exists()
        );
        assert_eq!(fixture.read_vault_note(), "private");

        let leased = queue.lease_batch(10).expect("lease");
        assert_eq!(leased.len(), 2);
        assert!(leased.iter().all(|item| item.generation == 2));
        assert!(
            leased
                .iter()
                .all(|item| item.reason == IndexingQueueReason::Rebuild)
        );
        assert!(
            leased
                .iter()
                .all(|item| item.status == IndexingQueueStatus::InProgress)
        );
    }

    #[test]
    fn commit_rebuild_swaps_data_and_removes_previous_inside_index_root() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fixture.create_engine_directory(&fixture.paths.data_directory);
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "old");
        fixture.create_engine_directory(&fixture.paths.rebuild_directory);
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "new");

        let commit = commit_index_rebuild(&fixture.paths).expect("commit rebuild");

        assert_eq!(commit.data_directory, fixture.paths.data_directory);
        assert!(commit.previous_data_removed);
        assert!(!fixture.paths.rebuild_directory.exists());
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.data_directory),
            "new"
        );
        assert!(!fixture.paths.index_root.join("previous-data").exists());
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn rejects_rebuild_data_directory_that_overlaps_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        let bad_paths = IndexRebuildPaths::new(
            &fixture.vault_root,
            fixture.temp.path(),
            &fixture.vault_root,
            fixture.temp.path().join("rebuild"),
        );
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let result = start_index_rebuild(
            &mut queue,
            &scan,
            &bad_paths,
            1,
            IndexRebuildReason::UserRequested,
        );

        assert!(matches!(
            result,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataOverlapsVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn rejects_index_root_inside_vault_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        let bad_paths = IndexRebuildPaths::new(
            &fixture.vault_root,
            fixture.vault_root.join(".native-markdown-index"),
            fixture
                .vault_root
                .join(".native-markdown-index")
                .join("data"),
            fixture
                .vault_root
                .join(".native-markdown-index")
                .join("rebuild"),
        );
        let result = start_rebuild_with_paths(&bad_paths);

        assert!(matches!(
            result,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::IndexRootInsideVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn rejects_data_or_rebuild_outside_index_root_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        let data_outside = IndexRebuildPaths::new(
            &fixture.vault_root,
            &fixture.paths.index_root,
            fixture.temp.path().join("outside-data"),
            &fixture.paths.rebuild_directory,
        );
        let rebuild_outside = IndexRebuildPaths::new(
            &fixture.vault_root,
            &fixture.paths.index_root,
            &fixture.paths.data_directory,
            fixture.temp.path().join("outside-rebuild"),
        );

        assert!(matches!(
            start_rebuild_with_paths(&data_outside),
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataOutsideIndexRoot
            ))
        ));
        assert!(matches!(
            start_rebuild_with_paths(&rebuild_outside),
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::RebuildOutsideIndexRoot
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn rejects_data_equal_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        let bad_paths = IndexRebuildPaths::new(
            &fixture.vault_root,
            &fixture.paths.index_root,
            &fixture.paths.data_directory,
            &fixture.paths.data_directory,
        );
        let result = start_rebuild_with_paths(&bad_paths);

        assert!(matches!(
            result,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataEqualsRebuild
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinked_data_and_rebuild_paths_into_vault_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.index_root).expect("index root");
        symlink(&fixture.vault_root, &fixture.paths.data_directory).expect("data symlink");

        assert!(matches!(
            start_rebuild_with_paths(&fixture.paths),
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataOverlapsVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
        fs::remove_file(&fixture.paths.data_directory).expect("remove data symlink");
        symlink(&fixture.vault_root, &fixture.paths.rebuild_directory).expect("rebuild symlink");

        assert!(matches!(
            start_rebuild_with_paths(&fixture.paths),
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::RebuildOverlapsVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[cfg(unix)]
    #[test]
    fn rejects_data_parent_symlink_into_vault_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        let support_symlink = fixture.temp.path().join("support");
        symlink(&fixture.vault_root, &support_symlink).expect("support symlink");
        let index_root = support_symlink.join("Indexes").join("vault-id");
        let bad_paths = IndexRebuildPaths::new(
            &fixture.vault_root,
            &index_root,
            index_root.join("data"),
            index_root.join("rebuild"),
        );

        let start = start_rebuild_with_paths(&bad_paths);
        let commit = commit_index_rebuild(&bad_paths);

        assert!(matches!(
            start,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataOverlapsVault
            ))
        ));
        assert!(matches!(
            commit,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataOverlapsVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
        assert!(!fixture.vault_root.join("Indexes").exists());
    }

    #[cfg(unix)]
    #[test]
    fn rejects_rebuild_parent_symlink_into_vault_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.index_root).expect("index root");
        let rebuild_parent = fixture.paths.index_root.join("rebuild-parent");
        symlink(&fixture.vault_root, &rebuild_parent).expect("rebuild parent symlink");
        let bad_paths = IndexRebuildPaths::new(
            &fixture.vault_root,
            &fixture.paths.index_root,
            &fixture.paths.data_directory,
            rebuild_parent.join("rebuild"),
        );

        let result = start_rebuild_with_paths(&bad_paths);

        assert!(matches!(
            result,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::RebuildOverlapsVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
        assert!(!fixture.vault_root.join("rebuild").exists());
    }

    #[cfg(unix)]
    #[test]
    fn rejects_previous_data_symlink_into_vault_before_commit_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "old");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "new");
        symlink(
            &fixture.vault_root,
            fixture.paths.index_root.join("previous-data"),
        )
        .expect("previous-data symlink");

        let result = commit_index_rebuild(&fixture.paths);

        assert!(matches!(
            result,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::DataOverlapsVault
            ))
        ));
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.data_directory),
            "old"
        );
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.rebuild_directory),
            "new"
        );
    }

    #[test]
    fn corrupt_metadata_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        fs::write(&metadata_path, "not sqlite").expect("corrupt metadata");
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover corrupt metadata");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::CorruptIndex);
        assert_eq!(start.generation, 2);
        assert_eq!(start.enqueued_items, 1);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn compatible_metadata_opens_without_starting_rebuild() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let store = MetadataStore::open(&metadata_path, &expected).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("open compatible metadata");

        let MetadataOpenRecovery::Opened(store) = recovery else {
            panic!("expected opened metadata");
        };
        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 0);
        assert!(!fixture.paths.rebuild_directory.exists());
        assert_eq!(queue.summary().expect("queue").pending, 0);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn abort_rebuild_removes_rebuild_directory_without_touching_data() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "active");
        fixture.create_engine_directory(&fixture.paths.rebuild_directory);
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "stale");

        abort_index_rebuild(&fixture.paths).expect("abort rebuild");

        assert!(!fixture.paths.rebuild_directory.exists());
        assert!(
            fixture
                .paths
                .data_directory
                .join("metadata.sqlite")
                .exists()
        );
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn user_rebuild_replaces_unmarked_rebuild_directory_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "stale");

        let start = start_rebuild_with_paths(&fixture.paths).expect("start rebuild");

        assert_eq!(start.generation, 2);
        assert_eq!(fixture.read_vault_note(), "private");
        assert!(!fixture.paths.rebuild_directory.join("stale.tmp").exists());
        assert!(
            fixture
                .paths
                .rebuild_directory
                .join("rebuild.json")
                .exists()
        );
    }

    #[test]
    fn abort_rebuild_removes_unmarked_rebuild_directory_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "stale");

        abort_index_rebuild(&fixture.paths).expect("abort rebuild");

        assert_eq!(fixture.read_vault_note(), "private");
        assert!(!fixture.paths.rebuild_directory.exists());
    }

    #[test]
    fn commit_rebuild_replaces_unmarked_data_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "old");
        fixture.create_engine_directory(&fixture.paths.rebuild_directory);
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "new");

        let commit = commit_index_rebuild(&fixture.paths).expect("commit rebuild");

        assert!(commit.previous_data_removed);
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.data_directory),
            "new"
        );
        assert!(!fixture.paths.rebuild_directory.exists());
    }

    #[test]
    fn commit_rebuild_replaces_unmarked_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fixture.create_engine_directory(&fixture.paths.data_directory);
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "old");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "new");

        let commit = commit_index_rebuild(&fixture.paths).expect("commit rebuild");

        assert!(commit.previous_data_removed);
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.data_directory),
            "new"
        );
        assert!(!fixture.paths.rebuild_directory.exists());
    }

    #[test]
    fn commit_rebuild_replaces_unmarked_previous_data_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fixture.create_engine_directory(&fixture.paths.data_directory);
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "old");
        fixture.create_engine_directory(&fixture.paths.rebuild_directory);
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "new");
        fs::create_dir_all(fixture.paths.index_root.join("previous-data")).expect("previous data");
        fixture.write_metadata_artifact(&fixture.paths.index_root.join("previous-data"), "stale");

        let commit = commit_index_rebuild(&fixture.paths).expect("commit rebuild");

        assert!(commit.previous_data_removed);
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.data_directory),
            "new"
        );
        assert!(!fixture.paths.rebuild_directory.exists());
        assert!(!fixture.paths.index_root.join("previous-data").exists());
    }

    #[test]
    fn user_rebuild_rejects_unmarked_rebuild_with_unknown_entry_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fs::write(fixture.paths.rebuild_directory.join("stale.tmp"), "stale")
            .expect("unknown rebuild file");

        let result = start_rebuild_with_paths(&fixture.paths);

        assert_unexpected_index_entry(result);
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fs::read_to_string(fixture.paths.rebuild_directory.join("stale.tmp"))
                .expect("unknown rebuild file"),
            "stale"
        );
    }

    #[test]
    fn abort_rebuild_rejects_unmarked_rebuild_with_unknown_entry_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fs::write(fixture.paths.rebuild_directory.join("stale.tmp"), "stale")
            .expect("unknown rebuild file");

        let result = abort_index_rebuild(&fixture.paths);

        assert_unexpected_index_entry(result);
        assert_eq!(fixture.read_vault_note(), "private");
        assert!(fixture.paths.rebuild_directory.join("stale.tmp").exists());
    }

    #[test]
    fn commit_rebuild_rejects_unmarked_data_with_unknown_entry_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        fs::write(fixture.paths.data_directory.join("old.index"), "old").expect("old index");
        fixture.create_engine_directory(&fixture.paths.rebuild_directory);
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "new");

        let result = commit_index_rebuild(&fixture.paths);

        assert_unexpected_index_entry(result);
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fs::read_to_string(fixture.paths.data_directory.join("old.index")).expect("old index"),
            "old"
        );
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.rebuild_directory),
            "new"
        );
    }

    #[test]
    fn commit_rebuild_rejects_unmarked_rebuild_with_unknown_entry_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fixture.create_engine_directory(&fixture.paths.data_directory);
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "old");
        fs::create_dir_all(&fixture.paths.rebuild_directory).expect("rebuild");
        fs::write(fixture.paths.rebuild_directory.join("new.index"), "new").expect("new index");

        let result = commit_index_rebuild(&fixture.paths);

        assert_unexpected_index_entry(result);
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.data_directory),
            "old"
        );
        assert_eq!(
            fs::read_to_string(fixture.paths.rebuild_directory.join("new.index"))
                .expect("new index"),
            "new"
        );
    }

    #[test]
    fn commit_rebuild_rejects_unmarked_previous_data_with_unknown_entry_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fixture.create_engine_directory(&fixture.paths.data_directory);
        fixture.write_metadata_artifact(&fixture.paths.data_directory, "old");
        fixture.create_engine_directory(&fixture.paths.rebuild_directory);
        fixture.write_metadata_artifact(&fixture.paths.rebuild_directory, "new");
        fs::create_dir_all(fixture.paths.index_root.join("previous-data")).expect("previous data");
        fs::write(
            fixture
                .paths
                .index_root
                .join("previous-data")
                .join("stale.index"),
            "stale",
        )
        .expect("stale previous");

        let result = commit_index_rebuild(&fixture.paths);

        assert_unexpected_index_entry(result);
        assert_eq!(fixture.read_vault_note(), "private");
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.data_directory),
            "old"
        );
        assert_eq!(
            fixture.read_metadata_artifact(&fixture.paths.rebuild_directory),
            "new"
        );
        assert_eq!(
            fs::read_to_string(
                fixture
                    .paths
                    .index_root
                    .join("previous-data")
                    .join("stale.index")
            )
            .expect("stale previous"),
            "stale"
        );
    }

    #[test]
    fn schema_mismatch_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let stored = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tokenizer-v1", 1);
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tokenizer-v2", 1);
        let store = MetadataStore::open(&metadata_path, &stored).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover schema mismatch");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::SchemaMismatch);
        assert_eq!(start.generation, 2);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn snippet_storage_mismatch_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let stored = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "stored_body", 1);
        let expected =
            IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "lazy_source_experiment", 1);
        let store = MetadataStore::open(&metadata_path, &stored).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover snippet mismatch");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::SchemaMismatch);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    #[test]
    fn backend_mismatch_starts_rebuild_without_touching_vault() {
        let fixture = RebuildFixture::new();
        fixture.write_vault_note("private");
        fs::create_dir_all(&fixture.paths.data_directory).expect("data");
        let metadata_path = fixture.paths.data_directory.join("metadata.sqlite");
        let stored = IndexSchemaMetadata::new("sqlite-fts", "metadata-v1", "tantivy", 1);
        let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let store = MetadataStore::open(&metadata_path, &stored).expect("stored metadata");
        drop(store);
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let recovery = open_metadata_or_start_rebuild(
            &metadata_path,
            &expected,
            &mut queue,
            &scan,
            &fixture.paths,
            1,
        )
        .expect("recover backend mismatch");

        let MetadataOpenRecovery::RebuildStarted(start) = recovery else {
            panic!("expected rebuild");
        };
        assert_eq!(start.reason, IndexRebuildReason::BackendMismatch);
        assert_eq!(start.generation, 2);
        assert_eq!(fixture.read_vault_note(), "private");
    }

    struct RebuildFixture {
        temp: TempDir,
        vault_root: PathBuf,
        paths: IndexRebuildPaths,
    }

    impl RebuildFixture {
        fn new() -> Self {
            let temp = tempfile::tempdir().expect("tempdir");
            let vault_root = temp.path().join("vault");
            let index_root = temp.path().join("support").join("Indexes").join("vault-id");
            let data_directory = index_root.join("data");
            let rebuild_directory = index_root.join("rebuild");
            fs::create_dir_all(&vault_root).expect("vault");
            let paths =
                IndexRebuildPaths::new(&vault_root, index_root, data_directory, rebuild_directory);
            Self {
                temp,
                vault_root,
                paths,
            }
        }

        fn write_vault_note(&self, content: &str) {
            fs::write(self.vault_root.join("Note.md"), content).expect("vault note");
        }

        fn read_vault_note(&self) -> String {
            fs::read_to_string(self.vault_root.join("Note.md")).expect("vault note")
        }

        fn write_metadata_artifact(&self, path: &std::path::Path, content: &str) {
            fs::create_dir_all(path).expect("artifact directory");
            fs::write(path.join("metadata.sqlite"), content).expect("metadata artifact");
        }

        fn read_metadata_artifact(&self, path: &std::path::Path) -> String {
            fs::read_to_string(path.join("metadata.sqlite")).expect("metadata artifact")
        }

        fn create_engine_directory(&self, path: &std::path::Path) {
            mark_engine_owned_for_test(path).expect("engine owned directory");
        }
    }

    fn start_rebuild_with_paths(
        paths: &IndexRebuildPaths,
    ) -> Result<IndexRebuildStart, IndexRebuildError> {
        let scan = synthetic_scan(1, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        start_index_rebuild(
            &mut queue,
            &scan,
            paths,
            1,
            IndexRebuildReason::UserRequested,
        )
    }

    fn assert_unexpected_index_entry<T>(result: Result<T, IndexRebuildError>) {
        assert!(matches!(
            result,
            Err(IndexRebuildError::InvalidPath(
                IndexRebuildPathError::UnexpectedIndexDirectoryEntry
            ))
        ));
    }

    fn synthetic_scan(count: usize, generation_seed: u64) -> ScanSummary {
        let entries = (0..count)
            .map(|index| ScanEntry {
                relative_path: PathBuf::from(format!("Note-{index:05}.md")),
                kind: ScanEntryKind::Markdown,
                size_bytes: 10,
                modified: Some(UNIX_EPOCH + Duration::from_secs(generation_seed)),
                file_identity: FileIdentity {
                    device: 1,
                    inode: index as u64 + 100,
                },
            })
            .collect::<Vec<_>>();
        ScanSummary {
            markdown_files: entries.len(),
            entries,
            attachment_files: 0,
            other_files: 0,
            skipped_directories: 0,
            skipped_symlinks: 0,
        }
    }
}
