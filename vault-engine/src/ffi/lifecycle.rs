use std::ffi::CString;
use std::os::raw::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::read_ffi::EngineReadResultBuffer;

use super::EngineReadHandle;

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
