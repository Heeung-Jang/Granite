use std::{fmt, path::PathBuf, time::SystemTime};

use crate::adapters::fs::note_writer::capture_snapshot;
use crate::adapters::sqlite::{IndexingQueue, IndexingQueueError, IndexingQueueItem};
use crate::paths::{FileIdentity, PathError, VaultRoot};
use crate::save::{
    keep_conflicted_buffer_as_new_note_impl, overwrite_after_conflict_impl,
    reload_after_conflict_impl, safe_save_and_enqueue_own_save_impl, safe_save_impl,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveBaseline {
    pub relative_path: String,
    pub file_identity: FileIdentity,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub content_hash: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveRequest<'a> {
    pub baseline: &'a SaveBaseline,
    pub contents: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveOutcome {
    pub baseline: SaveBaseline,
    pub bytes_written: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueuedSaveOutcome {
    pub baseline: SaveBaseline,
    pub bytes_written: u64,
    pub queued_item: IndexingQueueItem,
    pub dirty: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveReloadOutcome {
    pub baseline: SaveBaseline,
    pub contents: Vec<u8>,
    pub queued_item: IndexingQueueItem,
    pub dirty: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveChoiceOutcome {
    pub choice: SaveConflictChoice,
    pub baseline: SaveBaseline,
    pub bytes_written: u64,
    pub queued_item: IndexingQueueItem,
    pub dirty: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveConflict {
    pub relative_path: String,
    pub kind: SaveConflictKind,
    pub expected: SaveBaseline,
    pub actual: Option<SaveConflictSnapshot>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SaveConflictSnapshot {
    pub file_identity: FileIdentity,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub content_hash: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveConflictKind {
    Deleted,
    FileIdentityChanged,
    ContentChanged,
    MetadataChanged,
    SymlinkChanged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveConflictChoice {
    KeepAsNewNote,
    Overwrite,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SaveIoOperation {
    CreateTemp,
    WriteTemp,
    SetTempPermissions,
    SyncTemp,
    RenameTemp,
    SyncParent,
    ReadFile,
    ReadMetadata,
    CreateNewNote,
    LinkNewNote,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SafeSaveError {
    Path(PathError),
    Conflict(Box<SaveConflict>),
    ReadOnly {
        relative_path: String,
    },
    NotRegularFile {
        relative_path: String,
    },
    Io {
        operation: SaveIoOperation,
        path: PathBuf,
        kind: std::io::ErrorKind,
    },
}

pub type SafeSaveResult<T> = Result<T, SafeSaveError>;

#[derive(Debug)]
pub enum SaveConflictChoiceError {
    Save(SafeSaveError),
    Queue(IndexingQueueError),
}

pub type SaveConflictChoiceResult<T> = Result<T, SaveConflictChoiceError>;

impl SaveBaseline {
    pub fn capture(root: &VaultRoot, relative_path: &str) -> SafeSaveResult<Self> {
        Ok(capture_snapshot(root, relative_path)?.baseline)
    }
}

impl<'a> SaveRequest<'a> {
    pub fn new(baseline: &'a SaveBaseline, contents: &'a [u8]) -> Self {
        Self { baseline, contents }
    }
}

pub fn safe_save(root: &VaultRoot, request: SaveRequest<'_>) -> SafeSaveResult<SaveOutcome> {
    safe_save_impl(root, request)
}

pub fn safe_save_and_enqueue_own_save(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    request: SaveRequest<'_>,
    generation: u64,
) -> SaveConflictChoiceResult<QueuedSaveOutcome> {
    safe_save_and_enqueue_own_save_impl(root, queue, request, generation)
}

pub fn reload_after_conflict(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    conflict: &SaveConflict,
    generation: u64,
) -> SaveConflictChoiceResult<SaveReloadOutcome> {
    reload_after_conflict_impl(root, queue, conflict, generation)
}

pub fn keep_conflicted_buffer_as_new_note(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    relative_path: &str,
    contents: &[u8],
    generation: u64,
) -> SaveConflictChoiceResult<SaveChoiceOutcome> {
    keep_conflicted_buffer_as_new_note_impl(root, queue, relative_path, contents, generation)
}

pub fn overwrite_after_conflict(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    conflict: &SaveConflict,
    contents: &[u8],
    generation: u64,
) -> SaveConflictChoiceResult<SaveChoiceOutcome> {
    overwrite_after_conflict_impl(root, queue, conflict, contents, generation)
}

impl From<&SaveBaseline> for SaveConflictSnapshot {
    fn from(baseline: &SaveBaseline) -> Self {
        Self {
            file_identity: baseline.file_identity.clone(),
            size_bytes: baseline.size_bytes,
            modified: baseline.modified,
            content_hash: baseline.content_hash.clone(),
        }
    }
}

impl fmt::Display for SafeSaveError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Path(error) => write!(formatter, "safe save path error: {error}"),
            Self::Conflict(conflict) => write!(
                formatter,
                "safe save conflict for {}: {:?}",
                conflict.relative_path, conflict.kind
            ),
            Self::ReadOnly { relative_path } => {
                write!(formatter, "safe save target is read-only: {relative_path}")
            }
            Self::NotRegularFile { relative_path } => {
                write!(
                    formatter,
                    "safe save target is not a regular file: {relative_path}"
                )
            }
            Self::Io {
                operation,
                path,
                kind,
            } => write!(
                formatter,
                "safe save io error during {:?} at {}: {:?}",
                operation,
                path.display(),
                kind
            ),
        }
    }
}

impl std::error::Error for SafeSaveError {}

impl fmt::Display for SaveConflictChoiceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Save(error) => write!(formatter, "save conflict choice error: {error}"),
            Self::Queue(error) => write!(formatter, "save conflict queue error: {error}"),
        }
    }
}

impl std::error::Error for SaveConflictChoiceError {}

impl From<SafeSaveError> for SaveConflictChoiceError {
    fn from(error: SafeSaveError) -> Self {
        Self::Save(error)
    }
}

impl From<IndexingQueueError> for SaveConflictChoiceError {
    fn from(error: IndexingQueueError) -> Self {
        Self::Queue(error)
    }
}
