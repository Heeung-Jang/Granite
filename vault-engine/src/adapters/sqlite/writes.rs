use rusqlite::{Connection, params};

use crate::adapters::sqlite::storage_values::{
    attachment_source_to_str, attachment_state_to_storage, bool_to_int, file_status_to_str,
    path_to_string, property_value_to_storage, scan_kind_to_str, system_time_to_unix_ms,
    tag_source_to_str,
};
use crate::core::metadata::{
    AttachmentRecord, FileRecord, HeadingRecord, LinkEdgeRecord, PropertyRecord, TagRecord,
};
use crate::graph_key::unresolved_target_key;
use crate::index::MetadataStoreResult;

pub(crate) fn upsert_file(connection: &Connection, file: &FileRecord) -> MetadataStoreResult<()> {
    connection.execute(
        "INSERT INTO files (
            file_id, relative_path, kind, size_bytes, modified_unix_ms, file_device, file_inode,
            content_hash, generation, status, last_error
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        ON CONFLICT(file_id) DO UPDATE SET
            relative_path = excluded.relative_path,
            kind = excluded.kind,
            size_bytes = excluded.size_bytes,
            modified_unix_ms = excluded.modified_unix_ms,
            file_device = excluded.file_device,
            file_inode = excluded.file_inode,
            content_hash = excluded.content_hash,
            generation = excluded.generation,
            status = excluded.status,
            last_error = excluded.last_error",
        params![
            &file.file_id,
            path_to_string(&file.relative_path),
            scan_kind_to_str(file.kind),
            file.size_bytes as i64,
            system_time_to_unix_ms(file.modified),
            file.file_identity.device.to_string(),
            file.file_identity.inode.to_string(),
            file.content_hash.as_deref(),
            file.generation as i64,
            file_status_to_str(file.status),
            file.last_error.as_deref(),
        ],
    )?;
    Ok(())
}

pub(crate) fn delete_child_records(
    connection: &Connection,
    file_id: &str,
) -> MetadataStoreResult<()> {
    connection.execute(
        "DELETE FROM links WHERE source_file_id = ?1",
        params![file_id],
    )?;
    for table in ["tags", "properties", "headings"] {
        connection.execute(
            &format!("DELETE FROM {table} WHERE file_id = ?1"),
            params![file_id],
        )?;
    }
    connection.execute(
        "DELETE FROM attachments WHERE source_file_id = ?1",
        params![file_id],
    )?;
    Ok(())
}

pub(crate) fn insert_link(
    connection: &Connection,
    link: &LinkEdgeRecord,
) -> MetadataStoreResult<()> {
    let target_key = unresolved_target_key(&link.target_text);
    connection.execute(
        "INSERT INTO links (
            source_file_id, target_text, target_key, resolved_target_file_id, heading, alias, is_embed
        ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            &link.source_file_id,
            &link.target_text,
            &target_key,
            link.resolved_target_file_id.as_deref(),
            link.heading.as_deref(),
            link.alias.as_deref(),
            bool_to_int(link.is_embed),
        ],
    )?;
    Ok(())
}

pub(crate) fn insert_tag(connection: &Connection, tag: &TagRecord) -> MetadataStoreResult<()> {
    connection.execute(
        "INSERT INTO tags (file_id, tag, source) VALUES (?1, ?2, ?3)",
        params![&tag.file_id, &tag.tag, tag_source_to_str(tag.source)],
    )?;
    Ok(())
}

pub(crate) fn insert_property(
    connection: &Connection,
    property: &PropertyRecord,
) -> MetadataStoreResult<()> {
    let (kind, json) = property_value_to_storage(&property.value)?;
    connection.execute(
        "INSERT INTO properties (file_id, key, value_kind, value_json) VALUES (?1, ?2, ?3, ?4)",
        params![&property.file_id, &property.key, kind, json],
    )?;
    Ok(())
}

pub(crate) fn insert_heading(
    connection: &Connection,
    heading: &HeadingRecord,
) -> MetadataStoreResult<()> {
    connection.execute(
        "INSERT INTO headings (file_id, slug, title, level, byte_offset)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            &heading.file_id,
            &heading.slug,
            &heading.title,
            heading.level as i64,
            heading.byte_offset.map(|offset| offset as i64),
        ],
    )?;
    Ok(())
}

pub(crate) fn insert_attachment(
    connection: &Connection,
    attachment: &AttachmentRecord,
) -> MetadataStoreResult<()> {
    let (state, detail) = attachment_state_to_storage(&attachment.state)?;
    connection.execute(
        "INSERT INTO attachments (source_file_id, source, raw_target, state, state_detail)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            &attachment.source_file_id,
            attachment_source_to_str(attachment.source),
            &attachment.raw_target,
            state,
            detail,
        ],
    )?;
    Ok(())
}
