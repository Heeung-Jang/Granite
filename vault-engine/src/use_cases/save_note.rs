use std::{fmt, path::PathBuf, time::SystemTime};

use std::path::Path;

use crate::adapters::fs::note_writer::{
    FileSnapshot, capture_snapshot, read_snapshot_contents, rename_temp_file, sync_parent,
    write_new_note, write_temp_file,
};
use crate::adapters::sqlite::{
    FileRecord, IndexingQueue, IndexingQueueError, IndexingQueueItem, IndexingQueueReason,
};
use crate::core::scan::{ScanEntry, classify_file};
use crate::paths::{FileIdentity, PathError, VaultRoot};

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
    let current = current_snapshot(root, request.baseline)?;
    ensure_baseline_matches(request.baseline, &current)?;

    if current.readonly {
        return Err(SafeSaveError::ReadOnly {
            relative_path: request.baseline.relative_path.clone(),
        });
    }

    let temp_path = write_temp_file(&current, request.contents)?;
    let display_path = Path::new(&current.baseline.relative_path);
    rename_temp_file(&temp_path, &current.absolute_path, display_path)?;
    sync_parent(&current.absolute_path, display_path)?;

    let baseline = SaveBaseline::capture(root, &request.baseline.relative_path)?;
    Ok(SaveOutcome {
        baseline,
        bytes_written: request.contents.len() as u64,
    })
}

pub fn safe_save_and_enqueue_own_save(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    request: SaveRequest<'_>,
    generation: u64,
) -> SaveConflictChoiceResult<QueuedSaveOutcome> {
    let outcome = safe_save(root, request)?;
    let queued_item = enqueue_saved_file(
        queue,
        &outcome.baseline,
        generation,
        IndexingQueueReason::OwnSave,
    )?;

    Ok(QueuedSaveOutcome {
        baseline: outcome.baseline,
        bytes_written: outcome.bytes_written,
        queued_item,
        dirty: false,
    })
}

pub fn reload_after_conflict(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    conflict: &SaveConflict,
    generation: u64,
) -> SaveConflictChoiceResult<SaveReloadOutcome> {
    let current = current_snapshot(root, &conflict.expected)?;
    let contents = read_snapshot_contents(&current)?;
    let queued_item = enqueue_saved_file(
        queue,
        &current.baseline,
        generation,
        IndexingQueueReason::FileChanged,
    )?;

    Ok(SaveReloadOutcome {
        baseline: current.baseline,
        contents,
        queued_item,
        dirty: false,
    })
}

pub fn keep_conflicted_buffer_as_new_note(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    relative_path: &str,
    contents: &[u8],
    generation: u64,
) -> SaveConflictChoiceResult<SaveChoiceOutcome> {
    write_new_note(root, relative_path, contents)?;
    let baseline = SaveBaseline::capture(root, relative_path)?;
    let queued_item =
        enqueue_saved_file(queue, &baseline, generation, IndexingQueueReason::OwnSave)?;

    Ok(SaveChoiceOutcome {
        choice: SaveConflictChoice::KeepAsNewNote,
        bytes_written: contents.len() as u64,
        baseline,
        queued_item,
        dirty: false,
    })
}

pub fn overwrite_after_conflict(
    root: &VaultRoot,
    queue: &mut IndexingQueue,
    conflict: &SaveConflict,
    contents: &[u8],
    generation: u64,
) -> SaveConflictChoiceResult<SaveChoiceOutcome> {
    let current = current_snapshot(root, &conflict.expected)?;
    if current.readonly {
        return Err(SafeSaveError::ReadOnly {
            relative_path: conflict.relative_path.clone(),
        }
        .into());
    }

    let temp_path = write_temp_file(&current, contents)?;
    let display_path = Path::new(&current.baseline.relative_path);
    rename_temp_file(&temp_path, &current.absolute_path, display_path)?;
    sync_parent(&current.absolute_path, display_path)?;

    let baseline = SaveBaseline::capture(root, &current.baseline.relative_path)?;
    let queued_item =
        enqueue_saved_file(queue, &baseline, generation, IndexingQueueReason::OwnSave)?;

    Ok(SaveChoiceOutcome {
        choice: SaveConflictChoice::Overwrite,
        baseline,
        bytes_written: contents.len() as u64,
        queued_item,
        dirty: false,
    })
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

pub(crate) fn current_snapshot(
    root: &VaultRoot,
    expected: &SaveBaseline,
) -> SafeSaveResult<FileSnapshot> {
    match capture_snapshot(root, &expected.relative_path) {
        Ok(snapshot) => Ok(snapshot),
        Err(SafeSaveError::Path(PathError::MissingPath(_))) => {
            Err(conflict(expected, SaveConflictKind::Deleted, None))
        }
        Err(SafeSaveError::Path(PathError::SymlinkEscape { .. }))
        | Err(SafeSaveError::NotRegularFile { .. }) => {
            Err(conflict(expected, SaveConflictKind::SymlinkChanged, None))
        }
        Err(error) => Err(error),
    }
}

fn ensure_baseline_matches(expected: &SaveBaseline, current: &FileSnapshot) -> SafeSaveResult<()> {
    let actual = SaveConflictSnapshot::from(&current.baseline);

    if expected.file_identity != current.baseline.file_identity {
        return Err(conflict(
            expected,
            SaveConflictKind::FileIdentityChanged,
            Some(actual),
        ));
    }

    if expected.content_hash != current.baseline.content_hash {
        return Err(conflict(
            expected,
            SaveConflictKind::ContentChanged,
            Some(actual),
        ));
    }

    if expected.size_bytes != current.baseline.size_bytes
        || expected.modified != current.baseline.modified
    {
        return Err(conflict(
            expected,
            SaveConflictKind::MetadataChanged,
            Some(actual),
        ));
    }

    Ok(())
}

fn conflict(
    expected: &SaveBaseline,
    kind: SaveConflictKind,
    actual: Option<SaveConflictSnapshot>,
) -> SafeSaveError {
    SafeSaveError::Conflict(Box::new(SaveConflict {
        relative_path: expected.relative_path.clone(),
        kind,
        expected: expected.clone(),
        actual,
    }))
}

pub(crate) fn enqueue_saved_file(
    queue: &mut IndexingQueue,
    baseline: &SaveBaseline,
    generation: u64,
    reason: IndexingQueueReason,
) -> Result<IndexingQueueItem, IndexingQueueError> {
    let entry = ScanEntry {
        relative_path: PathBuf::from(&baseline.relative_path),
        kind: classify_file(Path::new(&baseline.relative_path)),
        size_bytes: baseline.size_bytes,
        modified: baseline.modified,
        file_identity: baseline.file_identity.clone(),
    };
    let file = FileRecord::from_scan_entry(&entry, generation);
    queue.enqueue_file(&file, reason)
}
