use serde::Serialize;
use std::mem::{align_of, offset_of, size_of};
use vault_engine::ENGINE_ABI_VERSION;
use vault_engine::ffi::{EngineReadLocalGraphResult, EngineReadOpenResult};
use vault_engine::read_api::{
    ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
    ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
    ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
    ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP, ENGINE_READ_SEARCH_MODE_BODY,
    ENGINE_READ_SEARCH_MODE_FILE_NAME, ENGINE_READ_STATE_CANCELLED, ENGINE_READ_STATE_COMPLETE,
    ENGINE_READ_STATE_ERROR, ENGINE_READ_STATE_INDEX_UNAVAILABLE, ENGINE_READ_STATE_PARTIAL,
    ENGINE_READ_STATE_STALE, ReadOpenError,
};
use vault_engine::read_ffi::{
    ENGINE_READ_NO_NEXT_OFFSET, ENGINE_READ_ROW_KIND_ATTACHMENT, ENGINE_READ_ROW_KIND_BACKLINK,
    ENGINE_READ_ROW_KIND_FILE_TREE, ENGINE_READ_ROW_KIND_GRAPH_EDGE,
    ENGINE_READ_ROW_KIND_GRAPH_NODE, ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
    ENGINE_READ_ROW_KIND_OPEN_STATUS, ENGINE_READ_ROW_KIND_OUTGOING_LINK,
    ENGINE_READ_ROW_KIND_PROPERTY, ENGINE_READ_ROW_KIND_SEARCH_HIT, ENGINE_READ_ROW_KIND_TAG,
    EngineReadAttachmentRow, EngineReadFileTreeRow, EngineReadGraphEdgeRow, EngineReadGraphNodeRow,
    EngineReadLinkRow, EngineReadLivePreviewMetadataRow, EngineReadPropertyRow,
    EngineReadResultBuffer, EngineReadResultHeader, EngineReadSearchHitRow, EngineReadStringRef,
    EngineReadTagRow,
};

#[derive(Serialize)]
struct AbiManifest {
    schema_version: u32,
    abi_version: u32,
    layouts: Vec<Layout>,
    constants: Vec<Constant>,
    error_codes: Vec<ErrorCode>,
}

#[derive(Serialize)]
struct Layout {
    name: &'static str,
    size: usize,
    align: usize,
    fields: Vec<Field>,
}

#[derive(Serialize)]
struct Field {
    name: &'static str,
    offset: usize,
}

#[derive(Serialize)]
struct Constant {
    name: &'static str,
    value: String,
}

#[derive(Serialize)]
struct ErrorCode {
    group: &'static str,
    code: &'static str,
    numeric_code: Option<u32>,
    state_code: Option<u32>,
}

macro_rules! layout {
    ($ty:ty, $name:literal, [$($field:ident),* $(,)?]) => {
        Layout {
            name: $name,
            size: size_of::<$ty>(),
            align: align_of::<$ty>(),
            fields: vec![
                $(Field {
                    name: stringify!($field),
                    offset: offset_of!($ty, $field),
                }),*
            ],
        }
    };
}

fn main() {
    let manifest = AbiManifest {
        schema_version: 1,
        abi_version: ENGINE_ABI_VERSION,
        layouts: layouts(),
        constants: constants(),
        error_codes: error_codes(),
    };
    println!(
        "{}",
        serde_json::to_string_pretty(&manifest).expect("serialize ABI manifest")
    );
}

fn layouts() -> Vec<Layout> {
    vec![
        layout!(EngineReadStringRef, "EngineReadStringRef", [offset, length]),
        layout!(
            EngineReadResultHeader,
            "EngineReadResultHeader",
            [
                abi_version,
                row_kind,
                request_id,
                generation,
                state,
                row_count,
                row_stride,
                rows_offset,
                string_arena_offset,
                string_arena_length,
                next_offset,
                error_code,
                error_message,
            ]
        ),
        layout!(
            EngineReadResultBuffer,
            "EngineReadResultBuffer",
            [ptr, len, capacity]
        ),
        layout!(
            EngineReadFileTreeRow,
            "EngineReadFileTreeRow",
            [
                relative_path,
                display_name,
                kind,
                status,
                size_bytes,
                modified_unix_ms,
            ]
        ),
        layout!(
            EngineReadSearchHitRow,
            "EngineReadSearchHitRow",
            [file_id, relative_path, title, snippet, rank]
        ),
        layout!(
            EngineReadLinkRow,
            "EngineReadLinkRow",
            [
                source_file_id,
                source_relative_path,
                target_file_id,
                target_relative_path,
                target_text,
                heading,
                alias,
                resolution_state,
                is_embed,
            ]
        ),
        layout!(EngineReadTagRow, "EngineReadTagRow", [file_id, tag, source]),
        layout!(
            EngineReadPropertyRow,
            "EngineReadPropertyRow",
            [file_id, key, display_value, value_kind]
        ),
        layout!(
            EngineReadAttachmentRow,
            "EngineReadAttachmentRow",
            [
                source_file_id,
                raw_target,
                resolved_relative_path,
                source_kind,
                state_kind,
            ]
        ),
        layout!(
            EngineReadGraphNodeRow,
            "EngineReadGraphNodeRow",
            [node_id, file_id, label, node_kind]
        ),
        layout!(
            EngineReadGraphEdgeRow,
            "EngineReadGraphEdgeRow",
            [
                source_node_id,
                target_node_id,
                target_text,
                direction,
                is_embed,
                hop,
            ]
        ),
        layout!(
            EngineReadLivePreviewMetadataRow,
            "EngineReadLivePreviewMetadataRow",
            [
                item_kind,
                key,
                value,
                resolved_file_id,
                resolved_relative_path,
                heading,
                alias,
                state_kind,
                source_kind,
            ]
        ),
        layout!(
            EngineReadOpenResult,
            "EngineReadOpenResult",
            [handle, result]
        ),
        layout!(
            EngineReadLocalGraphResult,
            "EngineReadLocalGraphResult",
            [nodes, edges]
        ),
    ]
}

fn constants() -> Vec<Constant> {
    vec![
        constant("ENGINE_ABI_VERSION", ENGINE_ABI_VERSION),
        constant("ENGINE_READ_NO_NEXT_OFFSET", ENGINE_READ_NO_NEXT_OFFSET),
        constant(
            "ENGINE_READ_ROW_KIND_OPEN_STATUS",
            ENGINE_READ_ROW_KIND_OPEN_STATUS,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_FILE_TREE",
            ENGINE_READ_ROW_KIND_FILE_TREE,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_SEARCH_HIT",
            ENGINE_READ_ROW_KIND_SEARCH_HIT,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_BACKLINK",
            ENGINE_READ_ROW_KIND_BACKLINK,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_OUTGOING_LINK",
            ENGINE_READ_ROW_KIND_OUTGOING_LINK,
        ),
        constant("ENGINE_READ_ROW_KIND_TAG", ENGINE_READ_ROW_KIND_TAG),
        constant(
            "ENGINE_READ_ROW_KIND_PROPERTY",
            ENGINE_READ_ROW_KIND_PROPERTY,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_ATTACHMENT",
            ENGINE_READ_ROW_KIND_ATTACHMENT,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_GRAPH_NODE",
            ENGINE_READ_ROW_KIND_GRAPH_NODE,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_GRAPH_EDGE",
            ENGINE_READ_ROW_KIND_GRAPH_EDGE,
        ),
        constant(
            "ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA",
            ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
        ),
        constant("ENGINE_READ_STATE_COMPLETE", ENGINE_READ_STATE_COMPLETE),
        constant("ENGINE_READ_STATE_PARTIAL", ENGINE_READ_STATE_PARTIAL),
        constant("ENGINE_READ_STATE_STALE", ENGINE_READ_STATE_STALE),
        constant("ENGINE_READ_STATE_CANCELLED", ENGINE_READ_STATE_CANCELLED),
        constant("ENGINE_READ_STATE_ERROR", ENGINE_READ_STATE_ERROR),
        constant(
            "ENGINE_READ_STATE_INDEX_UNAVAILABLE",
            ENGINE_READ_STATE_INDEX_UNAVAILABLE,
        ),
        constant(
            "ENGINE_READ_SEARCH_MODE_FILE_NAME",
            ENGINE_READ_SEARCH_MODE_FILE_NAME,
        ),
        constant("ENGINE_READ_SEARCH_MODE_BODY", ENGINE_READ_SEARCH_MODE_BODY),
        constant(
            "ENGINE_READ_INSPECTOR_PANEL_BACKLINKS",
            ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
        ),
        constant(
            "ENGINE_READ_INSPECTOR_PANEL_OUTGOING",
            ENGINE_READ_INSPECTOR_PANEL_OUTGOING,
        ),
        constant(
            "ENGINE_READ_INSPECTOR_PANEL_TAGS",
            ENGINE_READ_INSPECTOR_PANEL_TAGS,
        ),
        constant(
            "ENGINE_READ_INSPECTOR_PANEL_PROPERTIES",
            ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
        ),
        constant(
            "ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS",
            ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS,
        ),
        constant(
            "ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP",
            ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
        ),
        constant(
            "ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP",
            ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP,
        ),
    ]
}

fn error_codes() -> Vec<ErrorCode> {
    let open_errors = [
        ReadOpenError::MissingMetadata,
        ReadOpenError::CorruptMetadata,
        ReadOpenError::SchemaMismatch {
            stored: 0,
            expected: 1,
        },
        ReadOpenError::BackendMismatch {
            stored_name: "stored".to_string(),
            stored_version: "0".to_string(),
            expected_name: "expected".to_string(),
            expected_version: "1".to_string(),
        },
        ReadOpenError::TokenizerMismatch {
            stored: "stored".to_string(),
            expected: "expected".to_string(),
        },
        ReadOpenError::MissingTantivyIndex,
        ReadOpenError::InvalidInput("field"),
        ReadOpenError::Panic,
    ];
    let mut codes = open_errors
        .iter()
        .map(|error| ErrorCode {
            group: "read_open",
            code: error.abi_code(),
            numeric_code: Some(error.abi_numeric_code()),
            state_code: Some(error.state_code()),
        })
        .collect::<Vec<_>>();

    codes.extend(
        [
            "metadata_error",
            "search_error",
            "panic",
            "invalid_input",
            "not_found",
        ]
        .into_iter()
        .map(|code| ErrorCode {
            group: "read_page",
            code,
            numeric_code: None,
            state_code: Some(ENGINE_READ_STATE_ERROR),
        }),
    );
    codes.extend(
        [
            "invalid_input",
            "invalid_json",
            "unsupported_encoding",
            "invalid_request",
            "missing_index",
            "stale_schema",
            "graph_index_error",
            "oversized_response",
            "path_error",
            "save_conflict",
            "queue_error",
            "serialization_error",
            "panic",
        ]
        .into_iter()
        .map(|code| ErrorCode {
            group: "json_response",
            code,
            numeric_code: None,
            state_code: None,
        }),
    );
    codes.extend(
        ["invalid_input", "rebuild_failed", "panic"]
            .into_iter()
            .map(|code| ErrorCode {
                group: "read_rebuild",
                code,
                numeric_code: None,
                state_code: Some(ENGINE_READ_STATE_ERROR),
            }),
    );
    codes
}

fn constant(name: &'static str, value: impl ToString) -> Constant {
    Constant {
        name,
        value: value.to_string(),
    }
}
