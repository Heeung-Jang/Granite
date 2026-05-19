use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_uchar};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::ENGINE_ABI_VERSION;
use crate::paths::{FileIdentity, PathError, VaultRoot};
use crate::save::{
    SafeSaveError, SaveBaseline, SaveConflict, SaveConflictSnapshot, SaveOutcome, SaveRequest,
    safe_save,
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
        let baseline: FfiSaveBaseline =
            serde_json::from_str(&baseline_json).map_err(|error| FfiError {
                code: "invalid_json".to_string(),
                message: error.to_string(),
                conflict_kind: None,
                conflict: None,
            })?;
        let baseline = SaveBaseline::from(baseline);
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let outcome =
            safe_save(&root, SaveRequest::new(&baseline, contents)).map_err(FfiError::from_save)?;
        Ok(FfiSaveOutcome::from(&outcome))
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

#[derive(Debug, Clone, Serialize)]
struct FfiSaveConflictSnapshot {
    file_identity: FfiFileIdentity,
    size_bytes: u64,
    modified: Option<FfiSystemTime>,
    content_hash: String,
}

#[derive(Debug, Clone, Serialize)]
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

impl FfiError {
    fn invalid_input(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_input".to_string(),
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

impl From<&SaveOutcome> for FfiSaveOutcome {
    fn from(outcome: &SaveOutcome) -> Self {
        Self {
            baseline: FfiSaveBaseline::from(&outcome.baseline),
            bytes_written: outcome.bytes_written,
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
    use serde_json::Value;
    use std::fs;
    use tempfile::tempdir;

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
}
