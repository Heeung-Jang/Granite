use std::ffi::CString;
use std::os::raw::c_char;

use crate::ENGINE_ABI_VERSION;

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
