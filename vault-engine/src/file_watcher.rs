#[cfg(test)]
mod tests {
    use crate::adapters::fs::path_resolver::VaultRoot;
    use crate::adapters::fs::scanner::scan_vault;
    use crate::adapters::fs::watcher::{
        InitialScanState, InitialScanWatcher, WATCHER_FLAG_ITEM_MODIFIED,
        WATCHER_FLAG_KERNEL_DROPPED, WatcherEventKind,
    };
    use std::fs;
    use std::path::PathBuf;
    use tempfile::tempdir;

    #[test]
    fn starts_watcher_before_initial_scan() {
        let dir = tempdir().expect("tempdir");
        fs::write(dir.path().join("Home.md"), "# Home").expect("note");
        let root = VaultRoot::open(dir.path()).expect("root");

        let watcher = InitialScanWatcher::start_for_test(&root, 16, Some(42));

        assert!(watcher.stream_started_at() <= watcher.scan_started_at());
        assert_eq!(watcher.stream_started_event_id(), Some(42));
    }

    #[test]
    fn records_scan_time_file_changes_as_stale() {
        let dir = tempdir().expect("tempdir");
        fs::write(dir.path().join("Home.md"), "# Home").expect("note");
        let root = VaultRoot::open(dir.path()).expect("root");
        let watcher = InitialScanWatcher::start_for_test(&root, 16, Some(1));

        watcher
            .record_event_for_test("Home.md", WATCHER_FLAG_ITEM_MODIFIED, Some(2))
            .expect("event");
        let scan = scan_vault(&root).expect("scan");
        let outcome = watcher.finish(scan).expect("finish");

        assert_eq!(outcome.reconciliation.state, InitialScanState::Stale);
        assert_eq!(outcome.scan.markdown_files, 1);
        assert_eq!(outcome.reconciliation.events.len(), 1);
        assert_eq!(
            outcome.reconciliation.events[0].relative_path,
            Some(PathBuf::from("Home.md"))
        );
        assert_eq!(
            outcome.reconciliation.events[0].kind,
            WatcherEventKind::Modified
        );
    }

    #[test]
    fn marks_dropped_events_as_ambiguous_full_rescan() {
        let dir = tempdir().expect("tempdir");
        fs::write(dir.path().join("Home.md"), "# Home").expect("note");
        let root = VaultRoot::open(dir.path()).expect("root");
        let watcher = InitialScanWatcher::start_for_test(&root, 16, Some(1));

        watcher
            .record_event_for_test("Home.md", WATCHER_FLAG_KERNEL_DROPPED, Some(2))
            .expect("event");
        let outcome = watcher.finish(()).expect("finish");

        assert_eq!(outcome.reconciliation.state, InitialScanState::Ambiguous);
        assert!(outcome.reconciliation.events[0].requires_full_rescan);
    }

    #[test]
    fn marks_buffer_overflow_as_ambiguous() {
        let dir = tempdir().expect("tempdir");
        fs::write(dir.path().join("Home.md"), "# Home").expect("note");
        let root = VaultRoot::open(dir.path()).expect("root");
        let watcher = InitialScanWatcher::start_for_test(&root, 1, Some(1));

        watcher
            .record_event_for_test("Home.md", WATCHER_FLAG_ITEM_MODIFIED, Some(2))
            .expect("event");
        watcher
            .record_event_for_test("Home.md", WATCHER_FLAG_ITEM_MODIFIED, Some(3))
            .expect("overflow");
        let outcome = watcher.finish(()).expect("finish");

        assert_eq!(outcome.reconciliation.state, InitialScanState::Ambiguous);
        assert!(outcome.reconciliation.overflowed);
        assert_eq!(outcome.reconciliation.events.len(), 1);
    }
}
