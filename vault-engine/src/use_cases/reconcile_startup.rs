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
