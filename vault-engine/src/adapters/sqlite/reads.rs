use rusqlite::{Connection, OptionalExtension, params};

use crate::adapters::sqlite::rows::{
    row_to_file_lookup_projection, row_to_file_record, row_to_link, row_to_link_projection,
};
use crate::adapters::sqlite::storage_values::path_to_string;
use crate::core::metadata::{FileRecord, LinkEdgeRecord};
use crate::index::{FileLookupProjection, FileTreeProjection, LinkProjection, MetadataStoreResult};

pub(crate) fn get_file(
    connection: &Connection,
    file_id: &str,
) -> MetadataStoreResult<Option<FileRecord>> {
    connection
        .query_row(
            "SELECT file_id, relative_path, kind, size_bytes, modified_unix_ms, \
             file_device, file_inode, content_hash, generation, status, last_error \
             FROM files WHERE file_id = ?1",
            params![file_id],
            row_to_file_record,
        )
        .optional()
        .map_err(Into::into)
}

pub(crate) fn list_files(
    connection: &Connection,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<FileRecord>> {
    let mut statement = connection.prepare(
        "SELECT file_id, relative_path, kind, size_bytes, modified_unix_ms, \
         file_device, file_inode, content_hash, generation, status, last_error \
         FROM files ORDER BY relative_path LIMIT ?1 OFFSET ?2",
    )?;
    let rows = statement.query_map(params![limit as i64, offset as i64], row_to_file_record)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn list_markdown_files(
    connection: &Connection,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<FileRecord>> {
    let mut statement = connection.prepare(
        "SELECT file_id, relative_path, kind, size_bytes, modified_unix_ms, \
         file_device, file_inode, content_hash, generation, status, last_error \
         FROM files WHERE kind = 'markdown' ORDER BY relative_path LIMIT ?1 OFFSET ?2",
    )?;
    let rows = statement.query_map(params![limit as i64, offset as i64], row_to_file_record)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn lookup_file(
    connection: &Connection,
    file_id_or_relative_path: &str,
) -> MetadataStoreResult<Option<FileLookupProjection>> {
    connection
        .query_row(
            "SELECT file_id, relative_path FROM files \
             WHERE file_id = ?1 OR relative_path = ?1 \
             ORDER BY relative_path LIMIT 1",
            params![file_id_or_relative_path],
            row_to_file_lookup_projection,
        )
        .optional()
        .map_err(Into::into)
}

pub(crate) fn file_tree_projection(
    connection: &Connection,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<FileTreeProjection>> {
    let files = list_markdown_files(connection, offset, limit)?;
    Ok(files
        .into_iter()
        .map(|file| FileTreeProjection {
            display_path: path_to_string(&file.relative_path),
            file,
        })
        .collect())
}

pub(crate) fn outgoing_links(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<LinkEdgeRecord>> {
    let mut statement = connection.prepare(
        "SELECT source_file_id, target_text, resolved_target_file_id, heading, alias, is_embed \
         FROM links WHERE source_file_id = ?1 ORDER BY target_text, id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(params![file_id, limit as i64, offset as i64], row_to_link)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn backlinks(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<LinkEdgeRecord>> {
    let mut statement = connection.prepare(
        "SELECT source_file_id, target_text, resolved_target_file_id, heading, alias, is_embed \
         FROM links WHERE resolved_target_file_id = ?1 \
         ORDER BY source_file_id, target_text, id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(params![file_id, limit as i64, offset as i64], row_to_link)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn backlink_projections(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<LinkProjection>> {
    let mut statement = connection.prepare(
        "SELECT l.source_file_id, source.relative_path, l.resolved_target_file_id,
                target.relative_path, l.target_text, l.heading, l.alias, l.is_embed
         FROM links l
         LEFT JOIN files source ON source.file_id = l.source_file_id
         LEFT JOIN files target ON target.file_id = l.resolved_target_file_id
         WHERE l.resolved_target_file_id = ?1
         ORDER BY source.relative_path, l.target_text, l.id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(
        params![file_id, limit as i64, offset as i64],
        row_to_link_projection,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn outgoing_link_projections(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<LinkProjection>> {
    let mut statement = connection.prepare(
        "SELECT l.source_file_id, source.relative_path, l.resolved_target_file_id,
                target.relative_path, l.target_text, l.heading, l.alias, l.is_embed
         FROM links l
         LEFT JOIN files source ON source.file_id = l.source_file_id
         LEFT JOIN files target ON target.file_id = l.resolved_target_file_id
         WHERE l.source_file_id = ?1
         ORDER BY l.target_text, l.id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(
        params![file_id, limit as i64, offset as i64],
        row_to_link_projection,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}
