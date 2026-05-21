use std::collections::HashSet;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_uchar};
use std::panic::{self, AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr::NonNull;
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
use crate::read_api::{
    ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
    ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
    ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
    ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP, ENGINE_READ_STATE_CANCELLED, ENGINE_READ_STATE_COMPLETE,
    ENGINE_READ_STATE_ERROR, ENGINE_READ_STATE_PARTIAL, ENGINE_READ_STATE_STALE, LocalGraphDepth,
    LocalGraphRequest, ReadApiError, ReadOpenError, ReadPage, ReadState, VaultReadApi,
    open_vault_read_api,
};
use crate::read_ffi::{
    ENGINE_READ_ROW_KIND_ATTACHMENT, ENGINE_READ_ROW_KIND_BACKLINK, ENGINE_READ_ROW_KIND_FILE_TREE,
    ENGINE_READ_ROW_KIND_GRAPH_EDGE, ENGINE_READ_ROW_KIND_GRAPH_NODE,
    ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA, ENGINE_READ_ROW_KIND_OUTGOING_LINK,
    ENGINE_READ_ROW_KIND_PROPERTY, ENGINE_READ_ROW_KIND_SEARCH_HIT, ENGINE_READ_ROW_KIND_TAG,
    EngineReadAttachmentRow, EngineReadFileTreeRow, EngineReadGraphEdgeRow, EngineReadGraphNodeRow,
    EngineReadLinkRow, EngineReadLivePreviewMetadataRow, EngineReadPropertyRow,
    EngineReadResultBuffer, EngineReadResultBuilder, EngineReadSearchHitRow, EngineReadTagRow,
    error_result_buffer, open_error_buffer, open_status_buffer,
};
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

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct EngineReadOpenResult {
    pub handle: *mut EngineReadHandle,
    pub result: EngineReadResultBuffer,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct EngineReadLocalGraphResult {
    pub nodes: EngineReadResultBuffer,
    pub edges: EngineReadResultBuffer,
}

pub struct EngineReadHandle {
    api: VaultReadApi,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_open(
    metadata_path: *const c_char,
    tantivy_path: *const c_char,
) -> EngineReadOpenResult {
    read_open_response(|| {
        let metadata_path = unsafe {
            read_c_string(metadata_path, "metadata_path")
                .map_err(|_| ReadOpenError::InvalidInput("metadata_path"))?
        };
        let tantivy_path = unsafe {
            read_c_string(tantivy_path, "tantivy_path")
                .map_err(|_| ReadOpenError::InvalidInput("tantivy_path"))?
        };
        EngineReadHandle::open(metadata_path, tantivy_path)
    })
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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_file_tree(
    handle: *mut EngineReadHandle,
    request_id: u64,
    offset: usize,
    limit: usize,
) -> EngineReadResultBuffer {
    read_page_response(
        handle,
        ENGINE_READ_ROW_KIND_FILE_TREE,
        request_id,
        |api| {
            api.file_tree_projection(crate::read_api::PageRequest::with_request_id(
                request_id, offset, limit,
            ))
        },
        EngineReadFileTreeRow::from_projection,
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_search(
    handle: *mut EngineReadHandle,
    request_id: u64,
    mode: u32,
    query: *const c_char,
    offset: usize,
    limit: usize,
) -> EngineReadResultBuffer {
    let query = match unsafe { read_read_string(query, "query") } {
        Ok(value) => value,
        Err(error) => {
            return read_api_error_buffer(ENGINE_READ_ROW_KIND_SEARCH_HIT, request_id, 0, &error);
        }
    };
    read_page_response(
        handle,
        ENGINE_READ_ROW_KIND_SEARCH_HIT,
        request_id,
        |api| {
            api.search_with_mode(
                mode,
                &query,
                crate::read_api::PageRequest::with_request_id(request_id, offset, limit),
            )
        },
        EngineReadSearchHitRow::from_hit,
    )
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_inspector_panel(
    handle: *mut EngineReadHandle,
    request_id: u64,
    relative_path: *const c_char,
    panel: u32,
    offset: usize,
    limit: usize,
) -> EngineReadResultBuffer {
    let relative_path = match unsafe { read_read_string(relative_path, "relative_path") } {
        Ok(value) => value,
        Err(error) => return read_api_error_buffer(panel_row_kind(panel), request_id, 0, &error),
    };
    match panel {
        ENGINE_READ_INSPECTOR_PANEL_BACKLINKS => read_page_response(
            handle,
            ENGINE_READ_ROW_KIND_BACKLINK,
            request_id,
            |api| {
                api.backlinks_for_path(
                    &relative_path,
                    crate::read_api::PageRequest::with_request_id(request_id, offset, limit),
                )
            },
            EngineReadLinkRow::from_projection,
        ),
        ENGINE_READ_INSPECTOR_PANEL_OUTGOING => read_page_response(
            handle,
            ENGINE_READ_ROW_KIND_OUTGOING_LINK,
            request_id,
            |api| {
                api.outgoing_links_for_path(
                    &relative_path,
                    crate::read_api::PageRequest::with_request_id(request_id, offset, limit),
                )
            },
            EngineReadLinkRow::from_projection,
        ),
        ENGINE_READ_INSPECTOR_PANEL_TAGS => read_page_response(
            handle,
            ENGINE_READ_ROW_KIND_TAG,
            request_id,
            |api| {
                api.tags_for_path(
                    &relative_path,
                    crate::read_api::PageRequest::with_request_id(request_id, offset, limit),
                )
            },
            EngineReadTagRow::from_record,
        ),
        ENGINE_READ_INSPECTOR_PANEL_PROPERTIES => read_page_response(
            handle,
            ENGINE_READ_ROW_KIND_PROPERTY,
            request_id,
            |api| {
                api.properties_for_path(
                    &relative_path,
                    crate::read_api::PageRequest::with_request_id(request_id, offset, limit),
                )
            },
            EngineReadPropertyRow::from_projection,
        ),
        ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS => read_page_response(
            handle,
            ENGINE_READ_ROW_KIND_ATTACHMENT,
            request_id,
            |api| {
                api.attachments_for_path(
                    &relative_path,
                    crate::read_api::PageRequest::with_request_id(request_id, offset, limit),
                )
            },
            EngineReadAttachmentRow::from_projection,
        ),
        _ => read_api_error_buffer(
            panel_row_kind(panel),
            request_id,
            read_generation(handle),
            &ReadApiError::InvalidInput("panel"),
        ),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_local_graph(
    handle: *mut EngineReadHandle,
    request_id: u64,
    relative_path: *const c_char,
    depth: u32,
    max_nodes: usize,
    max_edges: usize,
) -> EngineReadLocalGraphResult {
    let relative_path = match unsafe { read_read_string(relative_path, "relative_path") } {
        Ok(value) => value,
        Err(error) => return graph_error_result(request_id, 0, &error),
    };
    let depth = match depth {
        ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP => LocalGraphDepth::OneHop,
        ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP => LocalGraphDepth::TwoHop,
        _ => {
            return graph_error_result(
                request_id,
                read_generation(handle),
                &ReadApiError::InvalidInput("depth"),
            );
        }
    };
    let generation = read_generation(handle);
    match catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { read_handle(handle)?.as_ref() };
        handle.api.local_graph_for_path(
            &relative_path,
            LocalGraphRequest::with_depth(request_id, max_nodes, max_edges, depth),
        )
    })) {
        Ok(Ok(graph)) => EngineReadLocalGraphResult {
            nodes: read_items_buffer(
                ENGINE_READ_ROW_KIND_GRAPH_NODE,
                graph.request_id,
                graph.generation,
                read_state_code(graph.state),
                None,
                &graph.value.nodes,
                EngineReadGraphNodeRow::from_node,
            ),
            edges: read_items_buffer(
                ENGINE_READ_ROW_KIND_GRAPH_EDGE,
                graph.request_id,
                graph.generation,
                read_state_code(graph.state),
                None,
                &graph.value.edges,
                EngineReadGraphEdgeRow::from_edge,
            ),
        },
        Ok(Err(error)) => graph_error_result(request_id, generation, &error),
        Err(_) => graph_error_result(request_id, generation, &ReadApiError::InvalidInput("panic")),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn engine_read_live_preview_metadata(
    handle: *mut EngineReadHandle,
    request_id: u64,
    relative_path: *const c_char,
    contents: *const c_uchar,
    contents_len: usize,
) -> EngineReadResultBuffer {
    let relative_path = match unsafe { read_read_string(relative_path, "relative_path") } {
        Ok(value) => value,
        Err(error) => {
            return read_api_error_buffer(
                ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
                request_id,
                0,
                &error,
            );
        }
    };
    let contents = match unsafe { read_bytes(contents, contents_len, "contents") } {
        Ok(value) => value,
        Err(_) => {
            return read_api_error_buffer(
                ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
                request_id,
                0,
                &ReadApiError::InvalidInput("contents"),
            );
        }
    };
    let contents = match std::str::from_utf8(contents) {
        Ok(value) => value,
        Err(_) => {
            return read_api_error_buffer(
                ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
                request_id,
                0,
                &ReadApiError::InvalidInput("contents"),
            );
        }
    };
    read_page_response(
        handle,
        ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
        request_id,
        |api| api.live_preview_metadata(request_id, &relative_path, contents),
        EngineReadLivePreviewMetadataRow::from_item,
    )
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

impl EngineReadHandle {
    fn open(
        metadata_path: impl AsRef<std::path::Path>,
        tantivy_path: impl AsRef<std::path::Path>,
    ) -> Result<Self, ReadOpenError> {
        Ok(Self {
            api: open_vault_read_api(metadata_path, tantivy_path)?,
        })
    }

    fn generation(&self) -> u64 {
        self.api.generation()
    }
}

fn read_open_response<F>(call: F) -> EngineReadOpenResult
where
    F: FnOnce() -> Result<EngineReadHandle, ReadOpenError>,
{
    match catch_unwind(AssertUnwindSafe(call)).unwrap_or(Err(ReadOpenError::Panic)) {
        Ok(handle) => {
            let generation = handle.generation();
            EngineReadOpenResult {
                handle: Box::into_raw(Box::new(handle)),
                result: open_status_buffer(generation, ENGINE_READ_STATE_COMPLETE),
            }
        }
        Err(error) => EngineReadOpenResult {
            handle: std::ptr::null_mut(),
            result: open_error_buffer(&error),
        },
    }
}

fn read_page_response<T, Row, Call, BuildRow>(
    handle: *mut EngineReadHandle,
    row_kind: u32,
    request_id: u64,
    call: Call,
    build_row: BuildRow,
) -> EngineReadResultBuffer
where
    Row: Copy,
    Call: FnOnce(&VaultReadApi) -> Result<ReadPage<T>, ReadApiError>,
    BuildRow: Fn(&mut EngineReadResultBuilder, &T) -> Row,
{
    let generation = read_generation(handle);
    match catch_unwind(AssertUnwindSafe(|| {
        let handle = unsafe { read_handle(handle)?.as_ref() };
        call(&handle.api)
    })) {
        Ok(Ok(page)) => read_items_buffer(
            row_kind,
            page.request_id,
            page.generation,
            read_state_code(page.state),
            page.next_offset.map(|offset| offset as u64),
            &page.items,
            build_row,
        ),
        Ok(Err(error)) => read_api_error_buffer(row_kind, request_id, generation, &error),
        Err(_) => read_api_error_buffer(
            row_kind,
            request_id,
            generation,
            &ReadApiError::InvalidInput("panic"),
        ),
    }
}

fn read_items_buffer<T, Row, BuildRow>(
    row_kind: u32,
    request_id: u64,
    generation: u64,
    state: u32,
    next_offset: Option<u64>,
    items: &[T],
    build_row: BuildRow,
) -> EngineReadResultBuffer
where
    Row: Copy,
    BuildRow: Fn(&mut EngineReadResultBuilder, &T) -> Row,
{
    let mut builder =
        EngineReadResultBuilder::new(row_kind, request_id, generation, state, next_offset);
    for item in items {
        let row = build_row(&mut builder, item);
        builder.push_row(&row);
    }
    builder.finish()
}

fn graph_error_result(
    request_id: u64,
    generation: u64,
    error: &ReadApiError,
) -> EngineReadLocalGraphResult {
    EngineReadLocalGraphResult {
        nodes: read_api_error_buffer(
            ENGINE_READ_ROW_KIND_GRAPH_NODE,
            request_id,
            generation,
            error,
        ),
        edges: read_api_error_buffer(
            ENGINE_READ_ROW_KIND_GRAPH_EDGE,
            request_id,
            generation,
            error,
        ),
    }
}

fn read_api_error_buffer(
    row_kind: u32,
    request_id: u64,
    generation: u64,
    error: &ReadApiError,
) -> EngineReadResultBuffer {
    let (code, message) = read_api_error_payload(error);
    error_result_buffer(
        row_kind,
        request_id,
        generation,
        ENGINE_READ_STATE_ERROR,
        code,
        message,
    )
}

fn read_api_error_payload(error: &ReadApiError) -> (&'static str, &'static str) {
    match error {
        ReadApiError::Metadata(_) => ("metadata_error", "metadata read failed"),
        ReadApiError::Search(_) => ("search_error", "search read failed"),
        ReadApiError::InvalidInput("panic") => ("panic", "read ffi panic"),
        ReadApiError::InvalidInput(_) => ("invalid_input", "invalid read input"),
        ReadApiError::NotFound(_) => ("not_found", "read target not found"),
    }
}

fn read_state_code(state: ReadState) -> u32 {
    match state {
        ReadState::Complete => ENGINE_READ_STATE_COMPLETE,
        ReadState::Partial => ENGINE_READ_STATE_PARTIAL,
        ReadState::Stale => ENGINE_READ_STATE_STALE,
        ReadState::Cancelled => ENGINE_READ_STATE_CANCELLED,
        ReadState::Error => ENGINE_READ_STATE_ERROR,
    }
}

fn panel_row_kind(panel: u32) -> u32 {
    match panel {
        ENGINE_READ_INSPECTOR_PANEL_BACKLINKS => ENGINE_READ_ROW_KIND_BACKLINK,
        ENGINE_READ_INSPECTOR_PANEL_OUTGOING => ENGINE_READ_ROW_KIND_OUTGOING_LINK,
        ENGINE_READ_INSPECTOR_PANEL_TAGS => ENGINE_READ_ROW_KIND_TAG,
        ENGINE_READ_INSPECTOR_PANEL_PROPERTIES => ENGINE_READ_ROW_KIND_PROPERTY,
        ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS => ENGINE_READ_ROW_KIND_ATTACHMENT,
        _ => ENGINE_READ_ROW_KIND_PROPERTY,
    }
}

fn read_generation(handle: *mut EngineReadHandle) -> u64 {
    if handle.is_null() {
        return 0;
    }
    unsafe {
        handle
            .as_ref()
            .map(EngineReadHandle::generation)
            .unwrap_or(0)
    }
}

unsafe fn read_handle(
    handle: *mut EngineReadHandle,
) -> Result<NonNull<EngineReadHandle>, ReadApiError> {
    NonNull::new(handle).ok_or(ReadApiError::InvalidInput("handle"))
}

unsafe fn read_read_string(
    ptr: *const c_char,
    field: &'static str,
) -> Result<String, ReadApiError> {
    unsafe { read_c_string(ptr, field) }.map_err(|_| ReadApiError::InvalidInput(field))
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
    use crate::attachments::{
        AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
    };
    use crate::index::{
        AttachmentRecord, FileRecord, HeadingRecord, IndexSchemaMetadata, LinkEdgeRecord,
        MetadataStore, PropertyRecord, TagRecord, TagSource, slugify_heading,
    };
    use crate::parser::PropertyValue;
    use crate::paths::{FileIdentity, lookup_key};
    use crate::read_api::{
        ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
        ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
        ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
        ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP, ENGINE_READ_SEARCH_MODE_BODY,
        ENGINE_READ_SEARCH_MODE_FILE_NAME, READ_BACKEND_NAME, READ_BACKEND_VERSION,
        READ_TOKENIZER_CONFIG,
    };
    use crate::read_ffi::{
        ENGINE_READ_NO_NEXT_OFFSET, ENGINE_READ_ROW_KIND_ATTACHMENT, ENGINE_READ_ROW_KIND_BACKLINK,
        ENGINE_READ_ROW_KIND_FILE_TREE, ENGINE_READ_ROW_KIND_GRAPH_EDGE,
        ENGINE_READ_ROW_KIND_GRAPH_NODE, ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
        ENGINE_READ_ROW_KIND_OPEN_STATUS, ENGINE_READ_ROW_KIND_OUTGOING_LINK,
        ENGINE_READ_ROW_KIND_PROPERTY, ENGINE_READ_ROW_KIND_SEARCH_HIT, ENGINE_READ_ROW_KIND_TAG,
        EngineReadAttachmentRow, EngineReadFileTreeRow, EngineReadGraphNodeRow, EngineReadLinkRow,
        EngineReadLivePreviewMetadataRow, EngineReadPropertyRow, EngineReadSearchHitRow,
        EngineReadTagRow, decode_header_for_test, string_for_test,
    };
    use crate::scanner::{ScanEntry, ScanEntryKind};
    use crate::sqlite_fts::SearchDocument;
    use crate::tantivy_search::TantivySearchIndex;
    use serde_json::Value;
    use std::{fs, path::PathBuf};
    use tempfile::{TempDir, tempdir};

    #[test]
    fn read_handle_constructs_and_drops_without_ffi() {
        let fixture = read_fixture().expect("fixture");
        let handle = EngineReadHandle::open(&fixture.metadata_path, &fixture.tantivy_path)
            .expect("read handle");

        assert_eq!(handle.generation(), 11);
        drop(handle);
    }

    #[test]
    fn engine_read_open_opens_fixture_index_and_returns_status() {
        let fixture = read_fixture().expect("fixture");
        let metadata =
            CString::new(fixture.metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let tantivy =
            CString::new(fixture.tantivy_path.to_string_lossy().as_bytes()).expect("tantivy");

        let response = unsafe { engine_read_open(metadata.as_ptr(), tantivy.as_ptr()) };
        let header = unsafe { take_open_header(response.result) };

        assert!(!response.handle.is_null());
        assert_eq!(header.abi_version, ENGINE_ABI_VERSION);
        assert_eq!(header.row_kind, ENGINE_READ_ROW_KIND_OPEN_STATUS);
        assert_eq!(header.row_count, 0);
        assert_eq!(header.state, ENGINE_READ_STATE_COMPLETE);
        assert_eq!(header.generation, 11);
        assert_eq!(header.next_offset, ENGINE_READ_NO_NEXT_OFFSET);

        unsafe {
            engine_read_close(response.handle);
        }
    }

    #[test]
    fn engine_read_open_invalid_paths_return_error_buffer() {
        let response = unsafe { engine_read_open(std::ptr::null(), std::ptr::null()) };
        let (header, error_code) = unsafe { take_open_error(response.result) };

        assert!(response.handle.is_null());
        assert_eq!(header.state, crate::read_api::ENGINE_READ_STATE_ERROR);
        assert_eq!(error_code, "invalid_input");
    }

    #[test]
    fn engine_read_close_and_result_free_are_null_safe() {
        unsafe {
            engine_read_close(std::ptr::null_mut());
            engine_read_result_free(EngineReadResultBuffer {
                ptr: std::ptr::null_mut(),
                len: 0,
                capacity: 0,
            });
        }
    }

    #[test]
    fn read_ffi_panic_boundary_returns_error_buffer() {
        let response = read_open_response(|| panic!("test panic"));
        let (_header, error_code) = unsafe { take_open_error(response.result) };

        assert!(response.handle.is_null());
        assert_eq!(error_code, "panic");
    }

    #[test]
    fn engine_read_file_tree_decodes_complete_and_partial_buffers() {
        let fixture = read_fixture().expect("fixture");
        let handle = open_fixture_handle(&fixture);

        let partial = unsafe { engine_read_file_tree(handle, 101, 0, 2) };
        let partial_header = decode_header_for_test(&partial);
        assert_eq!(partial_header.row_kind, ENGINE_READ_ROW_KIND_FILE_TREE);
        assert_eq!(partial_header.request_id, 101);
        assert_eq!(partial_header.state, ENGINE_READ_STATE_PARTIAL);
        assert_eq!(partial_header.row_count, 2);
        assert_eq!(partial_header.next_offset, 2);
        let first: EngineReadFileTreeRow = unsafe { row_at(&partial, 0) };
        assert_eq!(
            string_for_test(&partial, first.relative_path),
            "Docs/Guide.md"
        );
        unsafe { engine_read_result_free(partial) };

        let complete = unsafe { engine_read_file_tree(handle, 102, 0, 10) };
        let complete_header = decode_header_for_test(&complete);
        assert_eq!(complete_header.state, ENGINE_READ_STATE_COMPLETE);
        assert_eq!(complete_header.row_count, 3);
        assert_eq!(complete_header.next_offset, ENGINE_READ_NO_NEXT_OFFSET);
        unsafe { engine_read_result_free(complete) };
        unsafe { engine_read_close(handle) };
    }

    #[test]
    fn engine_read_search_decodes_modes_empty_query_and_pagination() {
        let fixture = read_fixture().expect("fixture");
        let handle = open_fixture_handle(&fixture);
        let home_query = CString::new("Home").expect("query");
        let body_query = CString::new("compatibility").expect("query");
        let broad_query = CString::new("body").expect("query");
        let empty_query = CString::new("!!!").expect("query");

        let file_name = unsafe {
            engine_read_search(
                handle,
                201,
                ENGINE_READ_SEARCH_MODE_FILE_NAME,
                home_query.as_ptr(),
                0,
                10,
            )
        };
        let file_name_header = decode_header_for_test(&file_name);
        assert_eq!(file_name_header.row_kind, ENGINE_READ_ROW_KIND_SEARCH_HIT);
        assert_eq!(file_name_header.state, ENGINE_READ_STATE_COMPLETE);
        let row: EngineReadSearchHitRow = unsafe { row_at(&file_name, 0) };
        assert_eq!(string_for_test(&file_name, row.title), "Home");
        unsafe { engine_read_result_free(file_name) };

        let body = unsafe {
            engine_read_search(
                handle,
                202,
                ENGINE_READ_SEARCH_MODE_BODY,
                body_query.as_ptr(),
                0,
                10,
            )
        };
        let body_row: EngineReadSearchHitRow = unsafe { row_at(&body, 0) };
        assert_eq!(string_for_test(&body, body_row.relative_path), "Home.md");
        unsafe { engine_read_result_free(body) };

        let paged = unsafe {
            engine_read_search(
                handle,
                203,
                ENGINE_READ_SEARCH_MODE_BODY,
                broad_query.as_ptr(),
                0,
                1,
            )
        };
        let paged_header = decode_header_for_test(&paged);
        assert_eq!(paged_header.state, ENGINE_READ_STATE_PARTIAL);
        assert_eq!(paged_header.next_offset, 1);
        unsafe { engine_read_result_free(paged) };

        let empty = unsafe {
            engine_read_search(
                handle,
                204,
                ENGINE_READ_SEARCH_MODE_BODY,
                empty_query.as_ptr(),
                0,
                10,
            )
        };
        let empty_header = decode_header_for_test(&empty);
        assert_eq!(empty_header.state, ENGINE_READ_STATE_ERROR);
        assert_eq!(empty_header.row_count, 0);
        unsafe { engine_read_result_free(empty) };
        unsafe { engine_read_close(handle) };
    }

    #[test]
    fn engine_read_inspector_panels_decode_rows_and_errors() {
        let fixture = read_fixture().expect("fixture");
        let handle = open_fixture_handle(&fixture);
        let home = CString::new("Home.md").expect("relative path");

        let backlinks = unsafe {
            engine_read_inspector_panel(
                handle,
                301,
                home.as_ptr(),
                ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
                0,
                1,
            )
        };
        let backlink_header = decode_header_for_test(&backlinks);
        assert_eq!(backlink_header.row_kind, ENGINE_READ_ROW_KIND_BACKLINK);
        assert_eq!(backlink_header.row_count, 1);
        assert_eq!(backlink_header.state, ENGINE_READ_STATE_PARTIAL);
        assert_eq!(backlink_header.next_offset, 1);
        let backlink: EngineReadLinkRow = unsafe { row_at(&backlinks, 0) };
        assert_eq!(
            string_for_test(&backlinks, backlink.source_relative_path),
            "Docs/Guide.md"
        );
        unsafe { engine_read_result_free(backlinks) };

        let outgoing = unsafe {
            engine_read_inspector_panel(
                handle,
                302,
                home.as_ptr(),
                ENGINE_READ_INSPECTOR_PANEL_OUTGOING,
                0,
                1,
            )
        };
        let outgoing_header = decode_header_for_test(&outgoing);
        assert_eq!(outgoing_header.row_kind, ENGINE_READ_ROW_KIND_OUTGOING_LINK);
        assert_eq!(outgoing_header.state, ENGINE_READ_STATE_PARTIAL);
        let outgoing_row: EngineReadLinkRow = unsafe { row_at(&outgoing, 0) };
        assert_eq!(
            string_for_test(&outgoing, outgoing_row.target_text),
            "Folder/Target"
        );
        unsafe { engine_read_result_free(outgoing) };

        let tags = unsafe {
            engine_read_inspector_panel(
                handle,
                303,
                home.as_ptr(),
                ENGINE_READ_INSPECTOR_PANEL_TAGS,
                0,
                10,
            )
        };
        let tag: EngineReadTagRow = unsafe { row_at(&tags, 0) };
        assert_eq!(
            decode_header_for_test(&tags).row_kind,
            ENGINE_READ_ROW_KIND_TAG
        );
        assert_eq!(string_for_test(&tags, tag.tag), "project/native");
        unsafe { engine_read_result_free(tags) };

        let properties = unsafe {
            engine_read_inspector_panel(
                handle,
                304,
                home.as_ptr(),
                ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
                0,
                10,
            )
        };
        assert_eq!(
            decode_header_for_test(&properties).row_kind,
            ENGINE_READ_ROW_KIND_PROPERTY
        );
        let property_header = decode_header_for_test(&properties);
        let has_status = (0..property_header.row_count).any(|index| {
            let row: EngineReadPropertyRow = unsafe { row_at(&properties, index as usize) };
            string_for_test(&properties, row.key) == "status"
                && string_for_test(&properties, row.display_value) == "active"
        });
        assert!(has_status);
        unsafe { engine_read_result_free(properties) };

        let attachments = unsafe {
            engine_read_inspector_panel(
                handle,
                305,
                home.as_ptr(),
                ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS,
                0,
                10,
            )
        };
        let attachment_header = decode_header_for_test(&attachments);
        assert_eq!(attachment_header.row_kind, ENGINE_READ_ROW_KIND_ATTACHMENT);
        assert_eq!(attachment_header.row_count, 6);
        let states = (0..attachment_header.row_count)
            .map(|index| unsafe { row_at::<EngineReadAttachmentRow>(&attachments, index as usize) }.state_kind)
            .collect::<Vec<_>>();
        assert!(states.contains(&1));
        assert!(states.contains(&2));
        assert!(states.contains(&3));
        assert!(states.contains(&4));
        assert!(states.contains(&5));
        assert!(states.contains(&6));
        unsafe { engine_read_result_free(attachments) };

        let unknown = unsafe { engine_read_inspector_panel(handle, 306, home.as_ptr(), 99, 0, 10) };
        let unknown_header = decode_header_for_test(&unknown);
        assert_eq!(unknown_header.state, ENGINE_READ_STATE_ERROR);
        assert_eq!(
            string_for_test(&unknown, unknown_header.error_code),
            "invalid_input"
        );
        unsafe { engine_read_result_free(unknown) };
        unsafe { engine_read_close(handle) };
    }

    #[test]
    fn engine_read_local_graph_decodes_one_hop_two_hop_and_partial_caps() {
        let fixture = read_fixture().expect("fixture");
        let handle = open_fixture_handle(&fixture);
        let home = CString::new("Home.md").expect("relative path");

        let one_hop = unsafe {
            engine_read_local_graph(
                handle,
                401,
                home.as_ptr(),
                ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
                10,
                10,
            )
        };
        let one_nodes = decode_header_for_test(&one_hop.nodes);
        let one_edges = decode_header_for_test(&one_hop.edges);
        assert_eq!(one_nodes.row_kind, ENGINE_READ_ROW_KIND_GRAPH_NODE);
        assert_eq!(one_edges.row_kind, ENGINE_READ_ROW_KIND_GRAPH_EDGE);
        assert_eq!(one_nodes.row_count, 4);
        assert_eq!(one_edges.row_count, 4);
        let center: EngineReadGraphNodeRow = unsafe { row_at(&one_hop.nodes, 0) };
        assert_eq!(center.node_kind, 1);
        unsafe {
            engine_read_result_free(one_hop.nodes);
            engine_read_result_free(one_hop.edges);
        }

        let two_hop = unsafe {
            engine_read_local_graph(
                handle,
                402,
                home.as_ptr(),
                ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP,
                10,
                10,
            )
        };
        let two_nodes = decode_header_for_test(&two_hop.nodes);
        assert!(two_nodes.row_count >= 4);
        let has_guide = (0..two_nodes.row_count).any(|index| {
            let row: EngineReadGraphNodeRow = unsafe { row_at(&two_hop.nodes, index as usize) };
            string_for_test(&two_hop.nodes, row.label) == "Docs/Guide.md"
        });
        assert!(has_guide);
        unsafe {
            engine_read_result_free(two_hop.nodes);
            engine_read_result_free(two_hop.edges);
        }

        let capped = unsafe {
            engine_read_local_graph(
                handle,
                403,
                home.as_ptr(),
                ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
                2,
                10,
            )
        };
        assert_eq!(
            decode_header_for_test(&capped.nodes).state,
            ENGINE_READ_STATE_PARTIAL
        );
        unsafe {
            engine_read_result_free(capped.nodes);
            engine_read_result_free(capped.edges);
            engine_read_close(handle);
        }
    }

    #[test]
    fn engine_read_live_preview_metadata_uses_buffer_without_vault_scan() {
        let fixture = read_fixture().expect("fixture");
        let handle = open_fixture_handle(&fixture);
        let home = CString::new("Home.md").expect("relative path");
        let contents = b"---\nstatus: draft\ntags: [project/native]\n---\n# Title\n[[Folder/Target|Target]] ![[attachments/diagram.svg]] [Guide](Docs/Guide.md)\n";

        let buffer = unsafe {
            engine_read_live_preview_metadata(
                handle,
                501,
                home.as_ptr(),
                contents.as_ptr(),
                contents.len(),
            )
        };
        let header = decode_header_for_test(&buffer);
        assert_eq!(header.row_kind, ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA);
        assert_eq!(header.state, ENGINE_READ_STATE_COMPLETE);
        assert!(header.row_count >= 5);

        let mut saw_property = false;
        let mut saw_resolved_link = false;
        let mut saw_resolved_attachment = false;
        for index in 0..header.row_count {
            let row: EngineReadLivePreviewMetadataRow = unsafe { row_at(&buffer, index as usize) };
            let key = string_for_test(&buffer, row.key);
            let value = string_for_test(&buffer, row.value);
            let resolved = string_for_test(&buffer, row.resolved_relative_path);
            saw_property |= key == "status" && value == "draft";
            saw_resolved_link |=
                row.item_kind == 3 && value == "Folder/Target" && resolved == "Folder/Target.md";
            saw_resolved_attachment |= row.item_kind == 4
                && value == "attachments/diagram.svg"
                && resolved == "attachments/diagram.svg";
        }
        assert!(saw_property);
        assert!(saw_resolved_link);
        assert!(saw_resolved_attachment);
        unsafe {
            engine_read_result_free(buffer);
            engine_read_close(handle);
        }
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

    unsafe fn take_open_header(
        buffer: EngineReadResultBuffer,
    ) -> crate::read_ffi::EngineReadResultHeader {
        assert!(!buffer.ptr.is_null());
        let header = decode_header_for_test(&buffer);
        unsafe {
            engine_read_result_free(buffer);
        }
        header
    }

    unsafe fn take_open_error(
        buffer: EngineReadResultBuffer,
    ) -> (crate::read_ffi::EngineReadResultHeader, String) {
        assert!(!buffer.ptr.is_null());
        let header = decode_header_for_test(&buffer);
        let error_code = string_for_test(&buffer, header.error_code);
        unsafe {
            engine_read_result_free(buffer);
        }
        (header, error_code)
    }

    unsafe fn row_at<T: Copy>(buffer: &EngineReadResultBuffer, index: usize) -> T {
        let header = decode_header_for_test(buffer);
        assert!(index < header.row_count as usize);
        assert_eq!(header.row_stride as usize, std::mem::size_of::<T>());
        let offset = header.rows_offset as usize + index * header.row_stride as usize;
        assert!(offset + std::mem::size_of::<T>() <= buffer.len);
        unsafe { std::ptr::read_unaligned(buffer.ptr.add(offset).cast::<T>()) }
    }

    fn open_fixture_handle(fixture: &ReadFixture) -> *mut EngineReadHandle {
        let metadata =
            CString::new(fixture.metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let tantivy =
            CString::new(fixture.tantivy_path.to_string_lossy().as_bytes()).expect("tantivy");
        let response = unsafe { engine_read_open(metadata.as_ptr(), tantivy.as_ptr()) };
        assert!(!response.handle.is_null());
        unsafe {
            engine_read_result_free(response.result);
        }
        response.handle
    }

    struct ReadFixture {
        _dir: TempDir,
        metadata_path: std::path::PathBuf,
        tantivy_path: std::path::PathBuf,
    }

    fn read_fixture() -> Result<ReadFixture, Box<dyn std::error::Error>> {
        let dir = tempdir()?;
        let metadata_path = dir.path().join("metadata.sqlite");
        let tantivy_path = dir.path().join("tantivy");
        let metadata = IndexSchemaMetadata::new(
            READ_BACKEND_NAME,
            READ_BACKEND_VERSION,
            READ_TOKENIZER_CONFIG,
            11,
        );
        let mut store = MetadataStore::open(&metadata_path, &metadata)?;
        let mut home =
            FileRecord::from_scan_entry(&fixture_entry("Home.md", ScanEntryKind::Markdown), 11);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(
            &fixture_entry("Folder/Target.md", ScanEntryKind::Markdown),
            11,
        );
        target.mark_search_indexed();
        let mut guide = FileRecord::from_scan_entry(
            &fixture_entry("Docs/Guide.md", ScanEntryKind::Markdown),
            11,
        );
        guide.mark_search_indexed();
        let mut diagram = FileRecord::from_scan_entry(
            &fixture_entry("attachments/diagram.svg", ScanEntryKind::Attachment),
            11,
        );
        diagram.mark_search_indexed();

        let home_links = [
            LinkEdgeRecord {
                source_file_id: home.file_id.clone(),
                target_text: "Folder/Target".to_string(),
                resolved_target_file_id: Some(target.file_id.clone()),
                heading: Some("Details".to_string()),
                alias: None,
                is_embed: false,
            },
            LinkEdgeRecord {
                source_file_id: home.file_id.clone(),
                target_text: "Missing Note".to_string(),
                resolved_target_file_id: None,
                heading: None,
                alias: Some("Missing".to_string()),
                is_embed: false,
            },
        ];
        let target_links = [
            LinkEdgeRecord {
                source_file_id: target.file_id.clone(),
                target_text: "Home".to_string(),
                resolved_target_file_id: Some(home.file_id.clone()),
                heading: None,
                alias: Some("Home alias".to_string()),
                is_embed: true,
            },
            LinkEdgeRecord {
                source_file_id: target.file_id.clone(),
                target_text: "Docs/Guide".to_string(),
                resolved_target_file_id: Some(guide.file_id.clone()),
                heading: None,
                alias: None,
                is_embed: false,
            },
        ];
        let guide_links = [LinkEdgeRecord {
            source_file_id: guide.file_id.clone(),
            target_text: "Home".to_string(),
            resolved_target_file_id: Some(home.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        }];
        let tags = [TagRecord {
            file_id: home.file_id.clone(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        }];
        let properties = [
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "status",
                &PropertyValue::String("active".to_string()),
            ),
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "flags",
                &PropertyValue::List(vec!["swift".to_string(), "rust".to_string()]),
            ),
        ];
        let headings = [HeadingRecord {
            file_id: home.file_id.clone(),
            slug: slugify_heading("Home"),
            title: "Home".to_string(),
            level: 1,
            byte_offset: Some(0),
        }];
        let attachments = [
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "attachments/diagram.svg".to_string(),
                state: AttachmentResolutionState::Resolved {
                    relative_path: PathBuf::from("attachments/diagram.svg"),
                },
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownImage,
                raw_target: "missing.png".to_string(),
                state: AttachmentResolutionState::Missing,
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "duplicate.png".to_string(),
                state: AttachmentResolutionState::Duplicate {
                    candidates: vec![
                        PathBuf::from("a/duplicate.png"),
                        PathBuf::from("b/duplicate.png"),
                    ],
                },
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownLink,
                raw_target: "https://example.com/image.png".to_string(),
                state: AttachmentResolutionState::Remote,
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownImage,
                raw_target: "/tmp/secret.png".to_string(),
                state: AttachmentResolutionState::Rejected(AttachmentRejectReason::AbsolutePath),
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "Other".to_string(),
                state: AttachmentResolutionState::Unsupported,
            },
        ];

        store.replace_file_records(
            &home,
            &home_links,
            &tags,
            &properties,
            &headings,
            &attachments,
        )?;
        store.replace_file_records(&target, &target_links, &[], &[], &[], &[])?;
        store.replace_file_records(&guide, &guide_links, &[], &[], &[], &[])?;
        store.replace_file_records(&diagram, &[], &[], &[], &[], &[])?;
        drop(store);
        let mut index = TantivySearchIndex::open_in_dir(&tantivy_path)?;
        index.replace_documents(&[
            SearchDocument {
                file_id: home.file_id.clone(),
                path: "Home.md".to_string(),
                title: "Home".to_string(),
                body: "Home body mentions compatibility and native search.".to_string(),
            },
            SearchDocument {
                file_id: target.file_id.clone(),
                path: "Folder/Target.md".to_string(),
                title: "Target".to_string(),
                body: "Target body receives backlinks.".to_string(),
            },
            SearchDocument {
                file_id: guide.file_id.clone(),
                path: "Docs/Guide.md".to_string(),
                title: "Guide".to_string(),
                body: "Guide body is a second hop target.".to_string(),
            },
        ])?;
        drop(index);

        Ok(ReadFixture {
            _dir: dir,
            metadata_path,
            tantivy_path,
        })
    }

    fn fixture_entry(relative_path: &str, kind: ScanEntryKind) -> ScanEntry {
        ScanEntry {
            relative_path: PathBuf::from(relative_path),
            kind,
            size_bytes: 10,
            modified: Some(UNIX_EPOCH),
            file_identity: FileIdentity {
                device: 1,
                inode: lookup_key(relative_path).bytes().map(u64::from).sum(),
            },
        }
    }
}
