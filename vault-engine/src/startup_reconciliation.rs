pub use crate::use_cases::reconcile_startup::reconcile_startup;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::fs::path_resolver::VaultRoot;
    use crate::adapters::fs::scanner::scan_vault;
    use crate::adapters::sqlite::{
        FileRecord, IndexSchemaMetadata, IndexingQueue, IndexingQueueReason, MetadataStore,
    };
    use crate::core::scan::ScanSummary;
    use std::fs;
    use std::path::PathBuf;
    use tempfile::TempDir;

    #[test]
    fn leaves_unchanged_search_indexed_files_unqueued() {
        let fixture = ReconciliationFixture::new();
        fixture.write_note("Home.md", "# Home\n");
        let scan = fixture.scan();
        let mut store = fixture.store();
        store_scan_as_search_indexed(&mut store, &scan, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let summary = reconcile_startup(&store, &mut queue, &scan, 2).expect("reconcile");

        assert_eq!(summary.unchanged, 1);
        assert_eq!(summary.enqueued, 0);
        assert_eq!(queue.summary().expect("queue").pending, 0);
    }

    #[test]
    fn enqueues_created_files() {
        let fixture = ReconciliationFixture::new();
        fixture.write_note("Home.md", "# Home\n");
        let store = fixture.store();
        let scan = fixture.scan();
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let summary = reconcile_startup(&store, &mut queue, &scan, 2).expect("reconcile");
        let item = queue
            .get_by_file_id("home.md")
            .expect("queue item")
            .expect("queue item");

        assert_eq!(summary.created, 1);
        assert_eq!(summary.enqueued, 1);
        assert_eq!(item.reason, IndexingQueueReason::FileCreated);
        assert_eq!(item.generation, 2);
    }

    #[test]
    fn enqueues_modified_files() {
        let fixture = ReconciliationFixture::new();
        fixture.write_note("Home.md", "# Home\n");
        let initial = fixture.scan();
        let mut store = fixture.store();
        store_scan_as_search_indexed(&mut store, &initial, 1);
        fixture.write_note("Home.md", "# Home\nchanged\n");
        let changed = fixture.scan();
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let summary = reconcile_startup(&store, &mut queue, &changed, 2).expect("reconcile");
        let item = queue
            .get_by_file_id("home.md")
            .expect("queue item")
            .expect("queue item");

        assert_eq!(summary.modified, 1);
        assert_eq!(summary.enqueued, 1);
        assert_eq!(item.reason, IndexingQueueReason::FileChanged);
    }

    #[test]
    fn enqueues_deleted_files() {
        let fixture = ReconciliationFixture::new();
        fixture.write_note("Home.md", "# Home\n");
        let initial = fixture.scan();
        let mut store = fixture.store();
        store_scan_as_search_indexed(&mut store, &initial, 1);
        fs::remove_file(fixture.path("Home.md")).expect("delete");
        let changed = fixture.scan();
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let summary = reconcile_startup(&store, &mut queue, &changed, 2).expect("reconcile");
        let item = queue
            .get_by_file_id("home.md")
            .expect("queue item")
            .expect("queue item");

        assert_eq!(summary.deleted, 1);
        assert_eq!(summary.enqueued, 1);
        assert_eq!(item.reason, IndexingQueueReason::FileDeleted);
        assert_eq!(item.generation, 2);
    }

    #[test]
    fn treats_rename_as_delete_create() {
        let fixture = ReconciliationFixture::new();
        fixture.write_note("Home.md", "# Home\n");
        let initial = fixture.scan();
        let mut store = fixture.store();
        store_scan_as_search_indexed(&mut store, &initial, 1);
        fs::rename(fixture.path("Home.md"), fixture.path("Renamed.md")).expect("rename");
        let changed = fixture.scan();
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let summary = reconcile_startup(&store, &mut queue, &changed, 2).expect("reconcile");

        assert_eq!(summary.created, 1);
        assert_eq!(summary.deleted, 1);
        assert_eq!(summary.renamed_as_delete_create, 1);
        assert_eq!(summary.enqueued, 2);
        assert_eq!(
            queue
                .get_by_file_id("renamed.md")
                .expect("created")
                .expect("created")
                .reason,
            IndexingQueueReason::FileCreated
        );
        assert_eq!(
            queue
                .get_by_file_id("home.md")
                .expect("deleted")
                .expect("deleted")
                .reason,
            IndexingQueueReason::FileDeleted
        );
    }

    #[test]
    fn enqueues_incomplete_cached_files_even_when_metadata_matches() {
        let fixture = ReconciliationFixture::new();
        fixture.write_note("Home.md", "# Home\n");
        let scan = fixture.scan();
        let mut store = fixture.store();
        store_scan_as_parsed(&mut store, &scan, 1);
        let mut queue = IndexingQueue::open_in_memory().expect("queue");

        let summary = reconcile_startup(&store, &mut queue, &scan, 2).expect("reconcile");

        assert_eq!(summary.incomplete, 1);
        assert_eq!(summary.enqueued, 1);
        assert_eq!(
            queue
                .get_by_file_id("home.md")
                .expect("queue item")
                .expect("queue item")
                .reason,
            IndexingQueueReason::FileChanged
        );
    }

    struct ReconciliationFixture {
        _temp: TempDir,
        root_path: PathBuf,
        root: VaultRoot,
    }

    impl ReconciliationFixture {
        fn new() -> Self {
            let temp = tempfile::tempdir().expect("tempdir");
            let root = VaultRoot::open(temp.path()).expect("root");
            Self {
                root_path: temp.path().to_path_buf(),
                root,
                _temp: temp,
            }
        }

        fn path(&self, relative_path: &str) -> PathBuf {
            self.root_path.join(relative_path)
        }

        fn write_note(&self, relative_path: &str, contents: &str) {
            if let Some(parent) = self.path(relative_path).parent() {
                fs::create_dir_all(parent).expect("parent");
            }
            fs::write(self.path(relative_path), contents).expect("write note");
        }

        fn scan(&self) -> ScanSummary {
            scan_vault(&self.root).expect("scan")
        }

        fn store(&self) -> MetadataStore {
            let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
            MetadataStore::open_in_memory(&metadata).expect("store")
        }
    }

    fn store_scan_as_search_indexed(
        store: &mut MetadataStore,
        scan: &ScanSummary,
        generation: u64,
    ) {
        for entry in &scan.entries {
            let mut file = FileRecord::from_scan_entry(entry, generation);
            file.mark_search_indexed();
            store
                .replace_file_records(&file, &[], &[], &[], &[], &[])
                .expect("store file");
        }
    }

    fn store_scan_as_parsed(store: &mut MetadataStore, scan: &ScanSummary, generation: u64) {
        for entry in &scan.entries {
            let mut file = FileRecord::from_scan_entry(entry, generation);
            file.mark_parsed("hash");
            store
                .replace_file_records(&file, &[], &[], &[], &[], &[])
                .expect("store file");
        }
    }
}
