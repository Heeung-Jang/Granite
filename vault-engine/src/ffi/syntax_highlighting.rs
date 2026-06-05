use std::os::raw::{c_char, c_uchar};
use std::panic::{AssertUnwindSafe, catch_unwind};

use crate::core::syntax_highlighting::{
    SyntaxHighlightResult, SyntaxHighlightState, SyntaxLanguage,
};
use crate::ffi::read_rows::{
    ENGINE_READ_ROW_KIND_SYNTAX_TOKEN, EngineReadResultBuffer, EngineReadResultBuilder,
    EngineSyntaxHighlightTokenRow, error_result_buffer,
};
use crate::use_cases::highlight_code_fence::highlight_code_fence;
use crate::use_cases::read_types::{ENGINE_READ_STATE_COMPLETE, ENGINE_READ_STATE_ERROR};

use super::strings::{read_bytes, read_c_string};

/// Highlights one live-preview fenced code block.
///
/// # Safety
///
/// `language` may be null, which means plain text. A non-null language pointer
/// must reference a valid NUL-terminated byte sequence for the duration of this
/// call. `code` may be null only when `code_len == 0`; otherwise it must point
/// to `code_len` initialized bytes for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_live_preview_highlight_code(
    request_id: u64,
    language: *const c_char,
    code: *const c_uchar,
    code_len: usize,
    visible_start_utf16: u32,
    visible_len_utf16: u32,
) -> EngineReadResultBuffer {
    match catch_unwind(AssertUnwindSafe(|| {
        let language = read_language(language);
        // SAFETY: The caller owns the bytes lifetime contract documented on this function.
        let code = unsafe { read_bytes(code, code_len, "code") }
            .map_err(|_| SyntaxFfiError::invalid_input("code"))?;
        let code = std::str::from_utf8(code).map_err(|_| SyntaxFfiError::invalid_input("code"))?;
        Ok::<_, SyntaxFfiError>(highlight_result_buffer(
            request_id,
            highlight_code_fence(language, code, visible_start_utf16, visible_len_utf16),
        ))
    })) {
        Ok(Ok(buffer)) => buffer,
        Ok(Err(error)) => syntax_error_buffer(request_id, error),
        Err(_) => syntax_error_buffer(request_id, SyntaxFfiError::panic()),
    }
}

fn read_language(language: *const c_char) -> SyntaxLanguage {
    if language.is_null() {
        return SyntaxLanguage::Plain;
    }
    // SAFETY: The pointer is non-null and the FFI function documents the
    // NUL-terminated string contract. Invalid strings fall back to plain text
    // to preserve Live Preview rendering.
    match unsafe { read_c_string(language, "language") } {
        Ok(value) => SyntaxLanguage::from_info_token(value.split_whitespace().next()),
        Err(_) => SyntaxLanguage::Plain,
    }
}

fn highlight_result_buffer(
    request_id: u64,
    result: SyntaxHighlightResult,
) -> EngineReadResultBuffer {
    let mut builder = EngineReadResultBuilder::new(
        ENGINE_READ_ROW_KIND_SYNTAX_TOKEN,
        request_id,
        0,
        syntax_state_code(result.state),
        None,
    );
    for token in &result.tokens {
        let row = EngineSyntaxHighlightTokenRow::from_token(token);
        builder.push_row(&row);
    }
    builder.finish()
}

fn syntax_state_code(_state: SyntaxHighlightState) -> u32 {
    ENGINE_READ_STATE_COMPLETE
}

fn syntax_error_buffer(request_id: u64, error: SyntaxFfiError) -> EngineReadResultBuffer {
    error_result_buffer(
        ENGINE_READ_ROW_KIND_SYNTAX_TOKEN,
        request_id,
        0,
        ENGINE_READ_STATE_ERROR,
        error.code,
        error.message,
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SyntaxFfiError {
    code: &'static str,
    message: &'static str,
}

impl SyntaxFfiError {
    fn invalid_input(field: &'static str) -> Self {
        Self {
            code: "invalid_input",
            message: field,
        }
    }

    fn panic() -> Self {
        Self {
            code: "panic",
            message: "vault engine FFI call panicked",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::syntax_highlighting::{SYNTAX_TOKEN_KIND_KEYWORD, SYNTAX_TOKEN_KIND_STRING};
    use crate::ffi::lifecycle::engine_read_result_free;
    use crate::ffi::read_rows::{decode_header_for_test, syntax_rows_for_test};
    use std::ffi::CString;

    #[test]
    fn ffi_highlights_rust_and_returns_stable_rows() {
        let language = CString::new("rust").expect("language");
        let code = b"fn main() { let name = \"granite\"; }";

        let buffer = unsafe {
            engine_live_preview_highlight_code(
                44,
                language.as_ptr(),
                code.as_ptr(),
                code.len(),
                0,
                0,
            )
        };

        let header = decode_header_for_test(&buffer);
        assert_eq!(header.request_id, 44);
        assert_eq!(header.row_kind, ENGINE_READ_ROW_KIND_SYNTAX_TOKEN);
        assert_eq!(header.row_stride as usize, 12);
        let rows = syntax_rows_for_test(&buffer);
        assert!(
            rows.iter()
                .any(|row| row.token_kind == SYNTAX_TOKEN_KIND_KEYWORD)
        );
        assert!(
            rows.iter()
                .any(|row| row.token_kind == SYNTAX_TOKEN_KIND_STRING)
        );
        unsafe {
            engine_read_result_free(buffer);
        }
    }

    #[test]
    fn ffi_rejects_null_code_with_nonzero_length() {
        let language = CString::new("rust").expect("language");

        let buffer = unsafe {
            engine_live_preview_highlight_code(45, language.as_ptr(), std::ptr::null(), 1, 0, 0)
        };

        let header = decode_header_for_test(&buffer);
        assert_eq!(header.state, ENGINE_READ_STATE_ERROR);
        unsafe {
            engine_read_result_free(buffer);
        }
    }
}
