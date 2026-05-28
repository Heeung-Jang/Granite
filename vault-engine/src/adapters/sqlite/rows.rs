use std::path::PathBuf;

use rusqlite::Row;

use crate::adapters::sqlite::storage_values::{
    attachment_source_from_str, attachment_state_from_storage, file_status_from_str, int_to_bool,
    optional_path, path_to_string, property_value_from_storage, scan_kind_from_str,
    tag_source_from_str, unix_ms_to_system_time,
};
use crate::adapters::sqlite::{
    FileLookupProjection, GraphFileRecord, GraphResolvedEdgeRecord, GraphTagRecord,
    GraphUnresolvedEdgeRecord, LinkProjection, TagNoteProjection,
};
use crate::core::files::FileIdentity;
use crate::core::metadata::{
    AttachmentRecord, FileRecord, HeadingRecord, LinkEdgeRecord, PropertyRecord, TagRecord,
};

pub(crate) fn row_to_file_record(row: &Row<'_>) -> rusqlite::Result<FileRecord> {
    let kind: String = row.get(2)?;
    let device: String = row.get(5)?;
    let inode: String = row.get(6)?;
    let status: String = row.get(9)?;

    Ok(FileRecord {
        file_id: row.get(0)?,
        relative_path: PathBuf::from(row.get::<_, String>(1)?),
        kind: scan_kind_from_str(&kind).map_err(|_| rusqlite::Error::InvalidQuery)?,
        size_bytes: row.get::<_, i64>(3)? as u64,
        modified: unix_ms_to_system_time(row.get(4)?),
        file_identity: FileIdentity {
            device: device.parse().map_err(|_| rusqlite::Error::InvalidQuery)?,
            inode: inode.parse().map_err(|_| rusqlite::Error::InvalidQuery)?,
        },
        content_hash: row.get(7)?,
        generation: row.get::<_, i64>(8)? as u64,
        status: file_status_from_str(&status).map_err(|_| rusqlite::Error::InvalidQuery)?,
        last_error: row.get(10)?,
    })
}

pub(crate) fn row_to_file_lookup_projection(
    row: &Row<'_>,
) -> rusqlite::Result<FileLookupProjection> {
    let relative_path = PathBuf::from(row.get::<_, String>(1)?);
    Ok(FileLookupProjection {
        file_id: row.get(0)?,
        display_path: path_to_string(&relative_path),
        relative_path,
    })
}

pub(crate) fn row_to_link_projection(row: &Row<'_>) -> rusqlite::Result<LinkProjection> {
    Ok(LinkProjection {
        source_file_id: row.get(0)?,
        source_relative_path: optional_path(row.get(1)?),
        target_file_id: row.get(2)?,
        target_relative_path: optional_path(row.get(3)?),
        target_text: row.get(4)?,
        heading: row.get(5)?,
        alias: row.get(6)?,
        is_embed: int_to_bool(row.get(7)?),
    })
}

pub(crate) fn row_to_tag_note_projection(row: &Row<'_>) -> rusqlite::Result<TagNoteProjection> {
    let source: String = row.get(3)?;
    Ok(TagNoteProjection {
        file_id: row.get(0)?,
        relative_path: PathBuf::from(row.get::<_, String>(1)?),
        tag: row.get(2)?,
        source: tag_source_from_str(&source).map_err(|_| rusqlite::Error::InvalidQuery)?,
    })
}

pub(crate) fn row_to_link(row: &Row<'_>) -> rusqlite::Result<LinkEdgeRecord> {
    Ok(LinkEdgeRecord {
        source_file_id: row.get(0)?,
        target_text: row.get(1)?,
        resolved_target_file_id: row.get(2)?,
        heading: row.get(3)?,
        alias: row.get(4)?,
        is_embed: row.get::<_, i64>(5)? == 1,
    })
}

pub(crate) fn row_to_tag(row: &Row<'_>) -> rusqlite::Result<TagRecord> {
    let source: String = row.get(2)?;
    Ok(TagRecord {
        file_id: row.get(0)?,
        tag: row.get(1)?,
        source: tag_source_from_str(&source).map_err(|_| rusqlite::Error::InvalidQuery)?,
    })
}

pub(crate) fn row_to_graph_file(row: &Row<'_>) -> rusqlite::Result<GraphFileRecord> {
    Ok(GraphFileRecord {
        file_id: row.get(0)?,
        relative_path: PathBuf::from(row.get::<_, String>(1)?),
    })
}

pub(crate) fn row_to_graph_resolved_edge(
    row: &Row<'_>,
) -> rusqlite::Result<GraphResolvedEdgeRecord> {
    Ok(GraphResolvedEdgeRecord {
        source_file_id: row.get(0)?,
        source_relative_path: PathBuf::from(row.get::<_, String>(1)?),
        target_file_id: row.get(2)?,
        target_relative_path: PathBuf::from(row.get::<_, String>(3)?),
        weight: row.get::<_, i64>(4)? as usize,
    })
}

pub(crate) fn row_to_graph_unresolved_edge(
    row: &Row<'_>,
) -> rusqlite::Result<GraphUnresolvedEdgeRecord> {
    Ok(GraphUnresolvedEdgeRecord {
        source_file_id: row.get(0)?,
        source_relative_path: PathBuf::from(row.get::<_, String>(1)?),
        target_text: row.get(2)?,
        weight: row.get::<_, i64>(3)? as usize,
    })
}

pub(crate) fn row_to_graph_tag(row: &Row<'_>) -> rusqlite::Result<GraphTagRecord> {
    Ok(GraphTagRecord {
        file_id: row.get(0)?,
        tag: row.get(1)?,
    })
}

pub(crate) fn row_to_property(row: &Row<'_>) -> rusqlite::Result<PropertyRecord> {
    let kind: String = row.get(2)?;
    let json: String = row.get(3)?;
    Ok(PropertyRecord {
        file_id: row.get(0)?,
        key: row.get(1)?,
        value: property_value_from_storage(&kind, &json)
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
    })
}

pub(crate) fn row_to_heading(row: &Row<'_>) -> rusqlite::Result<HeadingRecord> {
    Ok(HeadingRecord {
        file_id: row.get(0)?,
        slug: row.get(1)?,
        title: row.get(2)?,
        level: row.get::<_, i64>(3)? as u8,
        byte_offset: row.get::<_, Option<i64>>(4)?.map(|offset| offset as u64),
    })
}

pub(crate) fn row_to_attachment(row: &Row<'_>) -> rusqlite::Result<AttachmentRecord> {
    let source: String = row.get(1)?;
    let state: String = row.get(3)?;
    let detail: Option<String> = row.get(4)?;
    Ok(AttachmentRecord {
        source_file_id: row.get(0)?,
        source: attachment_source_from_str(&source).map_err(|_| rusqlite::Error::InvalidQuery)?,
        raw_target: row.get(2)?,
        state: attachment_state_from_storage(&state, detail.as_deref())
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
    })
}
