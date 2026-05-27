use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

use crate::adapters::sqlite::MAX_INDEX_ERROR_CHARS;
pub use crate::indexing_queue::*;
use crate::scanner::ScanEntryKind;

pub(crate) fn create_schema(connection: &Connection) -> IndexingQueueResult<()> {
    connection.execute_batch(
        "
        CREATE TABLE IF NOT EXISTS indexing_queue (
            item_id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL UNIQUE,
            relative_path TEXT NOT NULL,
            kind TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            modified_unix_ms INTEGER,
            generation INTEGER NOT NULL,
            reason TEXT NOT NULL,
            status TEXT NOT NULL,
            attempts INTEGER NOT NULL,
            last_error TEXT,
            leased_unix_ms INTEGER,
            updated_unix_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_indexing_queue_status_generation
            ON indexing_queue(status, generation, updated_unix_ms, item_id);
        ",
    )?;
    Ok(())
}

pub(crate) fn item_select_sql(where_clause: &str) -> String {
    format!(
        "SELECT item_id, file_id, relative_path, kind, size_bytes, modified_unix_ms, generation,
                reason, status, attempts, last_error, leased_unix_ms, updated_unix_ms
         FROM indexing_queue {where_clause}"
    )
}

pub(crate) fn row_to_queue_item(row: &rusqlite::Row<'_>) -> rusqlite::Result<IndexingQueueItem> {
    let kind: String = row.get(3)?;
    let reason: String = row.get(7)?;
    let status: String = row.get(8)?;

    Ok(IndexingQueueItem {
        item_id: row.get(0)?,
        file_id: row.get(1)?,
        relative_path: PathBuf::from(row.get::<_, String>(2)?),
        kind: scan_kind_from_str(&kind).map_err(|_| rusqlite::Error::InvalidQuery)?,
        size_bytes: row.get::<_, i64>(4)? as u64,
        modified: unix_ms_to_system_time(row.get(5)?),
        generation: row.get::<_, i64>(6)? as u64,
        reason: queue_reason_from_str(&reason).map_err(|_| rusqlite::Error::InvalidQuery)?,
        status: queue_status_from_str(&status).map_err(|_| rusqlite::Error::InvalidQuery)?,
        attempts: row.get::<_, i64>(9)? as u32,
        last_error: row.get(10)?,
        leased_at: unix_ms_to_system_time(row.get(11)?),
        updated_at: unix_ms_to_system_time(row.get(12)?).ok_or(rusqlite::Error::InvalidQuery)?,
    })
}

pub(crate) fn path_to_string(path: &Path) -> String {
    path.components()
        .filter_map(|component| match component {
            std::path::Component::Normal(value) => Some(value.to_string_lossy()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

pub(crate) fn system_time_to_unix_ms(time: Option<SystemTime>) -> Option<i64> {
    time.and_then(|value| {
        value
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_millis() as i64)
    })
}

pub(crate) fn unix_ms_to_system_time(value: Option<i64>) -> Option<SystemTime> {
    value.map(|millis| UNIX_EPOCH + Duration::from_millis(millis as u64))
}

pub(crate) fn truncate_queue_error(error: &str) -> String {
    let trimmed = error.trim();
    if trimmed.chars().count() <= MAX_INDEX_ERROR_CHARS {
        return trimmed.to_string();
    }

    trimmed.chars().take(MAX_INDEX_ERROR_CHARS).collect()
}

pub(crate) fn scan_kind_to_str(kind: ScanEntryKind) -> &'static str {
    match kind {
        ScanEntryKind::Markdown => "markdown",
        ScanEntryKind::Attachment => "attachment",
        ScanEntryKind::Other => "other",
    }
}

pub(crate) fn scan_kind_from_str(kind: &str) -> Result<ScanEntryKind, ()> {
    match kind {
        "markdown" => Ok(ScanEntryKind::Markdown),
        "attachment" => Ok(ScanEntryKind::Attachment),
        "other" => Ok(ScanEntryKind::Other),
        _ => Err(()),
    }
}

pub(crate) fn queue_reason_to_str(reason: IndexingQueueReason) -> &'static str {
    match reason {
        IndexingQueueReason::InitialScan => "initial_scan",
        IndexingQueueReason::FileCreated => "file_created",
        IndexingQueueReason::FileChanged => "file_changed",
        IndexingQueueReason::FileDeleted => "file_deleted",
        IndexingQueueReason::Rebuild => "rebuild",
        IndexingQueueReason::OwnSave => "own_save",
    }
}

pub(crate) fn queue_reason_from_str(reason: &str) -> Result<IndexingQueueReason, ()> {
    match reason {
        "initial_scan" => Ok(IndexingQueueReason::InitialScan),
        "file_created" => Ok(IndexingQueueReason::FileCreated),
        "file_changed" => Ok(IndexingQueueReason::FileChanged),
        "file_deleted" => Ok(IndexingQueueReason::FileDeleted),
        "rebuild" => Ok(IndexingQueueReason::Rebuild),
        "own_save" => Ok(IndexingQueueReason::OwnSave),
        _ => Err(()),
    }
}

pub(crate) fn queue_status_to_str(status: IndexingQueueStatus) -> &'static str {
    match status {
        IndexingQueueStatus::Pending => "pending",
        IndexingQueueStatus::InProgress => "in_progress",
        IndexingQueueStatus::Completed => "completed",
        IndexingQueueStatus::Failed => "failed",
        IndexingQueueStatus::Cancelled => "cancelled",
    }
}

pub(crate) fn queue_status_from_str(status: &str) -> Result<IndexingQueueStatus, ()> {
    match status {
        "pending" => Ok(IndexingQueueStatus::Pending),
        "in_progress" => Ok(IndexingQueueStatus::InProgress),
        "completed" => Ok(IndexingQueueStatus::Completed),
        "failed" => Ok(IndexingQueueStatus::Failed),
        "cancelled" => Ok(IndexingQueueStatus::Cancelled),
        _ => Err(()),
    }
}
