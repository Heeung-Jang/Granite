use std::collections::BTreeSet;
use std::fmt;
use std::path::PathBuf;

use crate::adapters::fs::watcher::{
    WATCHER_FLAG_EVENT_IDS_WRAPPED, WATCHER_FLAG_KERNEL_DROPPED, WATCHER_FLAG_MUST_SCAN_SUBDIRS,
    WATCHER_FLAG_USER_DROPPED, WatcherEvent, WatcherEventKind,
};
use crate::adapters::sqlite::MetadataStore;
use crate::adapters::sqlite::{IndexingQueue, IndexingQueueError};
use crate::core::scan::ScanSummary;
use crate::use_cases::reconcile_startup::{
    StartupReconciliationError, StartupReconciliationSummary, reconcile_startup,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatcherBurstPlan {
    pub state: WatcherBurstState,
    pub event_count: usize,
    pub changed_paths: Vec<PathBuf>,
    pub rescan_directories: Vec<PathBuf>,
    pub requires_full_rescan: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatcherBurstState {
    Complete,
    Stale,
    Ambiguous,
}

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

pub fn coalesce_watcher_burst(events: &[WatcherEvent]) -> WatcherBurstPlan {
    let mut changed_paths = BTreeSet::new();
    let mut rescan_directories = BTreeSet::new();
    let mut requires_full_rescan = false;

    for event in events {
        if event_requires_root_rescan(event) {
            requires_full_rescan = true;
            rescan_directories.insert(PathBuf::new());
            if let Some(path) = &event.relative_path {
                changed_paths.insert(path.clone());
            }
            continue;
        }

        let Some(path) = &event.relative_path else {
            requires_full_rescan = true;
            rescan_directories.insert(PathBuf::new());
            continue;
        };

        match event.kind {
            WatcherEventKind::Created | WatcherEventKind::Modified | WatcherEventKind::Removed => {
                changed_paths.insert(path.clone());
            }
            WatcherEventKind::Renamed | WatcherEventKind::Unknown => {
                changed_paths.insert(path.clone());
                rescan_directories.insert(parent_directory(path));
            }
            WatcherEventKind::Ambiguous | WatcherEventKind::RootChanged => {
                changed_paths.insert(path.clone());
                requires_full_rescan = true;
                rescan_directories.insert(PathBuf::new());
            }
        }
    }

    WatcherBurstPlan {
        state: if requires_full_rescan {
            WatcherBurstState::Ambiguous
        } else if events.is_empty() {
            WatcherBurstState::Complete
        } else {
            WatcherBurstState::Stale
        },
        event_count: events.len(),
        changed_paths: changed_paths.into_iter().collect(),
        rescan_directories: rescan_directories.into_iter().collect(),
        requires_full_rescan,
    }
}

fn event_requires_root_rescan(event: &WatcherEvent) -> bool {
    event.requires_full_rescan
        || event.relative_path.is_none()
        || event.kind == WatcherEventKind::Ambiguous
        || event.kind == WatcherEventKind::RootChanged
        || event.flags
            & (WATCHER_FLAG_MUST_SCAN_SUBDIRS
                | WATCHER_FLAG_USER_DROPPED
                | WATCHER_FLAG_KERNEL_DROPPED
                | WATCHER_FLAG_EVENT_IDS_WRAPPED)
            != 0
}

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

fn parent_directory(path: &std::path::Path) -> PathBuf {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .map(PathBuf::from)
        .unwrap_or_default()
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
