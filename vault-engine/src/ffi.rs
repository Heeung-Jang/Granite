use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_uchar};
use std::panic::{self, AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::slice;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::ENGINE_ABI_VERSION;
use crate::graph::{
    WholeVaultGraphInputs, WholeVaultGraphRequest, WholeVaultGraphSnapshot,
    build_whole_vault_graph_snapshot, whole_vault_graph_needs_tags,
};
use crate::index::{
    GraphFileRecord, GraphResolvedEdgeRecord, GraphUnresolvedEdgeRecord, IndexSchemaMetadata,
    MetadataStore, MetadataStoreError,
};
use crate::indexing_queue::{IndexingQueue, IndexingQueueItem};
use crate::paths::{FileIdentity, PathError, VaultRoot};
use crate::save::{
    SafeSaveError, SaveBaseline, SaveChoiceOutcome, SaveConflict, SaveConflictChoiceError,
    SaveConflictKind, SaveConflictSnapshot, SaveOutcome, SaveReloadOutcome, SaveRequest,
    keep_conflicted_buffer_as_new_note, overwrite_after_conflict, reload_after_conflict, safe_save,
};

static FFI_PANIC_HOOK_LOCK: Mutex<()> = Mutex::new(());

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
        let baseline: FfiSaveBaseline = read_json(&baseline_json, "baseline_json")?;
        let baseline = SaveBaseline::from(baseline);
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let outcome =
            safe_save(&root, SaveRequest::new(&baseline, contents)).map_err(FfiError::from_save)?;
        Ok(FfiSaveOutcome::from(&outcome))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_reload_after_conflict(
    vault_path: *const c_char,
    queue_path: *const c_char,
    conflict_json: *const c_char,
    generation: u64,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let queue_path = unsafe { read_c_string(queue_path, "queue_path") }?;
        let conflict_json = unsafe { read_c_string(conflict_json, "conflict_json") }?;
        let conflict: FfiSaveConflict = read_json(&conflict_json, "conflict_json")?;
        let conflict = SaveConflict::try_from(conflict)?;
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let mut queue = IndexingQueue::open(&queue_path).map_err(FfiError::from_queue)?;
        let outcome = reload_after_conflict(&root, &mut queue, &conflict, generation)
            .map_err(FfiError::from_choice)?;
        FfiSaveReloadOutcome::try_from(&outcome)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_keep_conflict_as_new_note(
    vault_path: *const c_char,
    queue_path: *const c_char,
    new_relative_path: *const c_char,
    contents: *const c_uchar,
    contents_len: usize,
    generation: u64,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let queue_path = unsafe { read_c_string(queue_path, "queue_path") }?;
        let new_relative_path = unsafe { read_c_string(new_relative_path, "new_relative_path") }?;
        let contents = unsafe { read_bytes(contents, contents_len, "contents") }?;
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let mut queue = IndexingQueue::open(&queue_path).map_err(FfiError::from_queue)?;
        let outcome = keep_conflicted_buffer_as_new_note(
            &root,
            &mut queue,
            &new_relative_path,
            contents,
            generation,
        )
        .map_err(FfiError::from_choice)?;
        Ok(FfiSaveChoiceOutcome::from(&outcome))
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_save_overwrite_after_conflict(
    vault_path: *const c_char,
    queue_path: *const c_char,
    conflict_json: *const c_char,
    contents: *const c_uchar,
    contents_len: usize,
    generation: u64,
) -> *mut c_char {
    ffi_response(|| {
        let vault_path = unsafe { read_c_string(vault_path, "vault_path") }?;
        let queue_path = unsafe { read_c_string(queue_path, "queue_path") }?;
        let conflict_json = unsafe { read_c_string(conflict_json, "conflict_json") }?;
        let contents = unsafe { read_bytes(contents, contents_len, "contents") }?;
        let conflict: FfiSaveConflict = read_json(&conflict_json, "conflict_json")?;
        let conflict = SaveConflict::try_from(conflict)?;
        let root = VaultRoot::open(&vault_path).map_err(FfiError::from_path)?;
        let mut queue = IndexingQueue::open(&queue_path).map_err(FfiError::from_queue)?;
        let outcome = overwrite_after_conflict(&root, &mut queue, &conflict, contents, generation)
            .map_err(FfiError::from_choice)?;
        Ok(FfiSaveChoiceOutcome::from(&outcome))
    })
}

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

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FfiSaveConflictSnapshot {
    file_identity: FfiFileIdentity,
    size_bytes: u64,
    modified: Option<FfiSystemTime>,
    content_hash: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

#[derive(Debug, Clone, Serialize)]
struct FfiQueuedItem {
    relative_path: String,
    generation: u64,
    reason: String,
    status: String,
}

#[derive(Debug, Clone, Serialize)]
struct FfiSaveReloadOutcome {
    baseline: FfiSaveBaseline,
    contents: String,
    queued_item: FfiQueuedItem,
    dirty: bool,
}

#[derive(Debug, Clone, Serialize)]
struct FfiSaveChoiceOutcome {
    choice: String,
    baseline: FfiSaveBaseline,
    bytes_written: u64,
    queued_item: FfiQueuedItem,
    dirty: bool,
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

impl FfiError {
    fn invalid_input(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_input".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn invalid_json(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "invalid_json".to_string(),
            message: format!("{field}: {}", message.into()),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn unsupported_encoding(field: &str, message: impl Into<String>) -> Self {
        Self {
            code: "unsupported_encoding".to_string(),
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

    fn from_choice(error: SaveConflictChoiceError) -> Self {
        match error {
            SaveConflictChoiceError::Save(error) => Self::from_save(error),
            SaveConflictChoiceError::Queue(error) => Self::from_queue(error),
        }
    }

    fn from_queue(error: crate::indexing_queue::IndexingQueueError) -> Self {
        Self {
            code: "queue_error".to_string(),
            message: error.to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn invalid_request(message: impl Into<String>) -> Self {
        Self {
            code: "invalid_request".to_string(),
            message: message.into(),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn missing_index() -> Self {
        Self {
            code: "missing_index".to_string(),
            message: "graph index is missing".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn stale_schema() -> Self {
        Self {
            code: "stale_schema".to_string(),
            message: "graph index schema is stale".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn graph_index_error() -> Self {
        Self {
            code: "graph_index_error".to_string(),
            message: "graph index could not be read".to_string(),
            conflict_kind: None,
            conflict: None,
        }
    }

    fn oversized_response() -> Self {
        Self {
            code: "oversized_response".to_string(),
            message: "graph response exceeded byte cap".to_string(),
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

impl From<FfiSaveConflictSnapshot> for SaveConflictSnapshot {
    fn from(snapshot: FfiSaveConflictSnapshot) -> Self {
        Self {
            file_identity: FileIdentity::from(snapshot.file_identity),
            size_bytes: snapshot.size_bytes,
            modified: snapshot.modified.map(system_time),
            content_hash: snapshot.content_hash,
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

impl TryFrom<FfiSaveConflict> for SaveConflict {
    type Error = FfiError;

    fn try_from(conflict: FfiSaveConflict) -> Result<Self, Self::Error> {
        Ok(Self {
            relative_path: conflict.relative_path,
            kind: save_conflict_kind_from_str(&conflict.kind)?,
            expected: SaveBaseline::from(conflict.expected),
            actual: conflict.actual.map(SaveConflictSnapshot::from),
        })
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

impl From<&IndexingQueueItem> for FfiQueuedItem {
    fn from(item: &IndexingQueueItem) -> Self {
        Self {
            relative_path: item.relative_path.to_string_lossy().into_owned(),
            generation: item.generation,
            reason: format!("{:?}", item.reason),
            status: format!("{:?}", item.status),
        }
    }
}

impl TryFrom<&SaveReloadOutcome> for FfiSaveReloadOutcome {
    type Error = FfiError;

    fn try_from(outcome: &SaveReloadOutcome) -> Result<Self, Self::Error> {
        let contents = String::from_utf8(outcome.contents.clone())
            .map_err(|error| FfiError::unsupported_encoding("contents", error.to_string()))?;
        Ok(Self {
            baseline: FfiSaveBaseline::from(&outcome.baseline),
            contents,
            queued_item: FfiQueuedItem::from(&outcome.queued_item),
            dirty: outcome.dirty,
        })
    }
}

impl From<&SaveChoiceOutcome> for FfiSaveChoiceOutcome {
    fn from(outcome: &SaveChoiceOutcome) -> Self {
        Self {
            choice: format!("{:?}", outcome.choice),
            baseline: FfiSaveBaseline::from(&outcome.baseline),
            bytes_written: outcome.bytes_written,
            queued_item: FfiQueuedItem::from(&outcome.queued_item),
            dirty: outcome.dirty,
        }
    }
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
    let edge_fetch_limit = graph_request.edge_limit().saturating_add(1);
    let node_fetch_limit = graph_request.node_limit().saturating_add(1);
    let all_files = metadata
        .graph_files(generation, node_fetch_limit)
        .map_err(graph_metadata_error)?;
    let has_all_files = all_files.len() < node_fetch_limit;
    let resolved_edges = if has_all_files {
        metadata
            .graph_resolved_edges_compact(generation, edge_fetch_limit)
            .map_err(graph_metadata_error)?
    } else {
        metadata
            .graph_resolved_edges(generation, edge_fetch_limit)
            .map_err(graph_metadata_error)?
    };
    let unresolved_edges = if graph_request.include_unresolved {
        metadata
            .graph_unresolved_edges(generation, edge_fetch_limit)
            .map_err(graph_metadata_error)?
    } else {
        Vec::new()
    };
    let orphan_files = if graph_request.include_orphans {
        metadata
            .graph_orphan_files(
                generation,
                graph_request.include_unresolved,
                node_fetch_limit,
            )
            .map_err(graph_metadata_error)?
    } else {
        Vec::new()
    };
    let files = if has_all_files {
        all_files
    } else {
        graph_candidate_files(
            &resolved_edges,
            &unresolved_edges,
            &orphan_files,
            node_fetch_limit,
        )
    };
    let tags = if whole_vault_graph_needs_tags(graph_request) {
        let file_ids = files
            .iter()
            .map(|file| file.file_id.clone())
            .collect::<Vec<_>>();
        metadata
            .graph_tags_for_files(&file_ids, graph_request.tag_limit().saturating_add(1))
            .map_err(graph_metadata_error)?
    } else {
        Vec::new()
    };
    let node_count_total = metadata
        .graph_visible_node_count(
            generation,
            graph_request.include_unresolved,
            graph_request.include_orphans,
        )
        .map_err(graph_metadata_error)?;
    let edge_count_total = metadata
        .graph_visible_edge_count(generation, graph_request.include_unresolved)
        .map_err(graph_metadata_error)?;
    let graph = build_whole_vault_graph_snapshot(
        graph_request,
        generation,
        WholeVaultGraphInputs {
            node_count_total,
            edge_count_total,
            files,
            resolved_edges,
            unresolved_edges,
            orphan_files,
            tags,
        },
    );
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

fn ffi_success_response_len<T: Serialize>(value: &T) -> Result<usize, FfiError> {
    let response: FfiResponse<&T> = FfiResponse {
        ok: true,
        value: Some(value),
        error: None,
    };
    serde_json::to_vec(&response)
        .map(|bytes| bytes.len())
        .map_err(|_| FfiError::graph_index_error())
}

fn graph_metadata_error(error: MetadataStoreError) -> FfiError {
    match error {
        MetadataStoreError::SchemaMismatch { .. } => FfiError::stale_schema(),
        MetadataStoreError::Sqlite(_) | MetadataStoreError::InvalidStoredValue(_) => {
            FfiError::graph_index_error()
        }
    }
}

fn graph_candidate_files(
    resolved_edges: &[GraphResolvedEdgeRecord],
    unresolved_edges: &[GraphUnresolvedEdgeRecord],
    orphan_files: &[GraphFileRecord],
    limit: usize,
) -> Vec<GraphFileRecord> {
    let mut seen = HashSet::new();
    let mut files = Vec::new();

    for edge in resolved_edges {
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &edge.source_file_id,
            &edge.source_relative_path,
        );
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &edge.target_file_id,
            &edge.target_relative_path,
        );
    }
    for edge in unresolved_edges {
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &edge.source_file_id,
            &edge.source_relative_path,
        );
    }
    for file in orphan_files {
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &file.file_id,
            &file.relative_path,
        );
    }

    files
}

fn push_graph_candidate_file(
    files: &mut Vec<GraphFileRecord>,
    seen: &mut HashSet<String>,
    limit: usize,
    file_id: &str,
    relative_path: &Path,
) {
    if files.len() >= limit || !seen.insert(file_id.to_string()) {
        return;
    }
    files.push(GraphFileRecord {
        file_id: file_id.to_string(),
        relative_path: relative_path.to_path_buf(),
    });
}

fn ffi_response<T, F>(call: F) -> *mut c_char
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

fn catch_ffi_unwind<T, F>(call: F) -> std::thread::Result<T>
where
    F: FnOnce() -> T,
{
    let _guard = FFI_PANIC_HOOK_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let result = catch_unwind(AssertUnwindSafe(call));
    panic::set_hook(previous_hook);
    result
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

fn read_json<T: for<'de> Deserialize<'de>>(json: &str, field: &str) -> Result<T, FfiError> {
    serde_json::from_str(json).map_err(|error| FfiError::invalid_json(field, error.to_string()))
}

fn save_conflict_kind_from_str(kind: &str) -> Result<SaveConflictKind, FfiError> {
    match kind {
        "Deleted" => Ok(SaveConflictKind::Deleted),
        "FileIdentityChanged" => Ok(SaveConflictKind::FileIdentityChanged),
        "ContentChanged" => Ok(SaveConflictKind::ContentChanged),
        "MetadataChanged" => Ok(SaveConflictKind::MetadataChanged),
        "SymlinkChanged" => Ok(SaveConflictKind::SymlinkChanged),
        _ => Err(FfiError::invalid_input(
            "conflict.kind",
            format!("unsupported save conflict kind: {kind}"),
        )),
    }
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
    use crate::index::{
        FileIndexStatus, FileRecord, IndexSchemaMetadata, LinkEdgeRecord, MetadataStore, TagRecord,
        TagSource,
    };
    use crate::paths::FileIdentity;
    use crate::scanner::ScanEntryKind;
    use serde_json::Value;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, Ordering};
    use tempfile::tempdir;

    #[test]
    fn graph_ffi_returns_versioned_payload() {
        let dir = tempdir().expect("tempdir");
        let metadata_path = dir.path().join("metadata.sqlite");
        write_graph_metadata(&metadata_path, "metadata-v2", 1);
        let metadata = CString::new(metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let request = CString::new(graph_request_json(1, 1, 1024 * 1024)).expect("request");

        let response =
            unsafe { take_response(engine_graph_snapshot(metadata.as_ptr(), request.as_ptr())) };
        let json: Value = serde_json::from_str(&response).expect("response json");

        assert_eq!(json["ok"], true);
        assert_eq!(json["value"]["payload_version"], 1);
        assert_eq!(json["value"]["request_id"], 1);
        assert_eq!(json["value"]["generation"], 1);
        assert_eq!(json["value"]["state"], "complete");
        assert_eq!(json["value"]["snapshot"]["node_count_total"], 2);
        assert_eq!(json["value"]["snapshot"]["edge_count_total"], 1);
        assert_eq!(
            json["value"]["snapshot"]["nodes"]
                .as_array()
                .expect("nodes")
                .len(),
            2
        );
        assert_eq!(
            json["value"]["snapshot"]["edges"]
                .as_array()
                .expect("edges")
                .len(),
            1
        );
        assert!(
            json["value"]["metrics"]["snapshot_duration_milliseconds"]
                .as_f64()
                .expect("duration")
                >= 0.0
        );
        assert!(
            json["value"]["metrics"]["encoded_payload_bytes"]
                .as_u64()
                .expect("payload bytes")
                > 0
        );
        assert_eq!(
            json["value"]["metrics"]["encoded_payload_bytes"]
                .as_u64()
                .expect("payload bytes") as usize,
            response.len()
        );
    }

    #[test]
    fn graph_ffi_uses_current_metadata_generation() {
        let dir = tempdir().expect("tempdir");
        let metadata_path = dir.path().join("metadata.sqlite");
        write_graph_metadata(&metadata_path, "metadata-v2", 7);
        let metadata = CString::new(metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let request = CString::new(graph_request_json(1, 0, 1024 * 1024)).expect("request");

        let response =
            unsafe { take_response(engine_graph_snapshot(metadata.as_ptr(), request.as_ptr())) };
        let json: Value = serde_json::from_str(&response).expect("response json");

        assert_eq!(json["ok"], true);
        assert_eq!(json["value"]["generation"], 7);
        assert_eq!(json["value"]["snapshot"]["generation"], 7);
        assert_eq!(json["value"]["snapshot"]["node_count_total"], 2);
        assert_eq!(json["value"]["snapshot"]["edge_count_total"], 1);
    }

    #[test]
    fn graph_ffi_returns_redacted_structured_errors() {
        let dir = tempdir().expect("tempdir");
        let missing_path = dir.path().join("SecretProject").join("metadata.sqlite");
        let missing = CString::new(missing_path.to_string_lossy().as_bytes()).expect("missing");
        let request = CString::new(graph_request_json(1, 1, 1024 * 1024)).expect("request");

        let missing_response =
            unsafe { take_response(engine_graph_snapshot(missing.as_ptr(), request.as_ptr())) };
        assert_graph_error(&missing_response, "missing_index");
        assert!(!missing_response.contains("SecretProject"));
        assert!(!missing_response.contains(&dir.path().to_string_lossy().to_string()));

        let metadata_path = dir.path().join("metadata.sqlite");
        write_graph_metadata(&metadata_path, "metadata-v1", 1);
        let metadata = CString::new(metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let stale_response =
            unsafe { take_response(engine_graph_snapshot(metadata.as_ptr(), request.as_ptr())) };
        assert_graph_error(&stale_response, "stale_schema");
        assert!(!stale_response.contains("SecretProject"));
        assert!(!stale_response.contains(&metadata_path.to_string_lossy().to_string()));

        let invalid_request = CString::new(graph_request_json(1, 1, 1024 * 1024).replacen(
            r#""payload_version":1"#,
            r#""payload_version":2"#,
            1,
        ))
        .expect("invalid request");
        let invalid_response = unsafe {
            take_response(engine_graph_snapshot(
                metadata.as_ptr(),
                invalid_request.as_ptr(),
            ))
        };
        assert_graph_error(&invalid_response, "invalid_request");

        let tiny_cap = CString::new(graph_request_json(1, 1, 1)).expect("tiny cap");
        let oversized_response =
            unsafe { take_response(engine_graph_snapshot(metadata.as_ptr(), tiny_cap.as_ptr())) };
        assert_graph_error(&oversized_response, "stale_schema");
    }

    #[test]
    fn graph_ffi_reports_oversized_response_without_private_values() {
        let dir = tempdir().expect("tempdir");
        let metadata_path = dir.path().join("metadata.sqlite");
        write_graph_metadata(&metadata_path, "metadata-v2", 1);
        let metadata = CString::new(metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let request = CString::new(graph_request_json(1, 1, 1)).expect("request");

        let response =
            unsafe { take_response(engine_graph_snapshot(metadata.as_ptr(), request.as_ptr())) };

        assert_graph_error(&response, "oversized_response");
        assert!(!response.contains("SecretProject"));
        assert!(!response.contains("client@example.com"));
        assert!(!response.contains(&metadata_path.to_string_lossy().to_string()));
    }

    #[test]
    fn graph_ffi_reports_oversized_response_when_envelope_exceeds_cap() {
        let dir = tempdir().expect("tempdir");
        let metadata_path = dir.path().join("metadata.sqlite");
        write_graph_metadata(&metadata_path, "metadata-v2", 1);
        let uncapped_payload = graph_snapshot_payload(
            &metadata_path,
            FfiWholeVaultGraphRequest {
                payload_version: 1,
                request_id: 1,
                generation: 1,
                include_unresolved: false,
                include_orphans: false,
                max_nodes: 100,
                max_edges: 100,
                byte_cap_bytes: 1024 * 1024,
            },
        )
        .expect("uncapped graph payload");
        let full_response_len =
            ffi_success_response_len(&uncapped_payload).expect("full response length");
        let snapshot_len = serde_json::to_vec(&uncapped_payload.snapshot)
            .expect("snapshot json")
            .len();
        let boundary_cap = snapshot_len;
        assert!(boundary_cap < full_response_len);

        let metadata = CString::new(metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let request = CString::new(graph_request_json(1, 1, boundary_cap)).expect("request");
        let response =
            unsafe { take_response(engine_graph_snapshot(metadata.as_ptr(), request.as_ptr())) };

        assert_graph_error(&response, "oversized_response");
        assert!(!response.contains("SecretProject"));
        assert!(!response.contains("client@example.com"));
        assert!(!response.contains(&metadata_path.to_string_lossy().to_string()));
    }

    #[test]
    fn ffi_response_catches_panics() {
        let response = unsafe {
            take_response(ffi_response(|| -> Result<Value, FfiError> {
                panic!("graph panic should be redacted");
            }))
        };

        assert_graph_error(&response, "panic");
        assert!(!response.contains("graph panic should be redacted"));
    }

    #[test]
    fn ffi_response_suppresses_panic_hook_payloads() {
        static HOOK_WAS_CALLED: AtomicBool = AtomicBool::new(false);
        HOOK_WAS_CALLED.store(false, Ordering::SeqCst);
        let previous_hook = panic::take_hook();
        panic::set_hook(Box::new(|info| {
            if info.to_string().contains("SecretProject") {
                HOOK_WAS_CALLED.store(true, Ordering::SeqCst);
            }
        }));

        let result = catch_ffi_unwind(|| {
            panic!("SecretProject client@example.com");
        });
        panic::set_hook(previous_hook);

        assert!(result.is_err());
        assert!(!HOOK_WAS_CALLED.load(Ordering::SeqCst));
    }

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

    #[test]
    fn save_conflict_reload_ffi_reads_disk_and_queues_file_changed() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let conflict = CString::new(conflict_json_for(&vault, &note)).expect("conflict");
        let queue_path = dir.path().join("indexing-queue.sqlite");
        let queue = CString::new(queue_path.to_string_lossy().as_bytes()).expect("queue");

        let response = unsafe {
            take_response(engine_save_reload_after_conflict(
                vault.as_ptr(),
                queue.as_ptr(),
                conflict.as_ptr(),
                7,
            ))
        };
        let value: Value = serde_json::from_str(&response).expect("reload json");

        assert_eq!(value["ok"], true);
        assert_eq!(value["value"]["contents"], "# External edit\n");
        assert_eq!(value["value"]["dirty"], false);
        assert_eq!(value["value"]["queued_item"]["relative_path"], "Home.md");
        assert_eq!(value["value"]["queued_item"]["reason"], "FileChanged");
        assert_eq!(value["value"]["queued_item"]["generation"], 7);
        assert!(queue_path.exists());
    }

    #[test]
    fn save_conflict_choice_ffi_keeps_new_and_overwrites_with_queue() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        let new_note = dir.path().join("Conflict Copy.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let conflict = CString::new(conflict_json_for(&vault, &note)).expect("conflict");
        let queue_path = dir.path().join("indexing-queue.sqlite");
        let queue = CString::new(queue_path.to_string_lossy().as_bytes()).expect("queue");
        let new_relative_path = CString::new("Conflict Copy.md").expect("new path");
        let edited = b"# App edit\n";

        let keep_response = unsafe {
            take_response(engine_save_keep_conflict_as_new_note(
                vault.as_ptr(),
                queue.as_ptr(),
                new_relative_path.as_ptr(),
                edited.as_ptr(),
                edited.len(),
                8,
            ))
        };
        let kept: Value = serde_json::from_str(&keep_response).expect("keep json");
        assert_eq!(kept["ok"], true);
        assert_eq!(kept["value"]["choice"], "KeepAsNewNote");
        assert_eq!(
            kept["value"]["baseline"]["relative_path"],
            "Conflict Copy.md"
        );
        assert_eq!(kept["value"]["queued_item"]["reason"], "OwnSave");
        assert_eq!(kept["value"]["queued_item"]["generation"], 8);
        assert_eq!(
            fs::read_to_string(&new_note).expect("new note"),
            "# App edit\n"
        );
        assert_eq!(
            fs::read_to_string(&note).expect("original"),
            "# External edit\n"
        );

        let overwrite_response = unsafe {
            take_response(engine_save_overwrite_after_conflict(
                vault.as_ptr(),
                queue.as_ptr(),
                conflict.as_ptr(),
                edited.as_ptr(),
                edited.len(),
                9,
            ))
        };
        let overwritten: Value = serde_json::from_str(&overwrite_response).expect("overwrite json");
        assert_eq!(overwritten["ok"], true);
        assert_eq!(overwritten["value"]["choice"], "Overwrite");
        assert_eq!(overwritten["value"]["queued_item"]["reason"], "OwnSave");
        assert_eq!(overwritten["value"]["queued_item"]["generation"], 9);
        assert_eq!(
            fs::read_to_string(&note).expect("overwritten"),
            "# App edit\n"
        );
    }

    #[test]
    fn save_conflict_overwrite_ffi_keeps_deleted_conflict_structured() {
        let dir = tempdir().expect("tempdir");
        let note = dir.path().join("Home.md");
        fs::write(&note, "# Home\n").expect("note");
        let vault = CString::new(dir.path().to_string_lossy().as_bytes()).expect("vault");
        let conflict = CString::new(deleted_conflict_json_for(&vault, &note)).expect("conflict");
        let queue_path = dir.path().join("indexing-queue.sqlite");
        let queue = CString::new(queue_path.to_string_lossy().as_bytes()).expect("queue");
        let edited = b"# App edit\n";

        let response = unsafe {
            take_response(engine_save_overwrite_after_conflict(
                vault.as_ptr(),
                queue.as_ptr(),
                conflict.as_ptr(),
                edited.as_ptr(),
                edited.len(),
                10,
            ))
        };
        let value: Value = serde_json::from_str(&response).expect("deleted overwrite json");

        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "save_conflict");
        assert_eq!(value["error"]["conflict_kind"], "Deleted");
        assert_eq!(value["error"]["conflict"]["kind"], "Deleted");
        assert!(!note.exists());
    }

    fn conflict_json_for(vault: &CString, note: &std::path::Path) -> String {
        let relative_path = CString::new("Home.md").expect("relative path");
        let baseline_response = unsafe {
            take_response(engine_save_capture_baseline(
                vault.as_ptr(),
                relative_path.as_ptr(),
            ))
        };
        let baseline: Value = serde_json::from_str(&baseline_response).expect("baseline json");
        let baseline_json = CString::new(baseline["value"].to_string()).expect("baseline payload");

        fs::write(note, "# External edit\n").expect("external edit");
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
        value["error"]["conflict"].to_string()
    }

    fn deleted_conflict_json_for(vault: &CString, note: &std::path::Path) -> String {
        let relative_path = CString::new("Home.md").expect("relative path");
        let baseline_response = unsafe {
            take_response(engine_save_capture_baseline(
                vault.as_ptr(),
                relative_path.as_ptr(),
            ))
        };
        let baseline: Value = serde_json::from_str(&baseline_response).expect("baseline json");
        let baseline_json = CString::new(baseline["value"].to_string()).expect("baseline payload");

        fs::remove_file(note).expect("delete note");
        let edited = b"# App edit\n";
        let save_response = unsafe {
            take_response(engine_save_write(
                vault.as_ptr(),
                baseline_json.as_ptr(),
                edited.as_ptr(),
                edited.len(),
            ))
        };
        let value: Value = serde_json::from_str(&save_response).expect("deleted conflict json");
        assert_eq!(value["ok"], false);
        value["error"]["conflict"].to_string()
    }

    fn graph_request_json(request_id: u64, generation: u64, byte_cap_bytes: usize) -> String {
        format!(
            r#"{{"payload_version":1,"request_id":{request_id},"generation":{generation},"include_unresolved":false,"include_orphans":false,"max_nodes":100,"max_edges":100,"byte_cap_bytes":{byte_cap_bytes}}}"#
        )
    }

    fn write_graph_metadata(path: &Path, backend_version: &str, generation: u64) {
        let metadata =
            IndexSchemaMetadata::new("sqlite+tantivy", backend_version, "tantivy", generation);
        let mut store = MetadataStore::open(path, &metadata).expect("metadata store");
        let mut home = graph_file("home", "SecretProject.md", generation, 1);
        home.status = FileIndexStatus::SearchIndexed;
        let mut target = graph_file("target", "Target.md", generation, 2);
        target.status = FileIndexStatus::SearchIndexed;
        store
            .replace_file_records(
                &home,
                &[LinkEdgeRecord {
                    source_file_id: home.file_id.clone(),
                    target_text: "Target".to_string(),
                    resolved_target_file_id: Some(target.file_id.clone()),
                    heading: None,
                    alias: None,
                    is_embed: false,
                }],
                &[TagRecord {
                    file_id: home.file_id.clone(),
                    tag: "client@example.com".to_string(),
                    source: TagSource::Inline,
                }],
                &[],
                &[],
                &[],
            )
            .expect("home records");
        store
            .replace_file_records(&target, &[], &[], &[], &[], &[])
            .expect("target records");
    }

    fn graph_file(file_id: &str, relative_path: &str, generation: u64, inode: u64) -> FileRecord {
        FileRecord {
            file_id: file_id.to_string(),
            relative_path: PathBuf::from(relative_path),
            kind: ScanEntryKind::Markdown,
            size_bytes: 1,
            modified: None,
            file_identity: FileIdentity { device: 1, inode },
            content_hash: Some(format!("{file_id}-hash")),
            generation,
            status: FileIndexStatus::Parsed,
            last_error: None,
        }
    }

    fn assert_graph_error(response: &str, expected_code: &str) {
        let json: Value = serde_json::from_str(response).expect("response json");
        assert_eq!(json["ok"], false);
        assert_eq!(json["error"]["code"], expected_code);
        assert_eq!(json["value"], Value::Null);
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
