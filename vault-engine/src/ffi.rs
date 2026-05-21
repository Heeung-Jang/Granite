use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_uchar};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::ENGINE_ABI_VERSION;
use crate::indexing_queue::{IndexingQueue, IndexingQueueItem};
use crate::paths::{FileIdentity, PathError, VaultRoot};
use crate::read_api::{
    ENGINE_READ_STATE_COMPLETE, ReadOpenError, VaultReadApi, open_vault_read_api,
};
use crate::save::{
    SafeSaveError, SaveBaseline, SaveChoiceOutcome, SaveConflict, SaveConflictChoiceError,
    SaveConflictKind, SaveConflictSnapshot, SaveOutcome, SaveReloadOutcome, SaveRequest,
    keep_conflicted_buffer_as_new_note, overwrite_after_conflict, reload_after_conflict, safe_save,
};

pub fn abi_version() -> u32 {
    ENGINE_ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn engine_abi_version() -> u32 {
    ENGINE_ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn engine_health_check() -> *mut c_char {
    let message = format!("vault-engine:ok:abi={ENGINE_ABI_VERSION}");
    CString::new(message)
        .expect("engine health message must not contain nul bytes")
        .into_raw()
}

/// Frees strings returned by the vault engine FFI.
///
/// # Safety
///
/// `ptr` must be null or a pointer previously returned by this library through
/// `CString::into_raw`. Passing any other pointer is undefined behavior.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_string_free(ptr: *mut c_char) {
    if ptr.is_null() {
        return;
    }

    unsafe {
        drop(CString::from_raw(ptr));
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct EngineReadResultBuffer {
    pub ptr: *mut c_uchar,
    pub len: usize,
    pub capacity: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct EngineReadOpenResult {
    pub handle: *mut EngineReadHandle,
    pub result: EngineReadResultBuffer,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct EngineReadOpenStatus {
    abi_version: u32,
    ok: u32,
    state: u32,
    generation: u64,
    error_code: u32,
}

pub struct EngineReadHandle {
    api: VaultReadApi,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_open(
    metadata_path: *const c_char,
    tantivy_path: *const c_char,
) -> EngineReadOpenResult {
    read_open_response(|| {
        let metadata_path = unsafe {
            read_c_string(metadata_path, "metadata_path")
                .map_err(|_| ReadOpenError::InvalidInput("metadata_path"))?
        };
        let tantivy_path = unsafe {
            read_c_string(tantivy_path, "tantivy_path")
                .map_err(|_| ReadOpenError::InvalidInput("tantivy_path"))?
        };
        EngineReadHandle::open(metadata_path, tantivy_path)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_close(handle: *mut EngineReadHandle) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return;
        }
        unsafe {
            drop(Box::from_raw(handle));
        }
    }));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_result_free(buffer: EngineReadResultBuffer) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if buffer.ptr.is_null() {
            return;
        }
        unsafe {
            drop(Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.capacity));
        }
    }));
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_capture_baseline(
    vault_path: *const c_char,
    relative_path: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let relative_path = unsafe { read_c_string(relative_path, "relative_path") }?;
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let baseline = SaveBaseline::capture(&root, &relative_path).map_err(FfiError::from_save)?;
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
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let outcome =
            safe_save(&root, SaveRequest::new(&baseline, contents)).map_err(FfiError::from_save)?;
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
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let mut queue = IndexingQueue::open(&queue_path).map_err(FfiError::from_queue)?;
        let outcome = reload_after_conflict(&root, &mut queue, &conflict, generation)
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
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let mut queue = IndexingQueue::open(&queue_path).map_err(FfiError::from_queue)?;
        let outcome = keep_conflicted_buffer_as_new_note(
            &root,
            &mut queue,
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
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let mut queue = IndexingQueue::open(&queue_path).map_err(FfiError::from_queue)?;
        let outcome = overwrite_after_conflict(&root, &mut queue, &conflict, contents, generation)
            .map_err(FfiError::from_choice)?;
        Ok(FfiSaveChoiceOutcome::from(&outcome))
    })
}

#[derive(Debug, Serialize)]
struct FfiResponse<T> {
    ok: bool,
    value: Option<T>,
    error: Option<FfiError>,
}

#[derive(Debug, Serialize)]
struct FfiError {
    code: String,
    message: String,
    conflict_kind: Option<String>,
    conflict: Option<FfiSaveConflict>,
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
struct FfiSaveConflict {
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

impl FfiError {
    fn invalid_input(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_input".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn invalid_json(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_json".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn unsupported_encoding(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "unsupported_encoding".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn from_path(error: PathError) -> Self {
        Self {
            code: "path_error".to_string(),
            message: error.to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn from_save(error: SafeSaveError) -> Self {
        let (conflict_kind, conflict) = match &error {
            SafeSaveError::Conflict(conflict) => (
                Some(format!("{:?}", conflict.kind)),
                Some(FfiSaveConflict::from(conflict.as_ref())),
            ),
            _ => (None, None),
        };
        Self {
            code: match &error {
                SafeSaveError::Path(_) => "path_error",
                SafeSaveError::Conflict(_) => "save_conflict",
                SafeSaveError::ReadOnly { .. } => "read_only",
                SafeSaveError::NotRegularFile { .. } => "not_regular_file",
                SafeSaveError::Io { .. } => "io_error",
            }
            .to_string(),
            message: error.to_string(),
            conflict_kind,
            conflict,
        }
    }

    fn from_choice(error: SaveConflictChoiceError) -> Self {
        match error {
            SaveConflictChoiceError::Save(error) => Self::from_save(error),
            SaveConflictChoiceError::Queue(error) => Self::from_queue(error),
        }
    }

    fn from_queue(error: crate::indexing_queue::IndexingQueueError) -> Self {
        Self {
            code: "queue_error".to_string(),
            message: error.to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn panic() -> Self {
        Self {
            code: "panic".to_string(),
            message: "vault engine FFI call panicked".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }
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

impl From<&IndexingQueueItem> for FfiQueuedItem {
    fn from(item: &IndexingQueueItem) -> Self {
        Self {
            relative_path: item.relative_path.to_string_lossy().into_owned(),
            generation: item.generation,
            reason: format!("{:?}", item.reason),
            status: format!("{:?}", item.status),
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
            queued_item: FfiQueuedItem::from(&outcome.queued_item),
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
            queued_item: FfiQueuedItem::from(&outcome.queued_item),
            dirty: outcome.dirty,
        }
    }
}

fn ffi_response<T, F>(call: F) -> *mut c_char
where
    T: Serialize,
    F: FnOnce() -> Result<T, FfiError>,
{
    let result = catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|_| Err(FfiError::panic()));
    let response = match result {
        Ok(value) => FfiResponse {
            ok: true,
            value: Some(value),
            error: None,
        },
        Err(error) => FfiResponse {
            ok: false,
            value: None,
            error: Some(error),
        },
    };
    let json = serde_json::to_string(&response).unwrap_or_else(|error| {
        format!(
            r#"{{"ok":false,"value":null,"error":{{"code":"serialization_error","message":"{}","conflict_kind":null,"conflict":null}}}}"#,
            error
        )
    });
    CString::new(json)
        .expect("serialized FFI response must not contain nul bytes")
        .into_raw()
}

impl EngineReadHandle {
    fn open(
        metadata_path: impl AsRef<std::path::Path>,
        tantivy_path: impl AsRef<std::path::Path>,
    ) -> Result<Self, ReadOpenError> {
        Ok(Self {
            api: open_vault_read_api(metadata_path, tantivy_path)?,
        })
    }

    fn generation(&self) -> u64 {
        self.api.generation()
    }
}

fn read_open_response<F>(call: F) -> EngineReadOpenResult
where
    F: FnOnce() -> Result<EngineReadHandle, ReadOpenError>,
{
    match catch_unwind(AssertUnwindSafe(call)).unwrap_or(Err(ReadOpenError::Panic)) {
        Ok(handle) => {
            let generation = handle.generation();
            EngineReadOpenResult {
                handle: Box::into_raw(Box::new(handle)),
                result: open_status_buffer(EngineReadOpenStatus {
                    abi_version: ENGINE_ABI_VERSION,
                    ok: 1,
                    state: ENGINE_READ_STATE_COMPLETE,
                    generation,
                    error_code: 0,
                }),
            }
        }
        Err(error) => EngineReadOpenResult {
            handle: std::ptr::null_mut(),
            result: open_status_buffer(EngineReadOpenStatus {
                abi_version: ENGINE_ABI_VERSION,
                ok: 0,
                state: error.state_code(),
                generation: 0,
                error_code: error.abi_numeric_code(),
            }),
        },
    }
}

fn open_status_buffer(status: EngineReadOpenStatus) -> EngineReadResultBuffer {
    let mut bytes = Vec::with_capacity(std::mem::size_of::<EngineReadOpenStatus>());
    let status_bytes = unsafe {
        slice::from_raw_parts(
            (&status as *const EngineReadOpenStatus).cast::<u8>(),
            std::mem::size_of::<EngineReadOpenStatus>(),
        )
    };
    bytes.extend_from_slice(status_bytes);
    let result = EngineReadResultBuffer {
        ptr: bytes.as_mut_ptr(),
        len: bytes.len(),
        capacity: bytes.capacity(),
    };
    std::mem::forget(bytes);
    result
}

unsafe fn read_c_string(ptr: *const c_char, field: &str) -> Result<String, FfiError> {
    if ptr.is_null() {
        return Err(FfiError::invalid_input(field, "null pointer"));
    }
    let value = unsafe { CStr::from_ptr(ptr) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|error| FfiError::invalid_input(field, error.to_string()))
}

unsafe fn read_bytes<'a>(
    ptr: *const c_uchar,
    len: usize,
    field: &str,
) -> Result<&'a [u8], FfiError> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(FfiError::invalid_input(field, "null pointer"));
    }
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

fn read_json<T: for<'de> Deserialize<'de>>(json: &str, field: &str) -> Result<T, FfiError> {
    serde_json::from_str(json).map_err(|error| FfiError::invalid_json(field, error.to_string()))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::{IndexSchemaMetadata, MetadataStore};
    use crate::read_api::{READ_BACKEND_NAME, READ_BACKEND_VERSION, READ_TOKENIZER_CONFIG};
    use crate::sqlite_fts::SearchDocument;
    use crate::tantivy_search::TantivySearchIndex;
    use serde_json::Value;
    use std::fs;
    use tempfile::{TempDir, tempdir};

    #[test]
    fn read_handle_constructs_and_drops_without_ffi() {
        let fixture = read_fixture().expect("fixture");
        let handle = EngineReadHandle::open(&fixture.metadata_path, &fixture.tantivy_path)
            .expect("read handle");

        assert_eq!(handle.generation(), 11);
        drop(handle);
    }

    #[test]
    fn engine_read_open_opens_fixture_index_and_returns_status() {
        let fixture = read_fixture().expect("fixture");
        let metadata =
            CString::new(fixture.metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let tantivy =
            CString::new(fixture.tantivy_path.to_string_lossy().as_bytes()).expect("tantivy");

        let response = unsafe { engine_read_open(metadata.as_ptr(), tantivy.as_ptr()) };
        let status = unsafe { take_open_status(response.result) };

        assert!(!response.handle.is_null());
        assert_eq!(
            status,
            EngineReadOpenStatus {
                abi_version: ENGINE_ABI_VERSION,
                ok: 1,
                state: ENGINE_READ_STATE_COMPLETE,
                generation: 11,
                error_code: 0,
            }
        );

        unsafe {
            engine_read_close(response.handle);
        }
    }

    #[test]
    fn engine_read_open_invalid_paths_return_error_buffer() {
        let response = unsafe { engine_read_open(std::ptr::null(), std::ptr::null()) };
        let status = unsafe { take_open_status(response.result) };

        assert!(response.handle.is_null());
        assert_eq!(status.ok, 0);
        assert_eq!(status.state, crate::read_api::ENGINE_READ_STATE_ERROR);
        assert_eq!(
            status.error_code,
            ReadOpenError::InvalidInput("metadata_path").abi_numeric_code()
        );
    }

    #[test]
    fn engine_read_close_and_result_free_are_null_safe() {
        unsafe {
            engine_read_close(std::ptr::null_mut());
            engine_read_result_free(EngineReadResultBuffer {
                ptr: std::ptr::null_mut(),
                len: 0,
                capacity: 0,
            });
        }
    }

    #[test]
    fn read_ffi_panic_boundary_returns_error_buffer() {
        let response = read_open_response(|| panic!("test panic"));
        let status = unsafe { take_open_status(response.result) };

        assert!(response.handle.is_null());
        assert_eq!(status.ok, 0);
        assert_eq!(status.error_code, ReadOpenError::Panic.abi_numeric_code());
    }

    #[test]
    fn save_ffi_captures_baseline_and_writes_exact_bytes() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let relative_path = CString::new("Home.md").expect("relative path");

        let baseline_response = unsafe {
            take_response(engine_save_capture_baseline(
                vault.as_ptr(),
                relative_path.as_ptr(),
            ))
        };
        let baseline: Value = serde_json::from_str(&baseline_response).expect("baseline json");
        assert_eq!(baseline["ok"], true);

        let baseline_json = CString::new(baseline["value"].to_string()).expect("baseline payload");
        let edited = b"# Edited\n";
        let save_response = unsafe {
            take_response(engine_save_write(
                vault.as_ptr(),
                baseline_json.as_ptr(),
                edited.as_ptr(),
                edited.len(),
            ))
        };
        let saved: Value = serde_json::from_str(&save_response).expect("save json");

        assert_eq!(saved["ok"], true);
        assert_eq!(saved["value"]["bytes_written"], edited.len() as u64);
        assert_eq!(fs::read(&note).expect("saved contents"), edited);
    }

    #[test]
    fn save_ffi_returns_structured_errors() {
        let relative_path = CString::new("Home.md").expect("relative path");
        let response = unsafe {
            take_response(engine_save_capture_baseline(
                std::ptr::null(),
                relative_path.as_ptr(),
            ))
        };
        let value: Value = serde_json::from_str(&response).expect("error json");

        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "invalid_input");
        assert_eq!(value["error"]["conflict"], Value::Null);
    }

    #[test]
    fn save_ffi_returns_conflict_payload() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let relative_path = CString::new("Home.md").expect("relative path");

        let baseline_response = unsafe {
            take_response(engine_save_capture_baseline(
                vault.as_ptr(),
                relative_path.as_ptr(),
            ))
        };
        let baseline: Value = serde_json::from_str(&baseline_response).expect("baseline json");
        let baseline_json = CString::new(baseline["value"].to_string()).expect("baseline payload");

        fs::write(&note, "# External edit\n").expect("external edit");
        let edited = b"# App edit\n";
        let save_response = unsafe {
            take_response(engine_save_write(
                vault.as_ptr(),
                baseline_json.as_ptr(),
                edited.as_ptr(),
                edited.len(),
            ))
        };
        let value: Value = serde_json::from_str(&save_response).expect("conflict json");

        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "save_conflict");
        assert_eq!(value["error"]["conflict_kind"], "ContentChanged");
        assert_eq!(value["error"]["conflict"]["relative_path"], "Home.md");
        assert_eq!(value["error"]["conflict"]["kind"], "ContentChanged");
        assert_eq!(
            value["error"]["conflict"]["expected"]["relative_path"],
            "Home.md"
        );
        assert_eq!(
            value["error"]["conflict"]["actual"]["size_bytes"],
            b"# External edit\n".len() as u64
        );
    }

    #[test]
    fn save_conflict_reload_ffi_reads_disk_and_queues_file_changed() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let conflict = CString::new(conflict_json_for(&vault, &note)).expect("conflict");
        let queue_path = dir.path().join("indexing-queue.sqlite");
        let queue = CString::new(queue_path.to_string_lossy().as_bytes()).expect("queue");

        let response = unsafe {
            take_response(engine_save_reload_after_conflict(
                vault.as_ptr(),
                queue.as_ptr(),
                conflict.as_ptr(),
                7,
            ))
        };
        let value: Value = serde_json::from_str(&response).expect("reload json");

        assert_eq!(value["ok"], true);
        assert_eq!(value["value"]["contents"], "# External edit\n");
        assert_eq!(value["value"]["dirty"], false);
        assert_eq!(value["value"]["queued_item"]["relative_path"], "Home.md");
        assert_eq!(value["value"]["queued_item"]["reason"], "FileChanged");
        assert_eq!(value["value"]["queued_item"]["generation"], 7);
        assert!(queue_path.exists());
    }

    #[test]
    fn save_conflict_choice_ffi_keeps_new_and_overwrites_with_queue() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        let new_note = dir.path().join("Conflict Copy.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let conflict = CString::new(conflict_json_for(&vault, &note)).expect("conflict");
        let queue_path = dir.path().join("indexing-queue.sqlite");
        let queue = CString::new(queue_path.to_string_lossy().as_bytes()).expect("queue");
        let new_relative_path = CString::new("Conflict Copy.md").expect("new path");
        let edited = b"# App edit\n";

        let keep_response = unsafe {
            take_response(engine_save_keep_conflict_as_new_note(
                vault.as_ptr(),
                queue.as_ptr(),
                new_relative_path.as_ptr(),
                edited.as_ptr(),
                edited.len(),
                8,
            ))
        };
        let kept: Value = serde_json::from_str(&keep_response).expect("keep json");
        assert_eq!(kept["ok"], true);
        assert_eq!(kept["value"]["choice"], "KeepAsNewNote");
        assert_eq!(
            kept["value"]["baseline"]["relative_path"],
            "Conflict Copy.md"
        );
        assert_eq!(kept["value"]["queued_item"]["reason"], "OwnSave");
        assert_eq!(kept["value"]["queued_item"]["generation"], 8);
        assert_eq!(
            fs::read_to_string(&new_note).expect("new note"),
            "# App edit\n"
        );
        assert_eq!(
            fs::read_to_string(&note).expect("original"),
            "# External edit\n"
        );

        let overwrite_response = unsafe {
            take_response(engine_save_overwrite_after_conflict(
                vault.as_ptr(),
                queue.as_ptr(),
                conflict.as_ptr(),
                edited.as_ptr(),
                edited.len(),
                9,
            ))
        };
        let overwritten: Value = serde_json::from_str(&overwrite_response).expect("overwrite json");
        assert_eq!(overwritten["ok"], true);
        assert_eq!(overwritten["value"]["choice"], "Overwrite");
        assert_eq!(overwritten["value"]["queued_item"]["reason"], "OwnSave");
        assert_eq!(overwritten["value"]["queued_item"]["generation"], 9);
        assert_eq!(
            fs::read_to_string(&note).expect("overwritten"),
            "# App edit\n"
        );
    }

    #[test]
    fn save_conflict_overwrite_ffi_keeps_deleted_conflict_structured() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let conflict = CString::new(deleted_conflict_json_for(&vault, &note)).expect("conflict");
        let queue_path = dir.path().join("indexing-queue.sqlite");
        let queue = CString::new(queue_path.to_string_lossy().as_bytes()).expect("queue");
        let edited = b"# App edit\n";

        let response = unsafe {
            take_response(engine_save_overwrite_after_conflict(
                vault.as_ptr(),
                queue.as_ptr(),
                conflict.as_ptr(),
                edited.as_ptr(),
                edited.len(),
                10,
            ))
        };
        let value: Value = serde_json::from_str(&response).expect("deleted overwrite json");

        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "save_conflict");
        assert_eq!(value["error"]["conflict_kind"], "Deleted");
        assert_eq!(value["error"]["conflict"]["kind"], "Deleted");
        assert!(!note.exists());
    }

    fn conflict_json_for(vault: &CString, note: &std::path::Path) -> String {
        let relative_path = CString::new("Home.md").expect("relative path");
        let baseline_response = unsafe {
            take_response(engine_save_capture_baseline(
                vault.as_ptr(),
                relative_path.as_ptr(),
            ))
        };
        let baseline: Value = serde_json::from_str(&baseline_response).expect("baseline json");
        let baseline_json = CString::new(baseline["value"].to_string()).expect("baseline payload");

        fs::write(note, "# External edit\n").expect("external edit");
        let edited = b"# App edit\n";
        let save_response = unsafe {
            take_response(engine_save_write(
                vault.as_ptr(),
                baseline_json.as_ptr(),
                edited.as_ptr(),
                edited.len(),
            ))
        };
        let value: Value = serde_json::from_str(&save_response).expect("conflict json");
        assert_eq!(value["ok"], false);
        value["error"]["conflict"].to_string()
    }

    fn deleted_conflict_json_for(vault: &CString, note: &std::path::Path) -> String {
        let relative_path = CString::new("Home.md").expect("relative path");
        let baseline_response = unsafe {
            take_response(engine_save_capture_baseline(
                vault.as_ptr(),
                relative_path.as_ptr(),
            ))
        };
        let baseline: Value = serde_json::from_str(&baseline_response).expect("baseline json");
        let baseline_json = CString::new(baseline["value"].to_string()).expect("baseline payload");

        fs::remove_file(note).expect("delete note");
        let edited = b"# App edit\n";
        let save_response = unsafe {
            take_response(engine_save_write(
                vault.as_ptr(),
                baseline_json.as_ptr(),
                edited.as_ptr(),
                edited.len(),
            ))
        };
        let value: Value = serde_json::from_str(&save_response).expect("deleted conflict json");
        assert_eq!(value["ok"], false);
        value["error"]["conflict"].to_string()
    }

    unsafe fn take_response(ptr: *mut c_char) -> String {
        assert!(!ptr.is_null());
        let value = unsafe { CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe {
            engine_string_free(ptr);
        }
        value
    }

    unsafe fn take_open_status(buffer: EngineReadResultBuffer) -> EngineReadOpenStatus {
        assert!(!buffer.ptr.is_null());
        assert_eq!(buffer.len, std::mem::size_of::<EngineReadOpenStatus>());
        let status = unsafe { std::ptr::read_unaligned(buffer.ptr.cast::<EngineReadOpenStatus>()) };
        unsafe {
            engine_read_result_free(buffer);
        }
        status
    }

    struct ReadFixture {
        _dir: TempDir,
        metadata_path: std::path::PathBuf,
        tantivy_path: std::path::PathBuf,
    }

    fn read_fixture() -> Result<ReadFixture, Box<dyn std::error::Error>> {
        let dir = tempdir()?;
        let metadata_path = dir.path().join("metadata.sqlite");
        let tantivy_path = dir.path().join("tantivy");
        let metadata = IndexSchemaMetadata::new(
            READ_BACKEND_NAME,
            READ_BACKEND_VERSION,
            READ_TOKENIZER_CONFIG,
            11,
        );
        let store = MetadataStore::open(&metadata_path, &metadata)?;
        drop(store);
        let mut index = TantivySearchIndex::open_in_dir(&tantivy_path)?;
        index.replace_documents(&[SearchDocument {
            file_id: "home".to_string(),
            path: "Home.md".to_string(),
            title: "Home".to_string(),
            body: "body".to_string(),
        }])?;
        drop(index);

        Ok(ReadFixture {
            _dir: dir,
            metadata_path,
            tantivy_path,
        })
    }
}
