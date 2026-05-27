use std::ffi::CStr;
use std::os::raw::{c_char, c_uchar};
use std::slice;

use crate::use_cases::read_types::ReadApiError;

use super::json::FfiError;
use super::read::ReadRebuildFfiError;

pub(super) unsafe fn read_rebuild_c_string(
    ptr: *const c_char,
    field: &'static str,
) -> Result<String, ReadRebuildFfiError> {
    unsafe { read_c_string(ptr, field) }.map_err(|_| ReadRebuildFfiError::invalid_input(field))
}

pub(super) unsafe fn read_read_string(
    ptr: *const c_char,
    field: &'static str,
) -> Result<String, ReadApiError> {
    unsafe { read_c_string(ptr, field) }.map_err(|_| ReadApiError::InvalidInput(field))
}

pub(super) unsafe fn read_c_string(ptr: *const c_char, field: &str) -> Result<String, FfiError> {
    if ptr.is_null() {
        return Err(FfiError::invalid_input(field, "null pointer"));
    }
    let value = unsafe { CStr::from_ptr(ptr) };
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|error| FfiError::invalid_input(field, error.to_string()))
}

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
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}
