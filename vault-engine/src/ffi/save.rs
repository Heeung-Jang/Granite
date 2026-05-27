use std::os::raw::{c_char, c_uchar};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::core::files::FileIdentity;
use crate::use_cases::save_note::{
    SaveBaseline, SaveChoiceOutcome, SaveConflict, SaveConflictKind, SaveConflictSnapshot,
    SaveOutcome, SaveReloadOutcome, SaveRequest, capture_baseline_for_path,
    keep_conflicted_buffer_as_new_note_for_paths, overwrite_after_conflict_for_paths,
    reload_after_conflict_for_paths, safe_save_for_path,
};

use super::json::{FfiError, ffi_response, read_json};
use super::strings::{read_bytes, read_c_string};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_capture_baseline(
    vault_path: *const c_char,
    relative_path: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let relative_path = unsafe { read_c_string(relative_path, "relative_path") }?;
        let baseline =
            capture_baseline_for_path(&vault_path, &relative_path).map_err(FfiError::from_save)?;
        Ok(FfiSaveBaseline::from(&baseline))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_write(
    vault_path: *const c_char,
    baseline_json: *const c_char,
    contents: *const c_uchar,
    contents_len: usize,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let baseline_json = unsafe { read_c_string(baseline_json, "baseline_json") }?;
        let contents = unsafe { read_bytes(contents, contents_len, "contents") }?;
        let baseline: FfiSaveBaseline = read_json(&baseline_json, "baseline_json")?;
        let baseline = SaveBaseline::from(baseline);
        let outcome = safe_save_for_path(&vault_path, SaveRequest::new(&baseline, contents))
            .map_err(FfiError::from_save)?;
        Ok(FfiSaveOutcome::from(&outcome))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_reload_after_conflict(
    vault_path: *const c_char,
    queue_path: *const c_char,
    conflict_json: *const c_char,
    generation: u64,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let queue_path = unsafe { read_c_string(queue_path, "queue_path") }?;
        let conflict_json = unsafe { read_c_string(conflict_json, "conflict_json") }?;
        let conflict: FfiSaveConflict = read_json(&conflict_json, "conflict_json")?;
        let conflict = SaveConflict::try_from(conflict)?;
        let outcome =
            reload_after_conflict_for_paths(&vault_path, &queue_path, &conflict, generation)
                .map_err(FfiError::from_choice)?;
        FfiSaveReloadOutcome::try_from(&outcome)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_keep_conflict_as_new_note(
    vault_path: *const c_char,
    queue_path: *const c_char,
    new_relative_path: *const c_char,
    contents: *const c_uchar,
    contents_len: usize,
    generation: u64,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let queue_path = unsafe { read_c_string(queue_path, "queue_path") }?;
        let new_relative_path = unsafe { read_c_string(new_relative_path, "new_relative_path") }?;
        let contents = unsafe { read_bytes(contents, contents_len, "contents") }?;
        let outcome = keep_conflicted_buffer_as_new_note_for_paths(
            &vault_path,
            &queue_path,
            &new_relative_path,
            contents,
            generation,
        )
        .map_err(FfiError::from_choice)?;
        Ok(FfiSaveChoiceOutcome::from(&outcome))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_overwrite_after_conflict(
    vault_path: *const c_char,
    queue_path: *const c_char,
    conflict_json: *const c_char,
    contents: *const c_uchar,
    contents_len: usize,
    generation: u64,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let queue_path = unsafe { read_c_string(queue_path, "queue_path") }?;
        let conflict_json = unsafe { read_c_string(conflict_json, "conflict_json") }?;
        let contents = unsafe { read_bytes(contents, contents_len, "contents") }?;
        let conflict: FfiSaveConflict = read_json(&conflict_json, "conflict_json")?;
        let conflict = SaveConflict::try_from(conflict)?;
        let outcome = overwrite_after_conflict_for_paths(
            &vault_path,
            &queue_path,
            &conflict,
            contents,
            generation,
        )
        .map_err(FfiError::from_choice)?;
        Ok(FfiSaveChoiceOutcome::from(&outcome))
    })
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FfiFileIdentity {
    device: u64,
    inode: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FfiSystemTime {
    secs_since_unix_epoch: u64,
    nanos: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FfiSaveBaseline {
    relative_path: String,
    file_identity: FfiFileIdentity,
    size_bytes: u64,
    modified: Option<FfiSystemTime>,
    content_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FfiSaveConflictSnapshot {
    file_identity: FfiFileIdentity,
    size_bytes: u64,
    modified: Option<FfiSystemTime>,
    content_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct FfiSaveConflict {
    relative_path: String,
    kind: String,
    expected: FfiSaveBaseline,
    actual: Option<FfiSaveConflictSnapshot>,
}

#[derive(Debug, Clone, Serialize)]
struct FfiSaveOutcome {
    baseline: FfiSaveBaseline,
    bytes_written: u64,
}

#[derive(Debug, Clone, Serialize)]
struct FfiQueuedItem {
    relative_path: String,
    generation: u64,
    reason: String,
    status: String,
}

#[derive(Debug, Clone, Serialize)]
struct FfiSaveReloadOutcome {
    baseline: FfiSaveBaseline,
    contents: String,
    queued_item: FfiQueuedItem,
    dirty: bool,
}

#[derive(Debug, Clone, Serialize)]
struct FfiSaveChoiceOutcome {
    choice: String,
    baseline: FfiSaveBaseline,
    bytes_written: u64,
    queued_item: FfiQueuedItem,
    dirty: bool,
}

impl From<&FileIdentity> for FfiFileIdentity {
    fn from(identity: &FileIdentity) -> Self {
        Self {
            device: identity.device,
            inode: identity.inode,
        }
    }
}

impl From<FfiFileIdentity> for FileIdentity {
    fn from(identity: FfiFileIdentity) -> Self {
        Self {
            device: identity.device,
            inode: identity.inode,
        }
    }
}

impl From<&SaveBaseline> for FfiSaveBaseline {
    fn from(baseline: &SaveBaseline) -> Self {
        Self {
            relative_path: baseline.relative_path.clone(),
            file_identity: FfiFileIdentity::from(&baseline.file_identity),
            size_bytes: baseline.size_bytes,
            modified: baseline.modified.and_then(ffi_system_time),
            content_hash: baseline.content_hash.clone(),
        }
    }
}

impl From<FfiSaveBaseline> for SaveBaseline {
    fn from(baseline: FfiSaveBaseline) -> Self {
        Self {
            relative_path: baseline.relative_path,
            file_identity: FileIdentity::from(baseline.file_identity),
            size_bytes: baseline.size_bytes,
            modified: baseline.modified.map(system_time),
            content_hash: baseline.content_hash,
        }
    }
}

impl From<&SaveConflictSnapshot> for FfiSaveConflictSnapshot {
    fn from(snapshot: &SaveConflictSnapshot) -> Self {
        Self {
            file_identity: FfiFileIdentity::from(&snapshot.file_identity),
            size_bytes: snapshot.size_bytes,
            modified: snapshot.modified.and_then(ffi_system_time),
            content_hash: snapshot.content_hash.clone(),
        }
    }
}

impl From<FfiSaveConflictSnapshot> for SaveConflictSnapshot {
    fn from(snapshot: FfiSaveConflictSnapshot) -> Self {
        Self {
            file_identity: FileIdentity::from(snapshot.file_identity),
            size_bytes: snapshot.size_bytes,
            modified: snapshot.modified.map(system_time),
            content_hash: snapshot.content_hash,
        }
    }
}

impl From<&SaveConflict> for FfiSaveConflict {
    fn from(conflict: &SaveConflict) -> Self {
        Self {
            relative_path: conflict.relative_path.clone(),
            kind: format!("{:?}", conflict.kind),
            expected: FfiSaveBaseline::from(&conflict.expected),
            actual: conflict.actual.as_ref().map(FfiSaveConflictSnapshot::from),
        }
    }
}

impl TryFrom<FfiSaveConflict> for SaveConflict {
    type Error = FfiError;

    fn try_from(conflict: FfiSaveConflict) -> Result<Self, Self::Error> {
        Ok(Self {
            relative_path: conflict.relative_path,
            kind: save_conflict_kind_from_str(&conflict.kind)?,
            expected: SaveBaseline::from(conflict.expected),
            actual: conflict.actual.map(SaveConflictSnapshot::from),
        })
    }
}

impl From<&SaveOutcome> for FfiSaveOutcome {
    fn from(outcome: &SaveOutcome) -> Self {
        Self {
            baseline: FfiSaveBaseline::from(&outcome.baseline),
            bytes_written: outcome.bytes_written,
        }
    }
}

impl TryFrom<&SaveReloadOutcome> for FfiSaveReloadOutcome {
    type Error = FfiError;

    fn try_from(outcome: &SaveReloadOutcome) -> Result<Self, Self::Error> {
        let contents = String::from_utf8(outcome.contents.clone())
            .map_err(|error| FfiError::unsupported_encoding("contents", error.to_string()))?;
        Ok(Self {
            baseline: FfiSaveBaseline::from(&outcome.baseline),
            contents,
            queued_item: FfiQueuedItem {
                relative_path: outcome
                    .queued_item
                    .relative_path
                    .to_string_lossy()
                    .into_owned(),
                generation: outcome.queued_item.generation,
                reason: format!("{:?}", outcome.queued_item.reason),
                status: format!("{:?}", outcome.queued_item.status),
            },
            dirty: outcome.dirty,
        })
    }
}

impl From<&SaveChoiceOutcome> for FfiSaveChoiceOutcome {
    fn from(outcome: &SaveChoiceOutcome) -> Self {
        Self {
            choice: format!("{:?}", outcome.choice),
            baseline: FfiSaveBaseline::from(&outcome.baseline),
            bytes_written: outcome.bytes_written,
            queued_item: FfiQueuedItem {
                relative_path: outcome
                    .queued_item
                    .relative_path
                    .to_string_lossy()
                    .into_owned(),
                generation: outcome.queued_item.generation,
                reason: format!("{:?}", outcome.queued_item.reason),
                status: format!("{:?}", outcome.queued_item.status),
            },
            dirty: outcome.dirty,
        }
    }
}

fn save_conflict_kind_from_str(kind: &str) -> Result<SaveConflictKind, FfiError> {
    match kind {
        "Deleted" => Ok(SaveConflictKind::Deleted),
        "FileIdentityChanged" => Ok(SaveConflictKind::FileIdentityChanged),
        "ContentChanged" => Ok(SaveConflictKind::ContentChanged),
        "MetadataChanged" => Ok(SaveConflictKind::MetadataChanged),
        "SymlinkChanged" => Ok(SaveConflictKind::SymlinkChanged),
        _ => Err(FfiError::invalid_input(
            "conflict.kind",
            format!("unsupported save conflict kind: {kind}"),
        )),
    }
}

fn ffi_system_time(time: SystemTime) -> Option<FfiSystemTime> {
    let duration = time.duration_since(UNIX_EPOCH).ok()?;
    Some(FfiSystemTime {
        secs_since_unix_epoch: duration.as_secs(),
        nanos: duration.subsec_nanos(),
    })
}

fn system_time(time: FfiSystemTime) -> SystemTime {
    UNIX_EPOCH + Duration::new(time.secs_since_unix_epoch, time.nanos)
}
