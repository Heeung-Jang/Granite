use std::mem::size_of;
use std::os::raw::c_uchar;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::ENGINE_ABI_VERSION;
use crate::adapters::sqlite::{
    AttachmentProjection, AttachmentRecord, FileIndexStatus, FileRecord, FileTreeProjection,
    IndexPropertyValue, LinkProjection, PropertyProjection, PropertyRecord, TagRecord,
};
use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
use crate::read_api::{
    LivePreviewMetadataItem, LivePreviewMetadataItemKind, LivePreviewMetadataSource,
    LivePreviewMetadataState, LocalGraphEdge, LocalGraphEdgeDirection, LocalGraphNode,
    LocalGraphNodeKind, ReadOpenError, SearchHit,
};
use crate::scanner::ScanEntryKind;

pub const ENGINE_READ_NO_NEXT_OFFSET: u64 = u64::MAX;
pub const ENGINE_READ_ROW_KIND_OPEN_STATUS: u32 = 1;
pub const ENGINE_READ_ROW_KIND_FILE_TREE: u32 = 10;
pub const ENGINE_READ_ROW_KIND_SEARCH_HIT: u32 = 11;
pub const ENGINE_READ_ROW_KIND_BACKLINK: u32 = 12;
pub const ENGINE_READ_ROW_KIND_OUTGOING_LINK: u32 = 13;
pub const ENGINE_READ_ROW_KIND_TAG: u32 = 14;
pub const ENGINE_READ_ROW_KIND_PROPERTY: u32 = 15;
pub const ENGINE_READ_ROW_KIND_ATTACHMENT: u32 = 16;
pub const ENGINE_READ_ROW_KIND_GRAPH_NODE: u32 = 17;
pub const ENGINE_READ_ROW_KIND_GRAPH_EDGE: u32 = 18;
pub const ENGINE_READ_ROW_KIND_LIVE_PREVIEW_METADATA: u32 = 19;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadStringRef {
    pub offset: u32,
    pub length: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadResultHeader {
    pub abi_version: u32,
    pub row_kind: u32,
    pub request_id: u64,
    pub generation: u64,
    pub state: u32,
    pub row_count: u32,
    pub row_stride: u32,
    pub rows_offset: u32,
    pub string_arena_offset: u32,
    pub string_arena_length: u32,
    pub next_offset: u64,
    pub error_code: EngineReadStringRef,
    pub error_message: EngineReadStringRef,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct EngineReadResultBuffer {
    pub ptr: *mut c_uchar,
    pub len: usize,
    pub capacity: usize,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadFileTreeRow {
    pub relative_path: EngineReadStringRef,
    pub display_name: EngineReadStringRef,
    pub kind: u32,
    pub status: u32,
    pub size_bytes: u64,
    pub modified_unix_ms: i64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EngineReadSearchHitRow {
    pub file_id: EngineReadStringRef,
    pub relative_path: EngineReadStringRef,
    pub title: EngineReadStringRef,
    pub snippet: EngineReadStringRef,
    pub rank: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadLinkRow {
    pub source_file_id: EngineReadStringRef,
    pub source_relative_path: EngineReadStringRef,
    pub target_file_id: EngineReadStringRef,
    pub target_relative_path: EngineReadStringRef,
    pub target_text: EngineReadStringRef,
    pub heading: EngineReadStringRef,
    pub alias: EngineReadStringRef,
    pub resolution_state: u32,
    pub is_embed: u32,
}

pub type EngineReadBacklinkRow = EngineReadLinkRow;
pub type EngineReadOutgoingLinkRow = EngineReadLinkRow;

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadTagRow {
    pub file_id: EngineReadStringRef,
    pub tag: EngineReadStringRef,
    pub source: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadPropertyRow {
    pub file_id: EngineReadStringRef,
    pub key: EngineReadStringRef,
    pub display_value: EngineReadStringRef,
    pub value_kind: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadAttachmentRow {
    pub source_file_id: EngineReadStringRef,
    pub raw_target: EngineReadStringRef,
    pub resolved_relative_path: EngineReadStringRef,
    pub source_kind: u32,
    pub state_kind: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadGraphNodeRow {
    pub node_id: EngineReadStringRef,
    pub file_id: EngineReadStringRef,
    pub label: EngineReadStringRef,
    pub node_kind: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadGraphEdgeRow {
    pub source_node_id: EngineReadStringRef,
    pub target_node_id: EngineReadStringRef,
    pub target_text: EngineReadStringRef,
    pub direction: u32,
    pub is_embed: u32,
    pub hop: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineReadLivePreviewMetadataRow {
    pub item_kind: u32,
    pub key: EngineReadStringRef,
    pub value: EngineReadStringRef,
    pub resolved_file_id: EngineReadStringRef,
    pub resolved_relative_path: EngineReadStringRef,
    pub heading: EngineReadStringRef,
    pub alias: EngineReadStringRef,
    pub state_kind: u32,
    pub source_kind: u32,
}

pub struct EngineReadResultBuilder {
    header: EngineReadResultHeader,
    rows: Vec<u8>,
    strings: Vec<u8>,
}

impl EngineReadStringRef {
    pub const fn empty() -> Self {
        Self {
            offset: 0,
            length: 0,
        }
    }
}

impl EngineReadResultBuilder {
    pub fn new(
        row_kind: u32,
        request_id: u64,
        generation: u64,
        state: u32,
        next_offset: Option<u64>,
    ) -> Self {
        Self {
            header: EngineReadResultHeader {
                abi_version: ENGINE_ABI_VERSION,
                row_kind,
                request_id,
                generation,
                state,
                row_count: 0,
                row_stride: 0,
                rows_offset: size_of::<EngineReadResultHeader>() as u32,
                string_arena_offset: size_of::<EngineReadResultHeader>() as u32,
                string_arena_length: 0,
                next_offset: next_offset.unwrap_or(ENGINE_READ_NO_NEXT_OFFSET),
                error_code: EngineReadStringRef::empty(),
                error_message: EngineReadStringRef::empty(),
            },
            rows: Vec::new(),
            strings: Vec::new(),
        }
    }

    pub fn push_string(&mut self, value: &str) -> EngineReadStringRef {
        if value.is_empty() {
            return EngineReadStringRef::empty();
        }
        let offset = self.strings.len();
        self.strings.extend_from_slice(value.as_bytes());
        EngineReadStringRef {
            offset: checked_u32(offset),
            length: checked_u32(value.len()),
        }
    }

    pub fn push_row<T: Copy>(&mut self, row: &T) {
        let row_size = size_of::<T>();
        if self.header.row_stride == 0 {
            self.header.row_stride = checked_u32(row_size);
        } else {
            assert_eq!(self.header.row_stride as usize, row_size);
        }
        let row_bytes = unsafe { bytes_of(row) };
        self.rows.extend_from_slice(row_bytes);
        self.header.row_count += 1;
    }

    pub fn set_error(&mut self, code: &str, message: &str) {
        self.header.error_code = self.push_string(code);
        self.header.error_message = self.push_string(message);
    }

    pub fn finish(mut self) -> EngineReadResultBuffer {
        self.header.rows_offset = size_of::<EngineReadResultHeader>() as u32;
        self.header.string_arena_offset =
            checked_u32(size_of::<EngineReadResultHeader>() + self.rows.len());
        self.header.string_arena_length = checked_u32(self.strings.len());

        let mut bytes = Vec::with_capacity(
            size_of::<EngineReadResultHeader>() + self.rows.len() + self.strings.len(),
        );
        let header_bytes = unsafe { bytes_of(&self.header) };
        bytes.extend_from_slice(header_bytes);
        bytes.extend_from_slice(&self.rows);
        bytes.extend_from_slice(&self.strings);

        let result = EngineReadResultBuffer {
            ptr: bytes.as_mut_ptr(),
            len: bytes.len(),
            capacity: bytes.capacity(),
        };
        std::mem::forget(bytes);
        result
    }
}

pub fn empty_result_buffer(
    row_kind: u32,
    request_id: u64,
    generation: u64,
    state: u32,
    next_offset: Option<u64>,
) -> EngineReadResultBuffer {
    EngineReadResultBuilder::new(row_kind, request_id, generation, state, next_offset).finish()
}

pub fn error_result_buffer(
    row_kind: u32,
    request_id: u64,
    generation: u64,
    state: u32,
    code: &str,
    message: &str,
) -> EngineReadResultBuffer {
    let mut builder = EngineReadResultBuilder::new(row_kind, request_id, generation, state, None);
    builder.set_error(code, message);
    builder.finish()
}

pub fn open_status_buffer(generation: u64, state: u32) -> EngineReadResultBuffer {
    empty_result_buffer(ENGINE_READ_ROW_KIND_OPEN_STATUS, 0, generation, state, None)
}

pub fn open_error_buffer(error: &ReadOpenError) -> EngineReadResultBuffer {
    error_result_buffer(
        ENGINE_READ_ROW_KIND_OPEN_STATUS,
        0,
        0,
        error.state_code(),
        error.abi_code(),
        &error.to_string(),
    )
}

impl EngineReadFileTreeRow {
    pub fn from_record(builder: &mut EngineReadResultBuilder, record: &FileRecord) -> Self {
        let relative_path = path_display(&record.relative_path);
        let display_name = record
            .relative_path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| relative_path.clone());
        Self {
            relative_path: builder.push_string(&relative_path),
            display_name: builder.push_string(&display_name),
            kind: file_kind_code(record.kind),
            status: file_status_code(record.status),
            size_bytes: record.size_bytes,
            modified_unix_ms: unix_ms(record.modified),
        }
    }

    pub fn from_projection(
        builder: &mut EngineReadResultBuilder,
        projection: &FileTreeProjection,
    ) -> Self {
        let mut row = Self::from_record(builder, &projection.file);
        row.relative_path = builder.push_string(&projection.display_path);
        row
    }
}

impl EngineReadSearchHitRow {
    pub fn from_hit(builder: &mut EngineReadResultBuilder, hit: &SearchHit) -> Self {
        Self {
            file_id: builder.push_string(&hit.file_id),
            relative_path: builder.push_string(&hit.path),
            title: builder.push_string(&hit.title),
            snippet: builder.push_string(&hit.snippet),
            rank: hit.rank,
        }
    }
}

impl EngineReadTagRow {
    pub fn from_record(builder: &mut EngineReadResultBuilder, record: &TagRecord) -> Self {
        Self {
            file_id: builder.push_string(&record.file_id),
            tag: builder.push_string(&record.tag),
            source: tag_source_code(record.source),
        }
    }
}

impl EngineReadLinkRow {
    pub fn from_projection(
        builder: &mut EngineReadResultBuilder,
        projection: &LinkProjection,
    ) -> Self {
        Self {
            source_file_id: builder.push_string(&projection.source_file_id),
            source_relative_path: projection
                .source_relative_path
                .as_ref()
                .map(|path| builder.push_string(&path_display(path)))
                .unwrap_or_else(EngineReadStringRef::empty),
            target_file_id: projection
                .target_file_id
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            target_relative_path: projection
                .target_relative_path
                .as_ref()
                .map(|path| builder.push_string(&path_display(path)))
                .unwrap_or_else(EngineReadStringRef::empty),
            target_text: builder.push_string(&projection.target_text),
            heading: projection
                .heading
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            alias: projection
                .alias
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            resolution_state: link_resolution_state_code(projection.target_file_id.is_some()),
            is_embed: u32::from(projection.is_embed),
        }
    }
}

impl EngineReadPropertyRow {
    pub fn from_record(builder: &mut EngineReadResultBuilder, record: &PropertyRecord) -> Self {
        let display_value = match &record.value {
            IndexPropertyValue::String(value) => value.clone(),
            IndexPropertyValue::Bool(value) => value.to_string(),
            IndexPropertyValue::List(values) => values.join(", "),
        };
        Self {
            file_id: builder.push_string(&record.file_id),
            key: builder.push_string(&record.key),
            display_value: builder.push_string(&display_value),
            value_kind: property_value_kind(&record.value),
        }
    }

    pub fn from_projection(
        builder: &mut EngineReadResultBuilder,
        projection: &PropertyProjection,
    ) -> Self {
        Self {
            file_id: builder.push_string(&projection.file_id),
            key: builder.push_string(&projection.key),
            display_value: builder.push_string(&projection.display_value),
            value_kind: property_value_kind(&projection.value),
        }
    }
}

impl EngineReadAttachmentRow {
    pub fn from_record(builder: &mut EngineReadResultBuilder, record: &AttachmentRecord) -> Self {
        let resolved_relative_path = match &record.state {
            AttachmentResolutionState::Resolved { relative_path } => {
                builder.push_string(&path_display(relative_path))
            }
            AttachmentResolutionState::Missing
            | AttachmentResolutionState::Duplicate { .. }
            | AttachmentResolutionState::Remote
            | AttachmentResolutionState::Rejected(_)
            | AttachmentResolutionState::Unsupported => EngineReadStringRef::empty(),
        };
        Self {
            source_file_id: builder.push_string(&record.source_file_id),
            raw_target: builder.push_string(&record.raw_target),
            resolved_relative_path,
            source_kind: attachment_source_code(record.source),
            state_kind: attachment_state_code(&record.state),
        }
    }

    pub fn from_projection(
        builder: &mut EngineReadResultBuilder,
        projection: &AttachmentProjection,
    ) -> Self {
        let resolved_relative_path = projection
            .resolved_relative_path
            .as_ref()
            .map(|path| builder.push_string(&path_display(path)))
            .unwrap_or_else(EngineReadStringRef::empty);
        Self {
            source_file_id: builder.push_string(&projection.source_file_id),
            raw_target: builder.push_string(&projection.raw_target),
            resolved_relative_path,
            source_kind: attachment_source_code(projection.source),
            state_kind: attachment_state_code(&projection.state),
        }
    }
}

impl EngineReadGraphNodeRow {
    pub fn from_node(builder: &mut EngineReadResultBuilder, node: &LocalGraphNode) -> Self {
        Self {
            node_id: builder.push_string(&node.node_id),
            file_id: node
                .file_id
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            label: builder.push_string(&node.label),
            node_kind: local_graph_node_kind_code(node.kind),
        }
    }
}

impl EngineReadGraphEdgeRow {
    pub fn from_edge(builder: &mut EngineReadResultBuilder, edge: &LocalGraphEdge) -> Self {
        Self {
            source_node_id: builder.push_string(&edge.source_node_id),
            target_node_id: builder.push_string(&edge.target_node_id),
            target_text: builder.push_string(&edge.target_text),
            direction: local_graph_edge_direction_code(edge.direction),
            is_embed: u32::from(edge.is_embed),
            hop: u32::from(edge.hop),
        }
    }
}

impl EngineReadLivePreviewMetadataRow {
    pub fn from_item(
        builder: &mut EngineReadResultBuilder,
        item: &LivePreviewMetadataItem,
    ) -> Self {
        Self {
            item_kind: live_preview_item_kind_code(item.kind),
            key: builder.push_string(&item.key),
            value: builder.push_string(&item.value),
            resolved_file_id: item
                .resolved_file_id
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            resolved_relative_path: item
                .resolved_relative_path
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            heading: item
                .heading
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            alias: item
                .alias
                .as_ref()
                .map(|value| builder.push_string(value))
                .unwrap_or_else(EngineReadStringRef::empty),
            state_kind: live_preview_state_code(item.state),
            source_kind: live_preview_source_code(item.source),
        }
    }
}

#[cfg(test)]
pub fn decode_header_for_test(buffer: &EngineReadResultBuffer) -> EngineReadResultHeader {
    assert!(!buffer.ptr.is_null());
    assert!(buffer.len >= size_of::<EngineReadResultHeader>());
    unsafe { std::ptr::read_unaligned(buffer.ptr.cast::<EngineReadResultHeader>()) }
}

#[cfg(test)]
pub fn string_for_test(buffer: &EngineReadResultBuffer, string_ref: EngineReadStringRef) -> String {
    if string_ref.length == 0 {
        return String::new();
    }
    let header = decode_header_for_test(buffer);
    let start = header.string_arena_offset as usize + string_ref.offset as usize;
    let end = start + string_ref.length as usize;
    assert!(end <= buffer.len);
    let bytes = unsafe { std::slice::from_raw_parts(buffer.ptr.add(start), end - start) };
    String::from_utf8(bytes.to_vec()).expect("utf8 string")
}

unsafe fn bytes_of<T>(value: &T) -> &[u8] {
    unsafe { std::slice::from_raw_parts((value as *const T).cast::<u8>(), size_of::<T>()) }
}

fn checked_u32(value: usize) -> u32 {
    u32::try_from(value).expect("read ABI buffer offset exceeds u32")
}

fn path_display(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn unix_ms(time: Option<SystemTime>) -> i64 {
    time.and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(-1)
}

pub(crate) fn file_kind_code(kind: ScanEntryKind) -> u32 {
    match kind {
        ScanEntryKind::Markdown => 1,
        ScanEntryKind::Attachment => 2,
        ScanEntryKind::Other => 3,
    }
}

pub(crate) fn file_status_code(status: FileIndexStatus) -> u32 {
    match status {
        FileIndexStatus::SeenMetadata => 1,
        FileIndexStatus::Parsed => 2,
        FileIndexStatus::SearchIndexed => 3,
        FileIndexStatus::Tombstoned => 4,
        FileIndexStatus::Error => 5,
    }
}

pub(crate) fn tag_source_code(source: crate::adapters::sqlite::TagSource) -> u32 {
    match source {
        crate::adapters::sqlite::TagSource::Inline => 1,
        crate::adapters::sqlite::TagSource::Frontmatter => 2,
    }
}

pub(crate) fn link_resolution_state_code(resolved: bool) -> u32 {
    if resolved { 1 } else { 2 }
}

pub(crate) fn attachment_source_code(source: AttachmentReferenceSource) -> u32 {
    match source {
        AttachmentReferenceSource::WikiEmbed => 1,
        AttachmentReferenceSource::MarkdownImage => 2,
        AttachmentReferenceSource::MarkdownLink => 3,
    }
}

pub(crate) fn attachment_state_code(state: &AttachmentResolutionState) -> u32 {
    match state {
        AttachmentResolutionState::Resolved { .. } => 1,
        AttachmentResolutionState::Missing => 2,
        AttachmentResolutionState::Duplicate { .. } => 3,
        AttachmentResolutionState::Remote => 4,
        AttachmentResolutionState::Rejected(_) => 5,
        AttachmentResolutionState::Unsupported => 6,
    }
}

pub(crate) fn property_value_kind(value: &IndexPropertyValue) -> u32 {
    match value {
        IndexPropertyValue::String(_) => 1,
        IndexPropertyValue::Bool(_) => 2,
        IndexPropertyValue::List(_) => 3,
    }
}

pub(crate) fn local_graph_node_kind_code(kind: LocalGraphNodeKind) -> u32 {
    match kind {
        LocalGraphNodeKind::Center => 1,
        LocalGraphNodeKind::Resolved => 2,
        LocalGraphNodeKind::Unresolved => 3,
    }
}

pub(crate) fn local_graph_edge_direction_code(direction: LocalGraphEdgeDirection) -> u32 {
    match direction {
        LocalGraphEdgeDirection::Outgoing => 1,
        LocalGraphEdgeDirection::Backlink => 2,
    }
}

pub(crate) fn live_preview_item_kind_code(kind: LivePreviewMetadataItemKind) -> u32 {
    match kind {
        LivePreviewMetadataItemKind::Property => 1,
        LivePreviewMetadataItemKind::Tag => 2,
        LivePreviewMetadataItemKind::Link => 3,
        LivePreviewMetadataItemKind::Attachment => 4,
    }
}

pub(crate) fn live_preview_state_code(state: LivePreviewMetadataState) -> u32 {
    match state {
        LivePreviewMetadataState::None => 0,
        LivePreviewMetadataState::Resolved => 1,
        LivePreviewMetadataState::Missing => 2,
        LivePreviewMetadataState::Remote => 4,
        LivePreviewMetadataState::Rejected => 5,
        LivePreviewMetadataState::Unsupported => 6,
    }
}

pub(crate) fn live_preview_source_code(source: LivePreviewMetadataSource) -> u32 {
    match source {
        LivePreviewMetadataSource::None => 0,
        LivePreviewMetadataSource::Inline => 1,
        LivePreviewMetadataSource::WikiLink => 2,
        LivePreviewMetadataSource::MarkdownLink => 3,
        LivePreviewMetadataSource::WikiEmbed => 4,
        LivePreviewMetadataSource::MarkdownImage => 5,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::sqlite::{IndexPropertyValue, PropertyRecord, TagSource};
    use crate::attachments::AttachmentResolutionState;
    use crate::read_api::{
        ENGINE_READ_STATE_COMPLETE, ENGINE_READ_STATE_ERROR, LocalGraphEdgeDirection,
    };
    use crate::scanner::{ScanEntry, ScanEntryKind};
    use serde_json::Value;
    use std::time::UNIX_EPOCH;

    #[test]
    fn string_ref_layout_is_stable() {
        assert_eq!(size_of::<EngineReadStringRef>(), 8);
        assert_eq!(std::mem::align_of::<EngineReadStringRef>(), 4);
    }

    #[test]
    fn header_layout_is_stable() {
        assert_eq!(size_of::<EngineReadResultHeader>(), 72);
        assert_eq!(std::mem::align_of::<EngineReadResultHeader>(), 8);
    }

    #[test]
    fn builder_places_row_and_string_arena_after_header() {
        let mut builder = EngineReadResultBuilder::new(
            ENGINE_READ_ROW_KIND_SEARCH_HIT,
            42,
            7,
            ENGINE_READ_STATE_COMPLETE,
            Some(10),
        );
        let row = EngineReadSearchHitRow {
            file_id: builder.push_string("home"),
            relative_path: builder.push_string("Home.md"),
            title: builder.push_string("Home"),
            snippet: builder.push_string("body"),
            rank: 1.5,
        };
        builder.push_row(&row);

        let buffer = builder.finish();
        let header = decode_header_for_test(&buffer);

        assert_eq!(header.request_id, 42);
        assert_eq!(header.generation, 7);
        assert_eq!(header.row_count, 1);
        assert_eq!(
            header.row_stride as usize,
            size_of::<EngineReadSearchHitRow>()
        );
        assert_eq!(
            header.rows_offset as usize,
            size_of::<EngineReadResultHeader>()
        );
        assert_eq!(
            header.string_arena_offset as usize,
            size_of::<EngineReadResultHeader>() + size_of::<EngineReadSearchHitRow>()
        );
        assert_eq!(header.next_offset, 10);
        assert_eq!(string_for_test(&buffer, row.relative_path), "Home.md");

        unsafe {
            drop(Vec::from_raw_parts(buffer.ptr, buffer.len, buffer.capacity));
        }
    }

    #[test]
    fn empty_and_error_buffers_decode_state() {
        let empty = empty_result_buffer(
            ENGINE_READ_ROW_KIND_FILE_TREE,
            1,
            2,
            ENGINE_READ_STATE_COMPLETE,
            None,
        );
        let empty_header = decode_header_for_test(&empty);
        assert_eq!(empty_header.row_count, 0);
        assert_eq!(empty_header.next_offset, ENGINE_READ_NO_NEXT_OFFSET);
        unsafe {
            drop(Vec::from_raw_parts(empty.ptr, empty.len, empty.capacity));
        }

        let error = error_result_buffer(
            ENGINE_READ_ROW_KIND_FILE_TREE,
            1,
            2,
            ENGINE_READ_STATE_ERROR,
            "invalid_input",
            "bad path",
        );
        let error_header = decode_header_for_test(&error);
        assert_eq!(
            string_for_test(&error, error_header.error_code),
            "invalid_input"
        );
        assert_eq!(
            string_for_test(&error, error_header.error_message),
            "bad path"
        );
        unsafe {
            drop(Vec::from_raw_parts(error.ptr, error.len, error.capacity));
        }
    }

    #[test]
    fn builds_file_tree_and_search_rows() {
        let entry = ScanEntry {
            relative_path: "Folder/Home.md".into(),
            kind: ScanEntryKind::Markdown,
            size_bytes: 12,
            modified: Some(UNIX_EPOCH),
            file_identity: crate::paths::FileIdentity {
                device: 1,
                inode: 2,
            },
        };
        let record = FileRecord::from_scan_entry(&entry, 3);
        let mut builder = EngineReadResultBuilder::new(
            ENGINE_READ_ROW_KIND_FILE_TREE,
            0,
            3,
            ENGINE_READ_STATE_COMPLETE,
            None,
        );
        let row = EngineReadFileTreeRow::from_record(&mut builder, &record);
        assert_eq!(string_for_builder(&builder, row.display_name), "Home.md");

        let hit = SearchHit {
            file_id: "home".to_string(),
            path: "Home.md".to_string(),
            title: "Home".to_string(),
            rank: 2.0,
            snippet: "match".to_string(),
        };
        let search_row = EngineReadSearchHitRow::from_hit(&mut builder, &hit);
        assert_eq!(string_for_builder(&builder, search_row.snippet), "match");
    }

    #[test]
    fn builds_link_tag_property_attachment_and_graph_rows() {
        let mut builder = EngineReadResultBuilder::new(
            ENGINE_READ_ROW_KIND_BACKLINK,
            0,
            1,
            ENGINE_READ_STATE_COMPLETE,
            None,
        );
        let link = EngineReadLinkRow {
            source_file_id: builder.push_string("source"),
            source_relative_path: builder.push_string("Source.md"),
            target_file_id: builder.push_string("target"),
            target_relative_path: builder.push_string("Target.md"),
            target_text: builder.push_string("Target"),
            heading: EngineReadStringRef::empty(),
            alias: builder.push_string("Alias"),
            resolution_state: 1,
            is_embed: 0,
        };
        builder.push_row(&link);
        assert_eq!(
            string_for_builder(&builder, link.target_relative_path),
            "Target.md"
        );

        let tag = TagRecord {
            file_id: "home".to_string(),
            tag: "project/native".to_string(),
            source: TagSource::Frontmatter,
        };
        let tag_row = EngineReadTagRow::from_record(&mut builder, &tag);
        assert_eq!(tag_row.source, 2);

        let property = PropertyRecord {
            file_id: "home".to_string(),
            key: "tags".to_string(),
            value: IndexPropertyValue::List(vec!["a".to_string(), "b".to_string()]),
        };
        let property_row = EngineReadPropertyRow::from_record(&mut builder, &property);
        assert_eq!(
            string_for_builder(&builder, property_row.display_value),
            "a, b"
        );

        let attachment = AttachmentRecord {
            source_file_id: "home".to_string(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "image.png".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: "assets/image.png".into(),
            },
        };
        let attachment_row = EngineReadAttachmentRow::from_record(&mut builder, &attachment);
        assert_eq!(attachment_row.state_kind, 1);

        let node = LocalGraphNode {
            node_id: "file:home".to_string(),
            file_id: Some("home".to_string()),
            label: "Home.md".to_string(),
            kind: LocalGraphNodeKind::Center,
        };
        let node_row = EngineReadGraphNodeRow::from_node(&mut builder, &node);
        assert_eq!(node_row.node_kind, 1);

        let edge = LocalGraphEdge {
            source_node_id: "file:home".to_string(),
            target_node_id: "file:target".to_string(),
            target_text: "Target".to_string(),
            direction: LocalGraphEdgeDirection::Outgoing,
            is_embed: true,
            hop: 2,
        };
        let edge_row = EngineReadGraphEdgeRow::from_edge(&mut builder, &edge);
        assert_eq!(edge_row.direction, 1);
        assert_eq!(edge_row.is_embed, 1);
        assert_eq!(edge_row.hop, 2);
    }

    #[test]
    fn layout_fixture_matches_current_abi() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../fixtures/read-abi-layout.json"))
                .expect("layout fixture");
        assert_layout::<EngineReadStringRef>(&fixture, "EngineReadStringRef");
        assert_layout::<EngineReadResultHeader>(&fixture, "EngineReadResultHeader");
        assert_layout::<EngineReadFileTreeRow>(&fixture, "EngineReadFileTreeRow");
        assert_layout::<EngineReadSearchHitRow>(&fixture, "EngineReadSearchHitRow");
        assert_layout::<EngineReadLinkRow>(&fixture, "EngineReadLinkRow");
        assert_layout::<EngineReadTagRow>(&fixture, "EngineReadTagRow");
        assert_layout::<EngineReadPropertyRow>(&fixture, "EngineReadPropertyRow");
        assert_layout::<EngineReadAttachmentRow>(&fixture, "EngineReadAttachmentRow");
        assert_layout::<EngineReadGraphNodeRow>(&fixture, "EngineReadGraphNodeRow");
        assert_layout::<EngineReadGraphEdgeRow>(&fixture, "EngineReadGraphEdgeRow");
        assert_layout::<EngineReadLivePreviewMetadataRow>(
            &fixture,
            "EngineReadLivePreviewMetadataRow",
        );
    }

    fn string_for_builder(
        builder: &EngineReadResultBuilder,
        string_ref: EngineReadStringRef,
    ) -> String {
        if string_ref.length == 0 {
            return String::new();
        }
        let start = string_ref.offset as usize;
        let end = start + string_ref.length as usize;
        String::from_utf8(builder.strings[start..end].to_vec()).expect("utf8")
    }

    fn assert_layout<T>(fixture: &Value, name: &str) {
        assert_eq!(fixture[name]["size"], size_of::<T>());
        assert_eq!(fixture[name]["align"], std::mem::align_of::<T>());
    }
}
