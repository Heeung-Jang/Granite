use std::ffi::CStr;
use std::os::raw::{c_char, c_uchar};
use std::slice;

use crate::use_cases::read_types::ReadApiError;

use super::json::FfiError;
use super::read::{ReadFreshnessFfiError, ReadRebuildFfiError};

pub(super) unsafe fn read_rebuild_c_string(
    ptr: *const c_char,
    field: &'static str,
) -> Result<String, ReadRebuildFfiError> {
    // SAFETY: The caller of this unsafe helper carries the same C-string
    // validity contract as `read_c_string`.
    unsafe { read_c_string(ptr, field) }.map_err(|_| ReadRebuildFfiError::invalid_input(field))
}

pub(super) unsafe fn read_freshness_c_string(
    ptr: *const c_char,
    field: &'static str,
) -> Result<String, ReadFreshnessFfiError> {
    // SAFETY: The caller of this unsafe helper carries the same C-string
    // validity contract as `read_c_string`.
    unsafe { read_c_string(ptr, field) }.map_err(|_| ReadFreshnessFfiError::invalid_input(field))
}

pub(super) unsafe fn read_read_string(
    ptr: *const c_char,
    field: &'static str,
) -> Result<String, ReadApiError> {
    // SAFETY: The caller of this unsafe helper carries the same C-string
    // validity contract as `read_c_string`.
    unsafe { read_c_string(ptr, field) }.map_err(|_| ReadApiError::InvalidInput(field))
}

/// Reads a UTF-8 C string from an FFI pointer.
///
/// # Safety
///
/// `ptr` must be null or point to a valid NUL-terminated byte sequence for the
/// duration of this call. Null and invalid UTF-8 are reported as structured
/// errors.
pub(super) unsafe fn read_c_string(ptr: *const c_char, field: &str) -> Result<String, FfiError> {
    if ptr.is_null() {
        return Err(FfiError::invalid_input(field, "null pointer"));
    }
    // SAFETY: The function contract requires a non-null valid NUL-terminated
    // C string for the duration of this call.
    let value = unsafe { CStr::from_ptr(ptr) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|error| FfiError::invalid_input(field, error.to_string()))
}

/// Reads a byte slice from an FFI pointer and length.
///
/// # Safety
///
/// When `len > 0`, `ptr` must point to `len` readable bytes for the duration of
/// this call. Null is accepted only for zero-length inputs.
pub(super) unsafe fn read_bytes<'a>(
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
    // SAFETY: The function contract requires `ptr` to reference `len`
    // readable bytes when `len > 0`.
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}
