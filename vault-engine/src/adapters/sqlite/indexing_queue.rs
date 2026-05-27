use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, params};

use crate::adapters::sqlite::{FileRecord, MAX_INDEX_ERROR_CHARS};
use crate::scanner::ScanEntryKind;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexingQueueItem {
    pub item_id: i64,
    pub file_id: String,
    pub relative_path: PathBuf,
    pub kind: ScanEntryKind,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub generation: u64,
    pub reason: IndexingQueueReason,
    pub status: IndexingQueueStatus,
    pub attempts: u32,
    pub last_error: Option<String>,
    pub leased_at: Option<SystemTime>,
    pub updated_at: SystemTime,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexingQueueReason {
    InitialScan,
    FileCreated,
    FileChanged,
    FileDeleted,
    Rebuild,
    OwnSave,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexingQueueStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct IndexingQueueSummary {
    pub pending: usize,
    pub in_progress: usize,
    pub completed: usize,
    pub failed: usize,
    pub cancelled: usize,
}

pub struct IndexingQueue {
    connection: Connection,
}

#[derive(Debug)]
pub enum IndexingQueueError {
    Sqlite(rusqlite::Error),
    InvalidStoredValue(&'static str),
}

pub type IndexingQueueResult<T> = Result<T, IndexingQueueError>;

impl IndexingQueue {
    pub fn open(path: impl AsRef<Path>) -> IndexingQueueResult<Self> {
        Self::from_connection(Connection::open(path)?)
    }

    pub fn open_in_memory() -> IndexingQueueResult<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> IndexingQueueResult<Self> {
        create_schema(&connection)?;
        Ok(Self { connection })
    }

    pub fn enqueue_file(
        &mut self,
        file: &FileRecord,
        reason: IndexingQueueReason,
    ) -> IndexingQueueResult<IndexingQueueItem> {
        let now = system_time_to_unix_ms(Some(SystemTime::now()));
        self.connection.execute(
            "INSERT INTO indexing_queue (
                file_id, relative_path, kind, size_bytes, modified_unix_ms, generation, reason,
                status, attempts, last_error, leased_unix_ms, updated_unix_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'pending', 0, NULL, NULL, ?8)
            ON CONFLICT(file_id) DO UPDATE SET
                relative_path = excluded.relative_path,
                kind = excluded.kind,
                size_bytes = excluded.size_bytes,
                modified_unix_ms = excluded.modified_unix_ms,
                generation = excluded.generation,
                reason = excluded.reason,
                status = 'pending',
                attempts = 0,
                last_error = NULL,
                leased_unix_ms = NULL,
                updated_unix_ms = excluded.updated_unix_ms
            WHERE excluded.generation > indexing_queue.generation
               OR (
                   excluded.generation = indexing_queue.generation
                   AND NOT (
                       indexing_queue.reason = 'own_save'
                       AND excluded.reason = 'file_changed'
                   )
               )",
            params![
                &file.file_id,
                path_to_string(&file.relative_path),
                scan_kind_to_str(file.kind),
                file.size_bytes as i64,
                system_time_to_unix_ms(file.modified),
                file.generation as i64,
                queue_reason_to_str(reason),
                now,
            ],
        )?;
        self.get_by_file_id(&file.file_id)?
            .ok_or(IndexingQueueError::InvalidStoredValue(
                "indexing_queue.file_id",
            ))
    }

    pub fn lease_batch(&mut self, limit: usize) -> IndexingQueueResult<Vec<IndexingQueueItem>> {
        if limit == 0 {
            return Ok(Vec::new());
        }

        let transaction = self.connection.transaction()?;
        let item_ids = {
            let mut statement = transaction.prepare(
                "SELECT item_id FROM indexing_queue
                 WHERE status = 'pending'
                 ORDER BY generation, updated_unix_ms, item_id
                 LIMIT ?1",
            )?;
            let rows = statement.query_map(params![limit as i64], |row| row.get::<_, i64>(0))?;
            rows.collect::<Result<Vec<_>, _>>()?
        };

        let now = system_time_to_unix_ms(Some(SystemTime::now()));
        for item_id in &item_ids {
            transaction.execute(
                "UPDATE indexing_queue
                 SET status = 'in_progress', leased_unix_ms = ?1, updated_unix_ms = ?1
                 WHERE item_id = ?2",
                params![now, item_id],
            )?;
        }
        transaction.commit()?;

        let mut leased = Vec::with_capacity(item_ids.len());
        for item_id in item_ids {
            if let Some(item) = self.get(item_id)? {
                leased.push(item);
            }
        }
        Ok(leased)
    }

    pub fn complete(&mut self, item_id: i64) -> IndexingQueueResult<()> {
        self.update_terminal_status(item_id, IndexingQueueStatus::Completed, None)
    }

    pub fn record_failure(
        &mut self,
        item_id: i64,
        error: impl AsRef<str>,
        max_attempts: u32,
    ) -> IndexingQueueResult<IndexingQueueItem> {
        let now = system_time_to_unix_ms(Some(SystemTime::now()));
        let current_attempts = self
            .get(item_id)?
            .ok_or(IndexingQueueError::InvalidStoredValue(
                "indexing_queue.item_id",
            ))?
            .attempts;
        let attempts = current_attempts.saturating_add(1);
        let status = if attempts >= max_attempts.max(1) {
            IndexingQueueStatus::Failed
        } else {
            IndexingQueueStatus::Pending
        };

        self.connection.execute(
            "UPDATE indexing_queue
             SET status = ?1, attempts = ?2, last_error = ?3,
                 leased_unix_ms = NULL, updated_unix_ms = ?4
             WHERE item_id = ?5",
            params![
                queue_status_to_str(status),
                attempts as i64,
                truncate_queue_error(error.as_ref()),
                now,
                item_id,
            ],
        )?;

        self.get(item_id)?
            .ok_or(IndexingQueueError::InvalidStoredValue(
                "indexing_queue.item_id",
            ))
    }

    pub fn cancel_generation(&mut self, generation: u64) -> IndexingQueueResult<usize> {
        let now = system_time_to_unix_ms(Some(SystemTime::now()));
        let updated = self.connection.execute(
            "UPDATE indexing_queue
             SET status = 'cancelled', leased_unix_ms = NULL, updated_unix_ms = ?1
             WHERE generation = ?2 AND status IN ('pending', 'in_progress')",
            params![now, generation as i64],
        )?;
        Ok(updated)
    }

    pub fn recover_interrupted(&mut self) -> IndexingQueueResult<usize> {
        let now = system_time_to_unix_ms(Some(SystemTime::now()));
        let updated = self.connection.execute(
            "UPDATE indexing_queue
             SET status = 'pending', leased_unix_ms = NULL, updated_unix_ms = ?1
             WHERE status = 'in_progress'",
            params![now],
        )?;
        Ok(updated)
    }

    pub fn summary(&self) -> IndexingQueueResult<IndexingQueueSummary> {
        let mut statement = self
            .connection
            .prepare("SELECT status, COUNT(*) FROM indexing_queue GROUP BY status")?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)? as usize))
        })?;

        let mut summary = IndexingQueueSummary::default();
        for row in rows {
            let (status, count) = row?;
            match queue_status_from_str(&status)
                .map_err(|_| IndexingQueueError::InvalidStoredValue("indexing_queue.status"))?
            {
                IndexingQueueStatus::Pending => summary.pending = count,
                IndexingQueueStatus::InProgress => summary.in_progress = count,
                IndexingQueueStatus::Completed => summary.completed = count,
                IndexingQueueStatus::Failed => summary.failed = count,
                IndexingQueueStatus::Cancelled => summary.cancelled = count,
            }
        }
        Ok(summary)
    }

    pub fn get(&self, item_id: i64) -> IndexingQueueResult<Option<IndexingQueueItem>> {
        self.connection
            .query_row(
                item_select_sql("WHERE item_id = ?1").as_str(),
                params![item_id],
                row_to_queue_item,
            )
            .optional()
            .map_err(Into::into)
    }

    pub fn get_by_file_id(&self, file_id: &str) -> IndexingQueueResult<Option<IndexingQueueItem>> {
        self.connection
            .query_row(
                item_select_sql("WHERE file_id = ?1").as_str(),
                params![file_id],
                row_to_queue_item,
            )
            .optional()
            .map_err(Into::into)
    }

    fn update_terminal_status(
        &mut self,
        item_id: i64,
        status: IndexingQueueStatus,
        error: Option<&str>,
    ) -> IndexingQueueResult<()> {
        let now = system_time_to_unix_ms(Some(SystemTime::now()));
        self.connection.execute(
            "UPDATE indexing_queue
             SET status = ?1, last_error = ?2, leased_unix_ms = NULL, updated_unix_ms = ?3
             WHERE item_id = ?4",
            params![queue_status_to_str(status), error, now, item_id],
        )?;
        Ok(())
    }
}

impl fmt::Display for IndexingQueueError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(error) => write!(formatter, "indexing queue sqlite error: {error}"),
            Self::InvalidStoredValue(field) => {
                write!(formatter, "invalid indexing queue value for {field}")
            }
        }
    }
}

impl std::error::Error for IndexingQueueError {}

impl From<rusqlite::Error> for IndexingQueueError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

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
