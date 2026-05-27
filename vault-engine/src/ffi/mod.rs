use std::os::raw::{c_char, c_uchar};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::Path;

use crate::ffi::read_rows::{
    ENGINE_READ_ROW_KIND_ATTACHMENT, ENGINE_READ_ROW_KIND_BACKLINK, ENGINE_READ_ROW_KIND_FILE_TREE,
    ENGINE_READ_ROW_KIND_GRAPH_EDGE, ENGINE_READ_ROW_KIND_GRAPH_NODE,
    ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA, ENGINE_READ_ROW_KIND_OUTGOING_LINK,
    ENGINE_READ_ROW_KIND_PROPERTY, ENGINE_READ_ROW_KIND_SEARCH_HIT, ENGINE_READ_ROW_KIND_TAG,
    EngineReadAttachmentRow, EngineReadFileTreeRow, EngineReadGraphEdgeRow, EngineReadGraphNodeRow,
    EngineReadLinkRow, EngineReadLivePreviewMetadataRow, EngineReadPropertyRow,
    EngineReadResultBuffer, EngineReadSearchHitRow, EngineReadTagRow,
};
use crate::read_api::{
    ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
    ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
    ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
    ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP, LocalGraphDepth, LocalGraphRequest, ReadApiError,
    ReadOpenError, VaultReadApi,
};

mod graph;
mod health;
mod json;
mod lifecycle;
mod panic;
mod read;
pub mod read_rows;
mod save;
mod strings;

pub use self::graph::engine_graph_snapshot;
pub use self::health::abi_version;
pub use self::lifecycle::{engine_read_close, engine_read_result_free, engine_string_free};
use self::read::{
    graph_error_result, panel_row_kind, read_api_error_buffer, read_generation, read_handle,
    read_items_buffer, read_open_response, read_page_response, read_rebuild_response,
    read_state_code, rebuild_read_index,
};
pub use self::save::{
    engine_save_capture_baseline, engine_save_keep_conflict_as_new_note,
    engine_save_overwrite_after_conflict, engine_save_reload_after_conflict, engine_save_write,
};
use self::strings::{read_bytes, read_c_string, read_read_string, read_rebuild_c_string};

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
pub unsafe extern "C" fn engine_read_rebuild_index(
    vault_path: *const c_char,
    data_path: *const c_char,
    rebuild_path: *const c_char,
) -> EngineReadResultBuffer {
    read_rebuild_response(|| {
        let vault_path = unsafe { read_rebuild_c_string(vault_path, "vault_path")? };
        let data_path = unsafe { read_rebuild_c_string(data_path, "data_path")? };
        let rebuild_path = unsafe { read_rebuild_c_string(rebuild_path, "rebuild_path")? };
        rebuild_read_index(
            Path::new(&vault_path),
            Path::new(&data_path),
            Path::new(&rebuild_path),
        )
    })
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ENGINE_ABI_VERSION;
    use crate::adapters::sqlite::{
        AttachmentRecord, FileRecord, HeadingRecord, IndexSchemaMetadata, LinkEdgeRecord,
        MetadataStore, PropertyRecord, TagRecord, TagSource, slugify_heading,
    };
    use crate::attachments::{
        AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
    };
    use crate::ffi::read_rows::{
        ENGINE_READ_NO_NEXT_OFFSET, ENGINE_READ_ROW_KIND_ATTACHMENT, ENGINE_READ_ROW_KIND_BACKLINK,
        ENGINE_READ_ROW_KIND_FILE_TREE, ENGINE_READ_ROW_KIND_GRAPH_EDGE,
        ENGINE_READ_ROW_KIND_GRAPH_NODE, ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
        ENGINE_READ_ROW_KIND_OPEN_STATUS, ENGINE_READ_ROW_KIND_OUTGOING_LINK,
        ENGINE_READ_ROW_KIND_PROPERTY, ENGINE_READ_ROW_KIND_SEARCH_HIT, ENGINE_READ_ROW_KIND_TAG,
        EngineReadAttachmentRow, EngineReadFileTreeRow, EngineReadGraphNodeRow, EngineReadLinkRow,
        EngineReadLivePreviewMetadataRow, EngineReadPropertyRow, EngineReadSearchHitRow,
        EngineReadTagRow, decode_header_for_test, string_for_test,
    };
    use crate::parser::PropertyValue;
    use crate::paths::{FileIdentity, lookup_key};
    use crate::read_api::{
        ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
        ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
        ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
        ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP, ENGINE_READ_SEARCH_MODE_BODY,
        ENGINE_READ_SEARCH_MODE_FILE_NAME, ENGINE_READ_STATE_COMPLETE, ENGINE_READ_STATE_ERROR,
        ENGINE_READ_STATE_PARTIAL, READ_BACKEND_NAME, READ_BACKEND_VERSION, READ_TOKENIZER_CONFIG,
    };
    use crate::scanner::{ScanEntry, ScanEntryKind};
    use crate::sqlite_fts::SearchDocument;
    use crate::tantivy_search::TantivySearchIndex;
    use serde_json::{Value, json};
    use std::{ffi::CString, fs, path::PathBuf, time::UNIX_EPOCH};
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
    fn engine_read_rebuild_index_materializes_missing_read_index() {
        let dir = tempdir().expect("tempdir");
        let vault_path = dir.path().join("vault");
        fs::create_dir_all(&vault_path).expect("vault dir");
        fs::write(
            vault_path.join("Home.md"),
            "# Home\n\nBody with [[Target]] and #tag",
        )
        .expect("home file");
        fs::write(vault_path.join("Target.md"), "# Target\n\nLinked body").expect("target file");
        let index_root = dir.path().join("support").join("Indexes").join("vault-id");
        let data_path = index_root.join("data");
        let rebuild_path = index_root.join("rebuild");
        let vault = CString::new(vault_path.to_string_lossy().as_bytes()).expect("vault");
        let data = CString::new(data_path.to_string_lossy().as_bytes()).expect("data");
        let rebuild = CString::new(rebuild_path.to_string_lossy().as_bytes()).expect("rebuild");

        let buffer =
            unsafe { engine_read_rebuild_index(vault.as_ptr(), data.as_ptr(), rebuild.as_ptr()) };
        let header = unsafe { take_open_header(buffer) };

        assert_eq!(header.row_kind, ENGINE_READ_ROW_KIND_OPEN_STATUS);
        assert_eq!(header.state, ENGINE_READ_STATE_COMPLETE);
        assert!(data_path.join("metadata.sqlite").is_file());
        assert!(data_path.join("tantivy").is_dir());
        assert!(!rebuild_path.exists());

        let metadata = CString::new(
            data_path
                .join("metadata.sqlite")
                .to_string_lossy()
                .as_bytes(),
        )
        .expect("metadata");
        let tantivy =
            CString::new(data_path.join("tantivy").to_string_lossy().as_bytes()).expect("tantivy");
        let response = unsafe { engine_read_open(metadata.as_ptr(), tantivy.as_ptr()) };
        assert!(!response.handle.is_null());
        unsafe {
            engine_read_result_free(response.result);
            engine_read_close(response.handle);
        }
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
    fn ffi_c_string_inputs_reject_null_and_invalid_utf8() {
        let relative_path = CString::new("Home.md").expect("relative path");

        let rebuild = unsafe {
            engine_read_rebuild_index(std::ptr::null(), std::ptr::null(), std::ptr::null())
        };
        let (rebuild_header, rebuild_error) = unsafe { take_open_error(rebuild) };
        assert_eq!(rebuild_header.row_kind, ENGINE_READ_ROW_KIND_OPEN_STATUS);
        assert_eq!(rebuild_error, "invalid_input");

        let graph_response =
            unsafe { take_response(engine_graph_snapshot(std::ptr::null(), std::ptr::null())) };
        assert_json_error_code(graph_response, "invalid_input");

        let capture_response = unsafe {
            take_response(engine_save_capture_baseline(
                std::ptr::null(),
                relative_path.as_ptr(),
            ))
        };
        assert_json_error_code(capture_response, "invalid_input");

        let save_response = unsafe {
            take_response(engine_save_write(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
            ))
        };
        assert_json_error_code(save_response, "invalid_input");

        let reload_response = unsafe {
            take_response(engine_save_reload_after_conflict(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                1,
            ))
        };
        assert_json_error_code(reload_response, "invalid_input");

        let keep_response = unsafe {
            take_response(engine_save_keep_conflict_as_new_note(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                1,
            ))
        };
        assert_json_error_code(keep_response, "invalid_input");

        let overwrite_response = unsafe {
            take_response(engine_save_overwrite_after_conflict(
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                0,
                1,
            ))
        };
        assert_json_error_code(overwrite_response, "invalid_input");

        let invalid_utf8 = [0xff_u8, 0];
        let invalid_path = invalid_utf8.as_ptr().cast::<c_char>();
        let response = unsafe { engine_read_open(invalid_path, invalid_path) };
        let (_header, error_code) = unsafe { take_open_error(response.result) };
        assert!(response.handle.is_null());
        assert_eq!(error_code, "invalid_input");

        let invalid_save_response = unsafe {
            take_response(engine_save_capture_baseline(
                invalid_path,
                relative_path.as_ptr(),
            ))
        };
        assert_json_error_code(invalid_save_response, "invalid_input");
    }

    #[test]
    fn read_ffi_null_handles_return_error_buffers_for_each_surface() {
        let query = CString::new("Home").expect("query");
        let relative_path = CString::new("Home.md").expect("relative path");
        let contents = b"# Home\n";

        let file_tree = unsafe { engine_read_file_tree(std::ptr::null_mut(), 701, 0, 10) };
        let (file_tree_header, file_tree_error) = unsafe { take_open_error(file_tree) };
        assert_eq!(file_tree_header.row_kind, ENGINE_READ_ROW_KIND_FILE_TREE);
        assert_eq!(file_tree_header.request_id, 701);
        assert_eq!(file_tree_error, "invalid_input");

        let search = unsafe {
            engine_read_search(
                std::ptr::null_mut(),
                702,
                ENGINE_READ_SEARCH_MODE_BODY,
                query.as_ptr(),
                0,
                10,
            )
        };
        let (search_header, search_error) = unsafe { take_open_error(search) };
        assert_eq!(search_header.row_kind, ENGINE_READ_ROW_KIND_SEARCH_HIT);
        assert_eq!(search_header.request_id, 702);
        assert_eq!(search_error, "invalid_input");

        let panel = unsafe {
            engine_read_inspector_panel(
                std::ptr::null_mut(),
                703,
                relative_path.as_ptr(),
                ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
                0,
                10,
            )
        };
        let (panel_header, panel_error) = unsafe { take_open_error(panel) };
        assert_eq!(panel_header.row_kind, ENGINE_READ_ROW_KIND_BACKLINK);
        assert_eq!(panel_header.request_id, 703);
        assert_eq!(panel_error, "invalid_input");

        let graph = unsafe {
            engine_read_local_graph(
                std::ptr::null_mut(),
                704,
                relative_path.as_ptr(),
                ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
                10,
                10,
            )
        };
        let (node_header, node_error) = unsafe { take_open_error(graph.nodes) };
        let (edge_header, edge_error) = unsafe { take_open_error(graph.edges) };
        assert_eq!(node_header.row_kind, ENGINE_READ_ROW_KIND_GRAPH_NODE);
        assert_eq!(edge_header.row_kind, ENGINE_READ_ROW_KIND_GRAPH_EDGE);
        assert_eq!(node_header.request_id, 704);
        assert_eq!(edge_header.request_id, 704);
        assert_eq!(node_error, "invalid_input");
        assert_eq!(edge_error, "invalid_input");

        let live_preview = unsafe {
            engine_read_live_preview_metadata(
                std::ptr::null_mut(),
                705,
                relative_path.as_ptr(),
                contents.as_ptr(),
                contents.len(),
            )
        };
        let (live_header, live_error) = unsafe { take_open_error(live_preview) };
        assert_eq!(
            live_header.row_kind,
            ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA
        );
        assert_eq!(live_header.request_id, 705);
        assert_eq!(live_error, "invalid_input");
    }

    #[test]
    fn ffi_byte_inputs_distinguish_null_by_length() {
        let fixture = read_fixture().expect("fixture");
        let handle = open_fixture_handle(&fixture);
        let relative_path = CString::new("Home.md").expect("relative path");

        let rejected = unsafe {
            engine_read_live_preview_metadata(
                handle,
                801,
                relative_path.as_ptr(),
                std::ptr::null(),
                1,
            )
        };
        let (rejected_header, rejected_error) = unsafe { take_open_error(rejected) };
        assert_eq!(
            rejected_header.row_kind,
            ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA
        );
        assert_eq!(rejected_error, "invalid_input");

        let accepted = unsafe {
            engine_read_live_preview_metadata(
                handle,
                802,
                relative_path.as_ptr(),
                std::ptr::null(),
                0,
            )
        };
        let accepted_header = decode_header_for_test(&accepted);
        assert_eq!(accepted_header.state, ENGINE_READ_STATE_COMPLETE);
        unsafe {
            engine_read_result_free(accepted);
            engine_read_close(handle);
        }

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

        let rejected_save = unsafe {
            take_response(engine_save_write(
                vault.as_ptr(),
                baseline_json.as_ptr(),
                std::ptr::null(),
                1,
            ))
        };
        assert_json_error_code(rejected_save, "invalid_input");

        let empty_save = unsafe {
            take_response(engine_save_write(
                vault.as_ptr(),
                baseline_json.as_ptr(),
                std::ptr::null(),
                0,
            ))
        };
        let empty: Value = serde_json::from_str(&empty_save).expect("empty save json");
        assert_eq!(empty["ok"], true);
        assert_eq!(empty["value"]["bytes_written"], 0);
        assert_eq!(fs::read(&note).expect("empty contents"), b"");
    }

    #[test]
    fn ffi_panic_payloads_remain_structured() {
        let json_response = unsafe {
            take_response(json::ffi_response::<Value, _>(
                || -> Result<Value, json::FfiError> { panic!("test panic") },
            ))
        };
        assert_json_error_code(json_response, "panic");

        let graph = graph_error_result(901, 0, &ReadApiError::InvalidInput("panic"));
        let (_node_header, node_error) = unsafe { take_open_error(graph.nodes) };
        let (_edge_header, edge_error) = unsafe { take_open_error(graph.edges) };
        assert_eq!(node_error, "panic");
        assert_eq!(edge_error, "panic");
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
    fn engine_graph_snapshot_returns_payload_and_errors() {
        let fixture = read_fixture().expect("fixture");
        let metadata =
            CString::new(fixture.metadata_path.to_string_lossy().as_bytes()).expect("metadata");
        let request = CString::new(
            json!({
                "payload_version": 1,
                "request_id": 601,
                "generation": 0,
                "include_unresolved": true,
                "include_orphans": true,
                "max_nodes": 10,
                "max_edges": 10,
                "byte_cap_bytes": 1_000_000
            })
            .to_string(),
        )
        .expect("request");

        let response =
            unsafe { take_response(engine_graph_snapshot(metadata.as_ptr(), request.as_ptr())) };
        let value: Value = serde_json::from_str(&response).expect("graph response");

        assert_eq!(value["ok"], true);
        assert_eq!(value["value"]["payload_version"], 1);
        assert_eq!(value["value"]["request_id"], 601);
        assert_eq!(value["value"]["generation"], 11);
        assert_eq!(value["value"]["state"], "complete");
        assert!(
            value["value"]["metrics"]["encoded_payload_bytes"]
                .as_u64()
                .expect("encoded bytes")
                > 0
        );
        assert!(
            value["value"]["snapshot"]["nodes"]
                .as_array()
                .expect("nodes")
                .len()
                >= 3
        );

        let invalid_request = CString::new(
            json!({
                "payload_version": 1,
                "request_id": 602,
                "generation": 0,
                "include_unresolved": true,
                "include_orphans": true,
                "max_nodes": 10,
                "max_edges": 10,
                "byte_cap_bytes": 0
            })
            .to_string(),
        )
        .expect("invalid request");
        let error_response = unsafe {
            take_response(engine_graph_snapshot(
                metadata.as_ptr(),
                invalid_request.as_ptr(),
            ))
        };
        let error: Value = serde_json::from_str(&error_response).expect("graph error");

        assert_eq!(error["ok"], false);
        assert_eq!(error["error"]["code"], "invalid_request");
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
        let value = unsafe { std::ffi::CStr::from_ptr(ptr) }
            .to_string_lossy()
            .into_owned();
        unsafe {
            engine_string_free(ptr);
        }
        value
    }

    fn assert_json_error_code(response: String, expected_code: &str) {
        let value: Value = serde_json::from_str(&response).expect("error json");
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], expected_code);
    }

    unsafe fn take_open_header(
        buffer: EngineReadResultBuffer,
    ) -> crate::ffi::read_rows::EngineReadResultHeader {
        assert!(!buffer.ptr.is_null());
        let header = decode_header_for_test(&buffer);
        unsafe {
            engine_read_result_free(buffer);
        }
        header
    }

    unsafe fn take_open_error(
        buffer: EngineReadResultBuffer,
    ) -> (crate::ffi::read_rows::EngineReadResultHeader, String) {
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
