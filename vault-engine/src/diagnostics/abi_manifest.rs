use std::mem::{align_of, offset_of, size_of};
use std::path::PathBuf;

use serde::Serialize;

use crate::ENGINE_ABI_VERSION;
use crate::adapters::sqlite::{FileIndexStatus, IndexPropertyValue, TagSource};
use crate::core::attachments::{
    AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
};
use crate::ffi::read_rows::{
    ENGINE_READ_NO_NEXT_OFFSET, ENGINE_READ_ROW_KIND_ATTACHMENT, ENGINE_READ_ROW_KIND_BACKLINK,
    ENGINE_READ_ROW_KIND_FILE_TREE, ENGINE_READ_ROW_KIND_GRAPH_EDGE,
    ENGINE_READ_ROW_KIND_GRAPH_NODE, ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA,
    ENGINE_READ_ROW_KIND_OPEN_STATUS, ENGINE_READ_ROW_KIND_OUTGOING_LINK,
    ENGINE_READ_ROW_KIND_PROPERTY, ENGINE_READ_ROW_KIND_SEARCH_HIT, ENGINE_READ_ROW_KIND_TAG,
    EngineReadAttachmentRow, EngineReadFileTreeRow, EngineReadGraphEdgeRow, EngineReadGraphNodeRow,
    EngineReadLinkRow, EngineReadLivePreviewMetadataRow, EngineReadPropertyRow,
    EngineReadResultBuffer, EngineReadResultHeader, EngineReadSearchHitRow, EngineReadStringRef,
    EngineReadTagRow, attachment_source_code, attachment_state_code, file_kind_code,
    file_status_code, link_resolution_state_code, live_preview_item_kind_code,
    live_preview_source_code, live_preview_state_code, local_graph_edge_direction_code,
    local_graph_node_kind_code, property_value_kind, tag_source_code,
};
use crate::ffi::{EngineReadLocalGraphResult, EngineReadOpenResult};
use crate::graph::{
    MAX_WHOLE_VAULT_GRAPH_EDGES, MAX_WHOLE_VAULT_GRAPH_GROUPS, MAX_WHOLE_VAULT_GRAPH_LABEL_BYTES,
    MAX_WHOLE_VAULT_GRAPH_NODES, MAX_WHOLE_VAULT_GRAPH_RULE_LENGTH,
    MAX_WHOLE_VAULT_GRAPH_TAGS_PER_NODE,
};
use crate::scanner::ScanEntryKind;
use crate::use_cases::read_graph::{LocalGraphEdgeDirection, LocalGraphNodeKind};
use crate::use_cases::read_types::{
    ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS, ENGINE_READ_INSPECTOR_PANEL_BACKLINKS,
    ENGINE_READ_INSPECTOR_PANEL_OUTGOING, ENGINE_READ_INSPECTOR_PANEL_PROPERTIES,
    ENGINE_READ_INSPECTOR_PANEL_TAGS, ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP,
    ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP, ENGINE_READ_SEARCH_MODE_BODY,
    ENGINE_READ_SEARCH_MODE_FILE_NAME, ENGINE_READ_STATE_CANCELLED, ENGINE_READ_STATE_COMPLETE,
    ENGINE_READ_STATE_ERROR, ENGINE_READ_STATE_INDEX_UNAVAILABLE, ENGINE_READ_STATE_PARTIAL,
    ENGINE_READ_STATE_STALE, LivePreviewMetadataItemKind, LivePreviewMetadataSource,
    LivePreviewMetadataState, ReadOpenError,
};

#[derive(Serialize)]
struct AbiManifest {
    schema_version: u32,
    abi_version: u32,
    layouts: Vec<Layout>,
    constants: Vec<Constant>,
    error_codes: Vec<ErrorCode>,
    json_contracts: Vec<JsonContract>,
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

#[derive(Clone, Serialize)]
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

#[derive(Serialize)]
struct JsonContract {
    name: &'static str,
    direction: &'static str,
    fields: Vec<&'static str>,
    values: Vec<Constant>,
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

pub fn generate_abi_manifest_json() -> Result<String, serde_json::Error> {
    serde_json::to_string_pretty(&AbiManifest {
        schema_version: 2,
        abi_version: ENGINE_ABI_VERSION,
        layouts: layouts(),
        constants: constants(),
        error_codes: error_codes(),
        json_contracts: json_contracts(),
    })
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
        constant(
            "FILE_KIND_MARKDOWN",
            file_kind_code(ScanEntryKind::Markdown),
        ),
        constant(
            "FILE_KIND_ATTACHMENT",
            file_kind_code(ScanEntryKind::Attachment),
        ),
        constant("FILE_KIND_OTHER", file_kind_code(ScanEntryKind::Other)),
        constant(
            "FILE_STATUS_SEEN_METADATA",
            file_status_code(FileIndexStatus::SeenMetadata),
        ),
        constant(
            "FILE_STATUS_PARSED",
            file_status_code(FileIndexStatus::Parsed),
        ),
        constant(
            "FILE_STATUS_SEARCH_INDEXED",
            file_status_code(FileIndexStatus::SearchIndexed),
        ),
        constant(
            "FILE_STATUS_TOMBSTONED",
            file_status_code(FileIndexStatus::Tombstoned),
        ),
        constant(
            "FILE_STATUS_ERROR",
            file_status_code(FileIndexStatus::Error),
        ),
        constant("TAG_SOURCE_INLINE", tag_source_code(TagSource::Inline)),
        constant(
            "TAG_SOURCE_FRONTMATTER",
            tag_source_code(TagSource::Frontmatter),
        ),
        constant(
            "PROPERTY_VALUE_KIND_STRING",
            property_value_kind(&IndexPropertyValue::String(String::new())),
        ),
        constant(
            "PROPERTY_VALUE_KIND_BOOL",
            property_value_kind(&IndexPropertyValue::Bool(false)),
        ),
        constant(
            "PROPERTY_VALUE_KIND_LIST",
            property_value_kind(&IndexPropertyValue::List(Vec::new())),
        ),
        constant(
            "LINK_RESOLUTION_STATE_RESOLVED",
            link_resolution_state_code(true),
        ),
        constant(
            "LINK_RESOLUTION_STATE_UNRESOLVED",
            link_resolution_state_code(false),
        ),
        constant(
            "ATTACHMENT_SOURCE_WIKI_EMBED",
            attachment_source_code(AttachmentReferenceSource::WikiEmbed),
        ),
        constant(
            "ATTACHMENT_SOURCE_MARKDOWN_IMAGE",
            attachment_source_code(AttachmentReferenceSource::MarkdownImage),
        ),
        constant(
            "ATTACHMENT_SOURCE_MARKDOWN_LINK",
            attachment_source_code(AttachmentReferenceSource::MarkdownLink),
        ),
        constant(
            "ATTACHMENT_STATE_RESOLVED",
            attachment_state_code(&AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachment.png"),
            }),
        ),
        constant(
            "ATTACHMENT_STATE_MISSING",
            attachment_state_code(&AttachmentResolutionState::Missing),
        ),
        constant(
            "ATTACHMENT_STATE_DUPLICATE",
            attachment_state_code(&AttachmentResolutionState::Duplicate {
                candidates: vec![PathBuf::from("a.png")],
            }),
        ),
        constant(
            "ATTACHMENT_STATE_REMOTE",
            attachment_state_code(&AttachmentResolutionState::Remote),
        ),
        constant(
            "ATTACHMENT_STATE_REJECTED",
            attachment_state_code(&AttachmentResolutionState::Rejected(
                AttachmentRejectReason::UrlScheme,
            )),
        ),
        constant(
            "ATTACHMENT_STATE_UNSUPPORTED",
            attachment_state_code(&AttachmentResolutionState::Unsupported),
        ),
        constant(
            "LOCAL_GRAPH_NODE_CENTER",
            local_graph_node_kind_code(LocalGraphNodeKind::Center),
        ),
        constant(
            "LOCAL_GRAPH_NODE_RESOLVED",
            local_graph_node_kind_code(LocalGraphNodeKind::Resolved),
        ),
        constant(
            "LOCAL_GRAPH_NODE_UNRESOLVED",
            local_graph_node_kind_code(LocalGraphNodeKind::Unresolved),
        ),
        constant(
            "LOCAL_GRAPH_EDGE_OUTGOING",
            local_graph_edge_direction_code(LocalGraphEdgeDirection::Outgoing),
        ),
        constant(
            "LOCAL_GRAPH_EDGE_BACKLINK",
            local_graph_edge_direction_code(LocalGraphEdgeDirection::Backlink),
        ),
        constant(
            "LIVE_PREVIEW_ITEM_PROPERTY",
            live_preview_item_kind_code(LivePreviewMetadataItemKind::Property),
        ),
        constant(
            "LIVE_PREVIEW_ITEM_TAG",
            live_preview_item_kind_code(LivePreviewMetadataItemKind::Tag),
        ),
        constant(
            "LIVE_PREVIEW_ITEM_LINK",
            live_preview_item_kind_code(LivePreviewMetadataItemKind::Link),
        ),
        constant(
            "LIVE_PREVIEW_ITEM_ATTACHMENT",
            live_preview_item_kind_code(LivePreviewMetadataItemKind::Attachment),
        ),
        constant(
            "LIVE_PREVIEW_STATE_NONE",
            live_preview_state_code(LivePreviewMetadataState::None),
        ),
        constant(
            "LIVE_PREVIEW_STATE_RESOLVED",
            live_preview_state_code(LivePreviewMetadataState::Resolved),
        ),
        constant(
            "LIVE_PREVIEW_STATE_MISSING",
            live_preview_state_code(LivePreviewMetadataState::Missing),
        ),
        constant(
            "LIVE_PREVIEW_STATE_REMOTE",
            live_preview_state_code(LivePreviewMetadataState::Remote),
        ),
        constant(
            "LIVE_PREVIEW_STATE_REJECTED",
            live_preview_state_code(LivePreviewMetadataState::Rejected),
        ),
        constant(
            "LIVE_PREVIEW_STATE_UNSUPPORTED",
            live_preview_state_code(LivePreviewMetadataState::Unsupported),
        ),
        constant(
            "LIVE_PREVIEW_SOURCE_NONE",
            live_preview_source_code(LivePreviewMetadataSource::None),
        ),
        constant(
            "LIVE_PREVIEW_SOURCE_INLINE",
            live_preview_source_code(LivePreviewMetadataSource::Inline),
        ),
        constant(
            "LIVE_PREVIEW_SOURCE_WIKI_LINK",
            live_preview_source_code(LivePreviewMetadataSource::WikiLink),
        ),
        constant(
            "LIVE_PREVIEW_SOURCE_MARKDOWN_LINK",
            live_preview_source_code(LivePreviewMetadataSource::MarkdownLink),
        ),
        constant(
            "LIVE_PREVIEW_SOURCE_WIKI_EMBED",
            live_preview_source_code(LivePreviewMetadataSource::WikiEmbed),
        ),
        constant(
            "LIVE_PREVIEW_SOURCE_MARKDOWN_IMAGE",
            live_preview_source_code(LivePreviewMetadataSource::MarkdownImage),
        ),
        constant("WHOLE_VAULT_GRAPH_PAYLOAD_VERSION", 1),
        constant("WHOLE_VAULT_GRAPH_CURRENT_GENERATION", 0),
        constant("MAX_WHOLE_VAULT_GRAPH_NODES", MAX_WHOLE_VAULT_GRAPH_NODES),
        constant("MAX_WHOLE_VAULT_GRAPH_EDGES", MAX_WHOLE_VAULT_GRAPH_EDGES),
        constant(
            "MAX_WHOLE_VAULT_GRAPH_LABEL_BYTES",
            MAX_WHOLE_VAULT_GRAPH_LABEL_BYTES,
        ),
        constant(
            "MAX_WHOLE_VAULT_GRAPH_TAGS_PER_NODE",
            MAX_WHOLE_VAULT_GRAPH_TAGS_PER_NODE,
        ),
        constant("MAX_WHOLE_VAULT_GRAPH_GROUPS", MAX_WHOLE_VAULT_GRAPH_GROUPS),
        constant(
            "MAX_WHOLE_VAULT_GRAPH_RULE_LENGTH",
            MAX_WHOLE_VAULT_GRAPH_RULE_LENGTH,
        ),
        constant("WHOLE_VAULT_GRAPH_STATE_COMPLETE", "complete"),
        constant("WHOLE_VAULT_GRAPH_STATE_PARTIAL", "partial"),
        constant("WHOLE_VAULT_GRAPH_NODE_KIND_RESOLVED", "Resolved"),
        constant("WHOLE_VAULT_GRAPH_NODE_KIND_UNRESOLVED", "Unresolved"),
        constant("WHOLE_VAULT_GRAPH_EDGE_KIND_RESOLVED", "Resolved"),
        constant("WHOLE_VAULT_GRAPH_EDGE_KIND_UNRESOLVED", "Unresolved"),
        constant("WHOLE_VAULT_GRAPH_PARTIAL_MAX_NODES", "MaxNodes"),
        constant("WHOLE_VAULT_GRAPH_PARTIAL_MAX_EDGES", "MaxEdges"),
        constant("WHOLE_VAULT_GRAPH_PARTIAL_MAX_LABEL_BYTES", "MaxLabelBytes"),
        constant(
            "WHOLE_VAULT_GRAPH_PARTIAL_MAX_TAGS_PER_NODE",
            "MaxTagsPerNode",
        ),
        constant("WHOLE_VAULT_GRAPH_PARTIAL_MAX_GROUPS", "MaxGroups"),
        constant("WHOLE_VAULT_GRAPH_PARTIAL_MAX_RULE_LENGTH", "MaxRuleLength"),
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
            "read_only",
            "not_regular_file",
            "io_error",
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

fn json_contracts() -> Vec<JsonContract> {
    vec![
        contract(
            "FfiResponse<T>",
            "rust_to_swift",
            ["ok", "value", "error"],
            [],
        ),
        contract(
            "FfiError",
            "rust_to_swift",
            ["code", "message", "conflict_kind", "conflict"],
            [],
        ),
        contract("FfiFileIdentity", "both", ["device", "inode"], []),
        contract(
            "FfiSystemTime",
            "both",
            ["secs_since_unix_epoch", "nanos"],
            [],
        ),
        contract(
            "FfiSaveBaseline",
            "both",
            [
                "relative_path",
                "file_identity",
                "size_bytes",
                "modified",
                "content_hash",
            ],
            [],
        ),
        contract(
            "FfiSaveConflictSnapshot",
            "both",
            ["file_identity", "size_bytes", "modified", "content_hash"],
            [],
        ),
        contract(
            "FfiSaveConflict",
            "both",
            ["relative_path", "kind", "expected", "actual"],
            [
                constant("kind.Deleted", "Deleted"),
                constant("kind.FileIdentityChanged", "FileIdentityChanged"),
                constant("kind.ContentChanged", "ContentChanged"),
                constant("kind.MetadataChanged", "MetadataChanged"),
                constant("kind.SymlinkChanged", "SymlinkChanged"),
            ],
        ),
        contract(
            "FfiSaveOutcome",
            "rust_to_swift",
            ["baseline", "bytes_written"],
            [],
        ),
        contract(
            "FfiQueuedItem",
            "rust_to_swift",
            ["relative_path", "generation", "reason", "status"],
            [
                constant("reason.InitialScan", "InitialScan"),
                constant("reason.FileCreated", "FileCreated"),
                constant("reason.FileChanged", "FileChanged"),
                constant("reason.FileDeleted", "FileDeleted"),
                constant("reason.Rebuild", "Rebuild"),
                constant("reason.OwnSave", "OwnSave"),
                constant("status.Pending", "Pending"),
                constant("status.InProgress", "InProgress"),
                constant("status.Completed", "Completed"),
                constant("status.Failed", "Failed"),
                constant("status.Cancelled", "Cancelled"),
            ],
        ),
        contract(
            "FfiSaveReloadOutcome",
            "rust_to_swift",
            ["baseline", "contents", "queued_item", "dirty"],
            [],
        ),
        contract(
            "FfiSaveChoiceOutcome",
            "rust_to_swift",
            [
                "choice",
                "baseline",
                "bytes_written",
                "queued_item",
                "dirty",
            ],
            [
                constant("choice.KeepAsNewNote", "KeepAsNewNote"),
                constant("choice.Overwrite", "Overwrite"),
            ],
        ),
        contract(
            "FfiWholeVaultGraphRequest",
            "swift_to_rust",
            [
                "payload_version",
                "request_id",
                "generation",
                "include_unresolved",
                "include_orphans",
                "max_nodes",
                "max_edges",
                "byte_cap_bytes",
            ],
            [
                constant("payload_version", 1),
                constant("current_generation", 0),
            ],
        ),
        contract(
            "FfiWholeVaultGraphPayload",
            "rust_to_swift",
            [
                "payload_version",
                "request_id",
                "generation",
                "state",
                "metrics",
                "snapshot",
            ],
            [
                constant("state.complete", "complete"),
                constant("state.partial", "partial"),
            ],
        ),
        contract(
            "FfiWholeVaultGraphMetrics",
            "rust_to_swift",
            ["snapshot_duration_milliseconds", "encoded_payload_bytes"],
            [],
        ),
        contract(
            "WholeVaultGraphSnapshot",
            "rust_to_swift",
            [
                "request_id",
                "generation",
                "partial_reasons",
                "node_count_total",
                "edge_count_total",
                "nodes",
                "edges",
            ],
            [
                constant("partial_reason.MaxNodes", "MaxNodes"),
                constant("partial_reason.MaxEdges", "MaxEdges"),
                constant("partial_reason.MaxLabelBytes", "MaxLabelBytes"),
                constant("partial_reason.MaxTagsPerNode", "MaxTagsPerNode"),
                constant("partial_reason.MaxGroups", "MaxGroups"),
                constant("partial_reason.MaxRuleLength", "MaxRuleLength"),
            ],
        ),
        contract(
            "WholeVaultGraphNode",
            "rust_to_swift",
            [
                "node_id",
                "file_id",
                "relative_path",
                "label",
                "kind",
                "degree",
                "tags",
            ],
            [
                constant("kind.Resolved", "Resolved"),
                constant("kind.Unresolved", "Unresolved"),
            ],
        ),
        contract(
            "WholeVaultGraphEdge",
            "rust_to_swift",
            ["source_node_id", "target_node_id", "kind", "weight"],
            [
                constant("kind.Resolved", "Resolved"),
                constant("kind.Unresolved", "Unresolved"),
            ],
        ),
    ]
}

fn contract<const FIELD_COUNT: usize, const VALUE_COUNT: usize>(
    name: &'static str,
    direction: &'static str,
    fields: [&'static str; FIELD_COUNT],
    values: [Constant; VALUE_COUNT],
) -> JsonContract {
    JsonContract {
        name,
        direction,
        fields: fields.to_vec(),
        values: values.to_vec(),
    }
}

fn constant(name: &'static str, value: impl ToString) -> Constant {
    Constant {
        name,
        value: value.to_string(),
    }
}
