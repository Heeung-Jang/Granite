use std::os::raw::c_char;
use std::path::Path;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::adapters::sqlite::{IndexSchemaMetadata, MetadataStore, MetadataStoreError};
use crate::graph::{WholeVaultGraphRequest, WholeVaultGraphSnapshot};
use crate::use_cases::build_graph::build_whole_vault_graph_from_metadata;

use super::json::{FfiError, ffi_response, ffi_success_response_len, read_json};
use super::strings::read_c_string;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_graph_snapshot(
    metadata_path: *const c_char,
    request_json: *const c_char,
) -> *mut c_char {
    ffi_response(|| {
        let metadata_path = unsafe { read_c_string(metadata_path, "metadata_path") }?;
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
    if !metadata_path.is_file() {
        return Err(FfiError::missing_index());
    }

    let generation = graph_request_generation(metadata_path, request.generation)?;
    let expected = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v2", "tantivy", generation);
    let metadata = MetadataStore::open(metadata_path, &expected).map_err(graph_metadata_error)?;
    let graph_request = WholeVaultGraphRequest::with_request_id(
        request.request_id,
        request.max_nodes,
        request.max_edges,
    )
    .including_unresolved(request.include_unresolved)
    .including_orphans(request.include_orphans);
    let start = Instant::now();
    let graph = build_whole_vault_graph_from_metadata(&metadata, generation, graph_request)
        .map_err(graph_metadata_error)?;
    let snapshot_duration_milliseconds = start.elapsed().as_secs_f64() * 1_000.0;
    let payload = FfiWholeVaultGraphPayload {
        payload_version: 1,
        request_id: request.request_id,
        generation,
        state: if graph.partial {
            "partial".to_string()
        } else {
            "complete".to_string()
        },
        metrics: FfiWholeVaultGraphMetrics {
            snapshot_duration_milliseconds,
            encoded_payload_bytes: 0,
        },
        snapshot: graph.snapshot,
    };

    finalize_graph_payload(payload, request.byte_cap_bytes)
}

fn graph_request_generation(
    metadata_path: &Path,
    requested_generation: u64,
) -> Result<u64, FfiError> {
    if requested_generation != 0 {
        return Ok(requested_generation);
    }

    let metadata =
        MetadataStore::stored_schema_metadata(metadata_path).map_err(graph_metadata_error)?;
    metadata
        .map(|metadata| metadata.generation)
        .ok_or_else(FfiError::graph_index_error)
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

fn graph_metadata_error(error: MetadataStoreError) -> FfiError {
    match error {
        MetadataStoreError::SchemaMismatch { .. } => FfiError::stale_schema(),
        MetadataStoreError::Sqlite(_) | MetadataStoreError::InvalidStoredValue(_) => {
            FfiError::graph_index_error()
        }
    }
}
