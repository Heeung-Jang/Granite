use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;
use std::ptr::NonNull;

use crate::index_rebuild::IndexRebuildPaths;
use crate::indexing_pipeline::{
    IndexingPipelineOptions, load_search_document_sources, run_full_rebuild_pipeline_and_commit,
};
use crate::paths::VaultRoot;
use crate::read_api::{
    ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
    ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
    ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_STATE_CANCELLED, ENGINE_READ_STATE_COMPLETE,
    ENGINE_READ_STATE_ERROR, ENGINE_READ_STATE_PARTIAL, ENGINE_READ_STATE_STALE, ReadApiError,
    ReadOpenError, ReadPage, ReadState, VaultReadApi, expected_read_schema_metadata,
    open_vault_read_api,
};
use crate::read_ffi::{
    ENGINE_READ_ROW_KIND_ATTACHMENT, ENGINE_READ_ROW_KIND_BACKLINK,
    ENGINE_READ_ROW_KIND_GRAPH_EDGE, ENGINE_READ_ROW_KIND_GRAPH_NODE,
    ENGINE_READ_ROW_KIND_OPEN_STATUS, ENGINE_READ_ROW_KIND_OUTGOING_LINK,
    ENGINE_READ_ROW_KIND_PROPERTY, ENGINE_READ_ROW_KIND_TAG, EngineReadResultBuffer,
    EngineReadResultBuilder, error_result_buffer, open_error_buffer, open_status_buffer,
};

use super::{EngineReadHandle, EngineReadLocalGraphResult, EngineReadOpenResult};

impl EngineReadHandle {
    pub(super) fn open(
        metadata_path: impl AsRef<std::path::Path>,
        tantivy_path: impl AsRef<std::path::Path>,
    ) -> Result<Self, ReadOpenError> {
        Ok(Self {
            api: open_vault_read_api(metadata_path, tantivy_path)?,
        })
    }

    pub(super) fn generation(&self) -> u64 {
        self.api.generation()
    }
}

pub(super) fn read_open_response<F>(call: F) -> EngineReadOpenResult
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ReadRebuildFfiError {
    code: &'static str,
    message: String,
}

impl ReadRebuildFfiError {
    pub(super) fn invalid_input(field: &'static str) -> Self {
        Self {
            code: "invalid_input",
            message: format!("{field}: invalid path"),
        }
    }

    fn rebuild_failed(error: impl std::fmt::Display) -> Self {
        Self {
            code: "rebuild_failed",
            message: error.to_string(),
        }
    }

    fn panic() -> Self {
        Self {
            code: "panic",
            message: "vault engine FFI call panicked".to_string(),
        }
    }
}

pub(super) fn read_rebuild_response<F>(call: F) -> EngineReadResultBuffer
where
    F: FnOnce() -> Result<u64, ReadRebuildFfiError>,
{
    match catch_unwind(AssertUnwindSafe(call)).unwrap_or_else(|_| Err(ReadRebuildFfiError::panic()))
    {
        Ok(generation) => open_status_buffer(generation, ENGINE_READ_STATE_COMPLETE),
        Err(error) => error_result_buffer(
            ENGINE_READ_ROW_KIND_OPEN_STATUS,
            0,
            0,
            ENGINE_READ_STATE_ERROR,
            error.code,
            &error.message,
        ),
    }
}

pub(super) fn rebuild_read_index(
    vault_path: &Path,
    data_path: &Path,
    rebuild_path: &Path,
) -> Result<u64, ReadRebuildFfiError> {
    let root = VaultRoot::open(vault_path).map_err(ReadRebuildFfiError::rebuild_failed)?;
    let index_root = data_path
        .parent()
        .ok_or_else(|| ReadRebuildFfiError::invalid_input("data_path"))?;
    let paths = IndexRebuildPaths::new(root.canonical_root(), index_root, data_path, rebuild_path);
    let loaded =
        load_search_document_sources(&root).map_err(ReadRebuildFfiError::rebuild_failed)?;
    let metadata = expected_read_schema_metadata();
    let result = run_full_rebuild_pipeline_and_commit(
        &paths,
        &loaded.sources,
        &metadata,
        &IndexingPipelineOptions::default(),
    )
    .map_err(ReadRebuildFfiError::rebuild_failed)?;

    Ok(result.generation)
}

pub(super) fn read_page_response<T, Row, Call, BuildRow>(
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

pub(super) fn read_items_buffer<T, Row, BuildRow>(
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

pub(super) fn graph_error_result(
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

pub(super) fn read_api_error_buffer(
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

pub(super) fn read_state_code(state: ReadState) -> u32 {
    match state {
        ReadState::Complete => ENGINE_READ_STATE_COMPLETE,
        ReadState::Partial => ENGINE_READ_STATE_PARTIAL,
        ReadState::Stale => ENGINE_READ_STATE_STALE,
        ReadState::Cancelled => ENGINE_READ_STATE_CANCELLED,
        ReadState::Error => ENGINE_READ_STATE_ERROR,
    }
}

pub(super) fn panel_row_kind(panel: u32) -> u32 {
    match panel {
        ENGINE_READ_INSPECTOR_PANEL_BACKLINKS => ENGINE_READ_ROW_KIND_BACKLINK,
        ENGINE_READ_INSPECTOR_PANEL_OUTGOING => ENGINE_READ_ROW_KIND_OUTGOING_LINK,
        ENGINE_READ_INSPECTOR_PANEL_TAGS => ENGINE_READ_ROW_KIND_TAG,
        ENGINE_READ_INSPECTOR_PANEL_PROPERTIES => ENGINE_READ_ROW_KIND_PROPERTY,
        ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS => ENGINE_READ_ROW_KIND_ATTACHMENT,
        _ => ENGINE_READ_ROW_KIND_PROPERTY,
    }
}

pub(super) fn read_generation(handle: *mut EngineReadHandle) -> u64 {
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

pub(super) unsafe fn read_handle(
    handle: *mut EngineReadHandle,
) -> Result<NonNull<EngineReadHandle>, ReadApiError> {
    NonNull::new(handle).ok_or(ReadApiError::InvalidInput("handle"))
}
