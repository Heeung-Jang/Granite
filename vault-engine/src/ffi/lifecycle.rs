use std::ffi::CString;
use std::os::raw::c_char;
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::ffi::read_rows::EngineReadResultBuffer;

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

    // SAFETY: The function contract requires `ptr` to come from
    // `CString::into_raw` in this library, and null was handled above.
    unsafe {
        drop(CString::from_raw(ptr));
    }
}

/// Closes a read handle returned by `engine_read_open`.
///
/// # Safety
///
/// `handle` must be null or a pointer returned by `engine_read_open` that has
/// not already been closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_close(handle: *mut EngineReadHandle) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if handle.is_null() {
            return;
        }
        // SAFETY: The function contract requires ownership of a live
        // `EngineReadHandle` allocated by `Box::into_raw`.
        unsafe {
            drop(Box::from_raw(handle));
        }
    }));
}

/// Frees a read result buffer returned by the read FFI.
///
/// # Safety
///
/// `buffer` must be a buffer returned by this library and must not have been
/// freed already.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_result_free(buffer: EngineReadResultBuffer) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if buffer.ptr.is_null() {
            return;
        }
        // SAFETY: The function contract requires `ptr`, `len`, and `capacity`
        // to be the exact values returned by `EngineReadResultBuilder`.
        unsafe {
            drop(Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.capacity));
        }
    }));
}
