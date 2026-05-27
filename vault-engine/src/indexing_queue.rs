pub use crate::adapters::sqlite::{IndexingQueue, IndexingQueueReason, IndexingQueueStatus};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::sqlite::FileRecord;
    use crate::adapters::sqlite::MAX_INDEX_ERROR_CHARS;
    use crate::paths::VaultRoot;
    use crate::scanner::{ScanEntry, scan_vault};
    use std::path::PathBuf;
    use tempfile::tempdir;

    #[test]
    fn leases_bounded_batches_and_marks_completion() {
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        for path in ["Home.md", "Folder/Target.md", "Docs/Guide.md"] {
            queue
                .enqueue_file(&fixture_file(path, 1), IndexingQueueReason::InitialScan)
                .expect("enqueue");
        }

        let leased = queue.lease_batch(2).expect("lease");

        assert_eq!(leased.len(), 2);
        assert!(leased.iter().all(|item| item.leased_at.is_some()));
        assert_eq!(queue.summary().expect("summary").in_progress, 2);

        queue.complete(leased[0].item_id).expect("complete");
        let summary = queue.summary().expect("summary");
        assert_eq!(summary.completed, 1);
        assert_eq!(summary.in_progress, 1);
        assert_eq!(summary.pending, 1);
    }

    #[test]
    fn recovers_in_progress_items_after_restart() {
        let dir = tempdir().expect("tempdir");
        let queue_path = dir.path().join("indexing-queue.sqlite");
        let item_id = {
            let mut queue = IndexingQueue::open(&queue_path).expect("queue");
            queue
                .enqueue_file(
                    &fixture_file("Home.md", 1),
                    IndexingQueueReason::InitialScan,
                )
                .expect("enqueue");
            queue.lease_batch(1).expect("lease")[0].item_id
        };

        let mut queue = IndexingQueue::open(&queue_path).expect("reopen queue");
        assert_eq!(
            queue.get(item_id).expect("item").expect("item").status,
            IndexingQueueStatus::InProgress
        );

        assert_eq!(queue.recover_interrupted().expect("recover"), 1);
        let leased = queue.lease_batch(1).expect("lease recovered");

        assert_eq!(leased[0].item_id, item_id);
        assert_eq!(leased[0].status, IndexingQueueStatus::InProgress);
    }

    #[test]
    fn retries_failed_items_until_attempt_budget_is_exhausted() {
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &fixture_file("Home.md", 1),
                IndexingQueueReason::InitialScan,
            )
            .expect("enqueue");
        let item_id = queue.lease_batch(1).expect("lease")[0].item_id;

        let retry = queue
            .record_failure(item_id, "transient parse failure", 2)
            .expect("retry");

        assert_eq!(retry.status, IndexingQueueStatus::Pending);
        assert_eq!(retry.attempts, 1);
        assert_eq!(retry.last_error.as_deref(), Some("transient parse failure"));

        let item_id = queue.lease_batch(1).expect("lease retry")[0].item_id;
        let failed = queue
            .record_failure(item_id, "permanent parse failure", 2)
            .expect("failed");

        assert_eq!(failed.status, IndexingQueueStatus::Failed);
        assert_eq!(failed.attempts, 2);
        assert_eq!(queue.lease_batch(1).expect("no lease").len(), 0);
    }

    #[test]
    fn record_failure_truncates_long_errors() {
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &fixture_file("Home.md", 1),
                IndexingQueueReason::InitialScan,
            )
            .expect("enqueue");
        let item_id = queue.lease_batch(1).expect("lease")[0].item_id;
        let error = "오류".repeat(MAX_INDEX_ERROR_CHARS + 20);

        let failed = queue.record_failure(item_id, error, 1).expect("failed");

        assert_eq!(failed.status, IndexingQueueStatus::Failed);
        assert_eq!(
            failed.last_error.expect("error").chars().count(),
            MAX_INDEX_ERROR_CHARS
        );
    }

    #[test]
    fn cancels_generation_and_excludes_cancelled_items_from_leases() {
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &fixture_file("Home.md", 1),
                IndexingQueueReason::InitialScan,
            )
            .expect("enqueue one");
        queue
            .enqueue_file(
                &fixture_file("Folder/Target.md", 2),
                IndexingQueueReason::FileChanged,
            )
            .expect("enqueue two");

        assert_eq!(queue.cancel_generation(1).expect("cancel"), 1);
        let leased = queue.lease_batch(10).expect("lease");

        assert_eq!(leased.len(), 1);
        assert_eq!(leased[0].generation, 2);
        assert_eq!(queue.summary().expect("summary").cancelled, 1);
    }

    #[test]
    fn newer_generation_replaces_older_file_work() {
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(
                &fixture_file("Home.md", 1),
                IndexingQueueReason::InitialScan,
            )
            .expect("enqueue old");
        queue
            .enqueue_file(
                &fixture_file("Home.md", 2),
                IndexingQueueReason::FileChanged,
            )
            .expect("enqueue new");
        queue
            .enqueue_file(&fixture_file("Home.md", 1), IndexingQueueReason::Rebuild)
            .expect("ignore older");

        let item = queue.get_by_file_id("home.md").expect("get").expect("item");

        assert_eq!(item.generation, 2);
        assert_eq!(item.reason, IndexingQueueReason::FileChanged);
        assert_eq!(queue.summary().expect("summary").pending, 1);
    }

    #[test]
    fn same_generation_watcher_change_does_not_replace_own_save_work() {
        let mut queue = IndexingQueue::open_in_memory().expect("queue");
        queue
            .enqueue_file(&fixture_file("Home.md", 2), IndexingQueueReason::OwnSave)
            .expect("enqueue own save");
        let watcher_item = queue
            .enqueue_file(
                &fixture_file("Home.md", 2),
                IndexingQueueReason::FileChanged,
            )
            .expect("watcher change");

        let item = queue.get_by_file_id("home.md").expect("get").expect("item");

        assert_eq!(watcher_item.reason, IndexingQueueReason::OwnSave);
        assert_eq!(item.reason, IndexingQueueReason::OwnSave);
        assert_eq!(item.generation, 2);
        assert_eq!(queue.summary().expect("summary").pending, 1);
    }

    fn fixture_file(relative_path: &str, generation: u64) -> FileRecord {
        FileRecord::from_scan_entry(&fixture_entry(relative_path), generation)
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
}
