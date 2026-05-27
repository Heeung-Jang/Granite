use std::collections::BTreeSet;
use std::path::PathBuf;

use crate::adapters::fs::watcher::{
    WATCHER_FLAG_EVENT_IDS_WRAPPED, WATCHER_FLAG_KERNEL_DROPPED, WATCHER_FLAG_MUST_SCAN_SUBDIRS,
    WATCHER_FLAG_USER_DROPPED, WatcherEvent, WatcherEventKind,
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

fn parent_directory(path: &std::path::Path) -> PathBuf {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .map(PathBuf::from)
        .unwrap_or_default()
}
