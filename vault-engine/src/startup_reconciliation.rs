use std::collections::{HashMap, HashSet};
use std::fmt;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::adapters::sqlite::{FileIndexStatus, FileRecord, MetadataStore, MetadataStoreError};
use crate::adapters::sqlite::{
    IndexingQueue, IndexingQueueError, IndexingQueueReason, IndexingQueueResult,
};
use crate::paths::FileIdentity;
use crate::scanner::ScanSummary;

const FILE_PAGE_SIZE: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct StartupReconciliationSummary {
    pub unchanged: usize,
    pub created: usize,
    pub modified: usize,
    pub deleted: usize,
    pub incomplete: usize,
    pub renamed_as_delete_create: usize,
    pub enqueued: usize,
}

#[derive(Debug)]
pub enum StartupReconciliationError {
    Metadata(MetadataStoreError),
    Queue(IndexingQueueError),
}

pub type StartupReconciliationResult<T> = Result<T, StartupReconciliationError>;

pub fn reconcile_startup(
    metadata: &MetadataStore,
    queue: &mut IndexingQueue,
    scan: &ScanSummary,
    generation: u64,
) -> StartupReconciliationResult<StartupReconciliationSummary> {
    let stored_files = load_all_files(metadata)?;
    let stored_by_id = stored_files
        .iter()
        .map(|file| (file.file_id.clone(), file.clone()))
        .collect::<HashMap<_, _>>();
    let current_files = scan
        .entries
        .iter()
        .map(|entry| FileRecord::from_scan_entry(entry, generation))
        .collect::<Vec<_>>();
    let current_by_id = current_files
        .iter()
        .map(|file| (file.file_id.clone(), file.clone()))
        .collect::<HashMap<_, _>>();
    let stored_missing_identities = stored_files
        .iter()
        .filter(|file| !current_by_id.contains_key(&file.file_id))
        .map(|file| identity_key(&file.file_identity))
        .collect::<HashSet<_>>();
    let current_created_identities = current_files
        .iter()
        .filter(|file| !stored_by_id.contains_key(&file.file_id))
        .map(|file| identity_key(&file.file_identity))
        .collect::<HashSet<_>>();

    let mut summary = StartupReconciliationSummary::default();

    for current in &current_files {
        match stored_by_id.get(&current.file_id) {
            Some(stored) if file_metadata_matches(stored, current) => {
                if stored.status == FileIndexStatus::SearchIndexed {
                    summary.unchanged += 1;
                } else {
                    summary.incomplete += 1;
                    enqueue(
                        queue,
                        current,
                        IndexingQueueReason::FileChanged,
                        &mut summary,
                    )?;
                }
            }
            Some(_) => {
                summary.modified += 1;
                enqueue(
                    queue,
                    current,
                    IndexingQueueReason::FileChanged,
                    &mut summary,
                )?;
            }
            None => {
                summary.created += 1;
                if stored_missing_identities.contains(&identity_key(&current.file_identity)) {
                    summary.renamed_as_delete_create += 1;
                }
                enqueue(
                    queue,
                    current,
                    IndexingQueueReason::FileCreated,
                    &mut summary,
                )?;
            }
        }
    }

    for stored in &stored_files {
        if current_by_id.contains_key(&stored.file_id) {
            continue;
        }

        summary.deleted += 1;
        if current_created_identities.contains(&identity_key(&stored.file_identity))
            && summary.renamed_as_delete_create == 0
        {
            summary.renamed_as_delete_create += 1;
        }
        let mut tombstone = stored.clone();
        tombstone.mark_tombstoned(generation);
        enqueue(
            queue,
            &tombstone,
            IndexingQueueReason::FileDeleted,
            &mut summary,
        )?;
    }

    Ok(summary)
}

fn load_all_files(metadata: &MetadataStore) -> Result<Vec<FileRecord>, MetadataStoreError> {
    let mut files = Vec::new();
    let mut offset = 0;
    loop {
        let page = metadata.list_files(offset, FILE_PAGE_SIZE)?;
        if page.is_empty() {
            break;
        }
        offset += page.len();
        files.extend(page);
    }
    Ok(files)
}

fn enqueue(
    queue: &mut IndexingQueue,
    file: &FileRecord,
    reason: IndexingQueueReason,
    summary: &mut StartupReconciliationSummary,
) -> IndexingQueueResult<()> {
    queue.enqueue_file(file, reason)?;
    summary.enqueued += 1;
    Ok(())
}

fn file_metadata_matches(stored: &FileRecord, current: &FileRecord) -> bool {
    stored.relative_path == current.relative_path
        && stored.kind == current.kind
        && stored.size_bytes == current.size_bytes
        && system_time_to_unix_ms(stored.modified) == system_time_to_unix_ms(current.modified)
        && stored.file_identity == current.file_identity
}

fn identity_key(identity: &FileIdentity) -> (u64, u64) {
    (identity.device, identity.inode)
}

fn system_time_to_unix_ms(time: Option<SystemTime>) -> Option<u128> {
    time.and_then(|value| {
        value
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_millis())
    })
}

impl fmt::Display for StartupReconciliationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Metadata(error) => {
                write!(formatter, "startup reconciliation metadata error: {error}")
            }
            Self::Queue(error) => write!(formatter, "startup reconciliation queue error: {error}"),
        }
    }
}

impl std::error::Error for StartupReconciliationError {}

impl From<MetadataStoreError> for StartupReconciliationError {
    fn from(error: MetadataStoreError) -> Self {
        Self::Metadata(error)
    }
}

impl From<IndexingQueueError> for StartupReconciliationError {
    fn from(error: IndexingQueueError) -> Self {
        Self::Queue(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::sqlite::IndexSchemaMetadata;
    use crate::paths::VaultRoot;
    use crate::scanner::scan_vault;
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
