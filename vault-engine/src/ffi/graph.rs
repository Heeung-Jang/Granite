use std::os::raw::c_char;
use std::path::Path;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::core::graph::{WholeVaultGraphRequest, WholeVaultGraphSnapshot};
use crate::use_cases::build_graph::{
    WholeVaultGraphSnapshotError, WholeVaultGraphSnapshotRequest, read_whole_vault_graph_snapshot,
};

use super::json::{FfiError, ffi_response, ffi_success_response_len, read_json};
use super::strings::read_c_string;

/// Builds a whole-vault graph snapshot from a metadata database path.
///
/// # Safety
///
/// `metadata_path` and `request_json` may be null, which returns a structured
/// error. Non-null pointers must reference valid NUL-terminated byte sequences
/// for the duration of this call. Invalid JSON or unsupported request values
/// are returned as structured FFI errors.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_graph_snapshot(
    metadata_path: *const c_char,
    request_json: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        // SAFETY: `read_c_string` handles null; non-null pointers are covered
        // by this function's safety contract.
        let metadata_path = unsafe { read_c_string(metadata_path, "metadata_path") }?;
        // SAFETY: `read_c_string` handles null; non-null pointers are covered
        // by this function's safety contract.
        let request_json = unsafe { read_c_string(request_json, "request_json") }?;
        let request: FfiWholeVaultGraphRequest = read_json(&request_json, "request_json")?;
        if request.payload_version != 1 {
            return Err(FfiError::invalid_request(
                "unsupported graph request version",
            ));
        }
        if request.byte_cap_bytes == 0 {
            return Err(FfiError::invalid_request(
                "byte cap must be greater than zero",
            ));
        }
        graph_snapshot_payload(Path::new(&metadata_path), request)
    })
}

#[derive(Debug, Clone, Deserialize)]
struct FfiWholeVaultGraphRequest {
    payload_version: u32,
    request_id: u64,
    generation: u64,
    include_unresolved: bool,
    include_orphans: bool,
    max_nodes: usize,
    max_edges: usize,
    byte_cap_bytes: usize,
}

#[derive(Debug, Clone, Serialize)]
struct FfiWholeVaultGraphPayload {
    payload_version: u32,
    request_id: u64,
    generation: u64,
    state: String,
    metrics: FfiWholeVaultGraphMetrics,
    snapshot: WholeVaultGraphSnapshot,
}

#[derive(Debug, Clone, Serialize)]
struct FfiWholeVaultGraphMetrics {
    snapshot_duration_milliseconds: f64,
    encoded_payload_bytes: usize,
}

fn graph_snapshot_payload(
    metadata_path: &Path,
    request: FfiWholeVaultGraphRequest,
) -> Result<FfiWholeVaultGraphPayload, FfiError> {
    let graph_request = WholeVaultGraphRequest::with_request_id(
        request.request_id,
        request.max_nodes,
        request.max_edges,
    )
    .including_unresolved(request.include_unresolved)
    .including_orphans(request.include_orphans);
    let start = Instant::now();
    let result = read_whole_vault_graph_snapshot(WholeVaultGraphSnapshotRequest {
        metadata_path,
        requested_generation: request.generation,
        graph_request,
    })
    .map_err(graph_snapshot_error)?;
    let snapshot_duration_milliseconds = start.elapsed().as_secs_f64() * 1_000.0;
    let payload = FfiWholeVaultGraphPayload {
        payload_version: 1,
        request_id: request.request_id,
        generation: result.generation,
        state: if result.graph.partial {
            "partial".to_string()
        } else {
            "complete".to_string()
        },
        metrics: FfiWholeVaultGraphMetrics {
            snapshot_duration_milliseconds,
            encoded_payload_bytes: 0,
        },
        snapshot: result.graph.snapshot,
    };

    finalize_graph_payload(payload, request.byte_cap_bytes)
}

fn finalize_graph_payload(
    mut payload: FfiWholeVaultGraphPayload,
    byte_cap_bytes: usize,
) -> Result<FfiWholeVaultGraphPayload, FfiError> {
    for _ in 0..8 {
        let encoded_payload_bytes = ffi_success_response_len(&payload)?;
        if encoded_payload_bytes > byte_cap_bytes {
            return Err(FfiError::oversized_response());
        }
        if payload.metrics.encoded_payload_bytes == encoded_payload_bytes {
            return Ok(payload);
        }
        payload.metrics.encoded_payload_bytes = encoded_payload_bytes;
    }

    let encoded_payload_bytes = ffi_success_response_len(&payload)?;
    if encoded_payload_bytes > byte_cap_bytes {
        return Err(FfiError::oversized_response());
    }
    payload.metrics.encoded_payload_bytes = encoded_payload_bytes;
    Ok(payload)
}

fn graph_snapshot_error(error: WholeVaultGraphSnapshotError) -> FfiError {
    match error {
        WholeVaultGraphSnapshotError::MissingIndex => FfiError::missing_index(),
        WholeVaultGraphSnapshotError::StaleSchema => FfiError::stale_schema(),
        WholeVaultGraphSnapshotError::GraphIndex => FfiError::graph_index_error(),
    }
}
