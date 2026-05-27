use std::ffi::CString;
use std::io::{self, Write};
use std::os::raw::c_char;

use serde::{Deserialize, Serialize};

use crate::use_cases::save_note::{SafeSaveError, SaveConflictChoiceError};

use super::panic::catch_ffi_unwind;
use super::save::FfiSaveConflict;

#[derive(Debug, Serialize)]
struct FfiResponse<T> {
    ok: bool,
    value: Option<T>,
    error: Option<FfiError>,
}

#[derive(Debug, Serialize)]
pub(super) struct FfiError {
    code: String,
    message: String,
    conflict_kind: Option<String>,
    conflict: Option<FfiSaveConflict>,
}

impl FfiError {
    pub(super) fn invalid_input(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_input".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn invalid_json(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_json".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn unsupported_encoding(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "unsupported_encoding".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn invalid_request(message: impl Into<String>) -> Self {
        Self {
            code: "invalid_request".to_string(),
            message: message.into(),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn missing_index() -> Self {
        Self {
            code: "missing_index".to_string(),
            message: "graph index is missing".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn stale_schema() -> Self {
        Self {
            code: "stale_schema".to_string(),
            message: "graph index schema is stale".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn graph_index_error() -> Self {
        Self {
            code: "graph_index_error".to_string(),
            message: "graph index could not be read".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn oversized_response() -> Self {
        Self {
            code: "oversized_response".to_string(),
            message: "graph response exceeded byte cap".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    pub(super) fn from_save(error: SafeSaveError) -> Self {
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

    pub(super) fn from_choice(error: SaveConflictChoiceError) -> Self {
        match error {
            SaveConflictChoiceError::Save(error) => Self::from_save(error),
            SaveConflictChoiceError::Queue(error) => Self::from_queue(error),
        }
    }

    pub(super) fn from_queue(error: crate::adapters::sqlite::IndexingQueueError) -> Self {
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

pub(super) fn ffi_response<T, F>(call: F) -> *mut c_char
where
    T: Serialize,
    F: FnOnce() -> Result<T, FfiError>,
{
    let result = catch_ffi_unwind(call).unwrap_or_else(|_| Err(FfiError::panic()));
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

pub(super) fn read_json<T: for<'de> Deserialize<'de>>(
    json: &str,
    field: &str,
) -> Result<T, FfiError> {
    serde_json::from_str(json).map_err(|error| FfiError::invalid_json(field, error.to_string()))
}

pub(super) fn ffi_success_response_len<T: Serialize>(value: &T) -> Result<usize, FfiError> {
    let response: FfiResponse<&T> = FfiResponse {
        ok: true,
        value: Some(value),
        error: None,
    };
    let mut writer = CountingWriter::default();
    serde_json::to_writer(&mut writer, &response)
        .map(|_| writer.bytes)
        .map_err(|_| FfiError::graph_index_error())
}

#[derive(Default)]
struct CountingWriter {
    bytes: usize,
}

impl Write for CountingWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.bytes = self.bytes.saturating_add(buffer.len());
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
