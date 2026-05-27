use std::fmt;

use crate::adapters::sqlite::MetadataStore;
use crate::adapters::sqlite::{IndexingQueue, IndexingQueueError};
use crate::file_watcher::WatcherEvent;
use crate::scanner::ScanSummary;
use crate::use_cases::reconcile_startup::{
    StartupReconciliationError, StartupReconciliationSummary, reconcile_startup,
};
pub use crate::use_cases::watcher_burst::{
    WatcherBurstPlan, WatcherBurstState, coalesce_watcher_burst,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatcherBurstRecovery {
    pub plan: WatcherBurstPlan,
    pub reconciliation: StartupReconciliationSummary,
    pub index_state: WatcherBurstState,
}

#[derive(Debug)]
pub enum WatcherBurstError {
    Reconciliation(StartupReconciliationError),
    Queue(IndexingQueueError),
}

pub type WatcherBurstResult<T> = Result<T, WatcherBurstError>;

pub fn recover_watcher_burst(
    metadata: &MetadataStore,
    queue: &mut IndexingQueue,
    current_scan: &ScanSummary,
    generation: u64,
    events: &[WatcherEvent],
) -> WatcherBurstResult<WatcherBurstRecovery> {
    let plan = coalesce_watcher_burst(events);
    let reconciliation = if plan.state == WatcherBurstState::Complete {
        StartupReconciliationSummary::default()
    } else {
        reconcile_startup(metadata, queue, current_scan, generation)?
    };
    let queue_summary = queue.summary()?;
    let index_state = if plan.state == WatcherBurstState::Ambiguous {
        WatcherBurstState::Ambiguous
    } else if queue_summary.pending > 0 || queue_summary.in_progress > 0 {
        WatcherBurstState::Stale
    } else {
        WatcherBurstState::Complete
    };

    Ok(WatcherBurstRecovery {
        plan,
        reconciliation,
        index_state,
    })
}

impl fmt::Display for WatcherBurstError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Reconciliation(error) => {
                write!(formatter, "watcher burst reconciliation error: {error}")
            }
            Self::Queue(error) => write!(formatter, "watcher burst queue error: {error}"),
        }
    }
}

impl std::error::Error for WatcherBurstError {}

impl From<StartupReconciliationError> for WatcherBurstError {
    fn from(error: StartupReconciliationError) -> Self {
        Self::Reconciliation(error)
    }
}

impl From<IndexingQueueError> for WatcherBurstError {
    fn from(error: IndexingQueueError) -> Self {
        Self::Queue(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::sqlite::{FileRecord, IndexSchemaMetadata, MetadataStore};
    use crate::adapters::sqlite::{IndexingQueueReason, IndexingQueueStatus};
    use crate::file_watcher::{
        WATCHER_FLAG_ITEM_MODIFIED, WATCHER_FLAG_ITEM_RENAMED, WATCHER_FLAG_KERNEL_DROPPED,
        WatcherEventKind,
    };
    use crate::paths::FileIdentity;
    use crate::scanner::{ScanEntry, ScanEntryKind};
    use std::path::PathBuf;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn coalesces_duplicate_paths_and_rescan_directories() {
        let events = vec![
            event(
                "Folder/Note.md",
                WatcherEventKind::Modified,
                WATCHER_FLAG_ITEM_MODIFIED,
            ),
            event(
                "Folder/Note.md",
                WatcherEventKind::Modified,
                WATCHER_FLAG_ITEM_MODIFIED,
            ),
            event(
                "Folder/Renamed.md",
                WatcherEventKind::Renamed,
                WATCHER_FLAG_ITEM_RENAMED,
            ),
        ];

        let plan = coalesce_watcher_burst(&events);

        assert_eq!(plan.state, WatcherBurstState::Stale);
        assert_eq!(
            plan.changed_paths,
            vec![
                PathBuf::from("Folder/Note.md"),
                PathBuf::from("Folder/Renamed.md")
            ]
        );
        assert_eq!(plan.rescan_directories, vec![PathBuf::from("Folder")]);
    }

    #[test]
    fn ambiguous_events_require_full_rescan() {
        let events = vec![event(
            "Folder/Note.md",
            WatcherEventKind::Ambiguous,
            WATCHER_FLAG_KERNEL_DROPPED,
        )];

        let plan = coalesce_watcher_burst(&events);

        assert_eq!(plan.state, WatcherBurstState::Ambiguous);
        assert!(plan.requires_full_rescan);
        assert_eq!(plan.rescan_directories, vec![PathBuf::new()]);
    }

    #[test]
    fn dropped_events_without_path_require_root_rescan() {
        let events = vec![WatcherEvent {
            relative_path: None,
            kind: WatcherEventKind::Ambiguous,
            flags: WATCHER_FLAG_KERNEL_DROPPED,
            event_id: None,
            requires_full_rescan: true,
        }];

        let plan = coalesce_watcher_burst(&events);

        assert_eq!(plan.state, WatcherBurstState::Ambiguous);
        assert!(plan.requires_full_rescan);
        assert!(plan.changed_paths.is_empty());
        assert_eq!(plan.rescan_directories, vec![PathBuf::new()]);
    }

    #[test]
    fn recovers_synthetic_bursts_without_old_generation_queue_rows() {
        for count in [100_usize, 1_000, 10_000] {
            let previous_scan = synthetic_scan(count, 1, 100);
            let mut store = metadata_store();
            store_search_indexed_records(&mut store, &previous_scan, 1);
            let current_scan = synthetic_scan(count, 2, 101);
            let events = synthetic_events(count);
            let mut queue = IndexingQueue::open_in_memory().expect("queue");
            seed_old_generation_queue(&mut queue, &previous_scan, 1);

            let recovery = recover_watcher_burst(&store, &mut queue, &current_scan, 2, &events)
                .expect("recover");

            assert_eq!(recovery.plan.state, WatcherBurstState::Stale);
            assert_eq!(recovery.index_state, WatcherBurstState::Stale);
            assert_eq!(recovery.reconciliation.modified, count);
            assert_eq!(recovery.reconciliation.enqueued, count);
            assert_eq!(queue.summary().expect("summary").pending, count);

            let leased = queue.lease_batch(count).expect("lease");
            assert_eq!(leased.len(), count);
            assert!(leased.iter().all(|item| item.generation == 2));
            assert!(
                leased
                    .iter()
                    .all(|item| item.status == IndexingQueueStatus::InProgress)
            );
            assert!(
                leased
                    .iter()
                    .all(|item| item.reason == IndexingQueueReason::FileChanged)
            );
        }
    }

    fn metadata_store() -> MetadataStore {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        MetadataStore::open_in_memory(&metadata).expect("store")
    }

    fn store_search_indexed_records(
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

    fn seed_old_generation_queue(queue: &mut IndexingQueue, scan: &ScanSummary, generation: u64) {
        for entry in &scan.entries {
            let file = FileRecord::from_scan_entry(entry, generation);
            queue
                .enqueue_file(&file, IndexingQueueReason::InitialScan)
                .expect("seed old queue item");
        }
    }

    fn synthetic_scan(count: usize, generation_seed: u64, size_bytes: u64) -> ScanSummary {
        let entries = (0..count)
            .map(|index| ScanEntry {
                relative_path: PathBuf::from(format!("Folder/Note-{index:05}.md")),
                kind: ScanEntryKind::Markdown,
                size_bytes,
                modified: Some(UNIX_EPOCH + Duration::from_secs(generation_seed)),
                file_identity: FileIdentity {
                    device: 1,
                    inode: index as u64 + 10,
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

    fn synthetic_events(count: usize) -> Vec<WatcherEvent> {
        (0..count)
            .map(|index| {
                event(
                    format!("Folder/Note-{index:05}.md"),
                    WatcherEventKind::Modified,
                    WATCHER_FLAG_ITEM_MODIFIED,
                )
            })
            .collect()
    }

    fn event(path: impl Into<PathBuf>, kind: WatcherEventKind, flags: u32) -> WatcherEvent {
        WatcherEvent {
            relative_path: Some(path.into()),
            kind,
            flags,
            event_id: None,
            requires_full_rescan: flags == WATCHER_FLAG_KERNEL_DROPPED,
        }
    }
}
