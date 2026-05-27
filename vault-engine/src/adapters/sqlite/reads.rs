use rusqlite::{Connection, OptionalExtension, params};

use crate::adapters::sqlite::metadata_store::MetadataStoreResult;
use crate::adapters::sqlite::rows::{
    row_to_attachment, row_to_file_lookup_projection, row_to_file_record, row_to_graph_file,
    row_to_graph_resolved_edge, row_to_graph_tag, row_to_graph_unresolved_edge, row_to_heading,
    row_to_link, row_to_link_projection, row_to_property, row_to_tag, row_to_tag_note_projection,
};
use crate::adapters::sqlite::storage_values::path_to_string;
use crate::adapters::sqlite::{
    AttachmentProjection, FileLookupProjection, FileTreeProjection, GraphFileRecord,
    GraphQueryPlanSummary, GraphQueryStage, GraphResolvedEdgeRecord, GraphTagRecord,
    GraphUnresolvedEdgeRecord, LinkProjection, PropertyProjection, TagNoteProjection,
};
use crate::core::attachments::AttachmentResolutionState;
use crate::core::metadata::{
    AttachmentRecord, FileRecord, HeadingRecord, LinkEdgeRecord, PropertyRecord, TagRecord,
};

pub(crate) const GRAPH_TAG_FILE_ID_CHUNK_SIZE: usize = 400;

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

pub(crate) fn tags(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<TagRecord>> {
    let mut statement = connection.prepare(
        "SELECT file_id, tag, source FROM tags \
         WHERE file_id = ?1 ORDER BY tag, source, id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(params![file_id, limit as i64, offset as i64], row_to_tag)?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn tag_note_projections(
    connection: &Connection,
    tag: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<TagNoteProjection>> {
    let mut statement = connection.prepare(
        "SELECT t.file_id, f.relative_path, t.tag, MIN(t.source)
         FROM tags t
         JOIN files f ON f.file_id = t.file_id
         WHERE t.tag = ?1
         GROUP BY t.file_id, f.relative_path, t.tag
         ORDER BY f.relative_path, t.file_id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(
        params![tag, limit as i64, offset as i64],
        row_to_tag_note_projection,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn properties(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<PropertyRecord>> {
    let mut statement = connection.prepare(
        "SELECT file_id, key, value_kind, value_json FROM properties \
         WHERE file_id = ?1 ORDER BY key, id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(
        params![file_id, limit as i64, offset as i64],
        row_to_property,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn property_projections(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<PropertyProjection>> {
    let properties = properties(connection, file_id, offset, limit)?;
    Ok(properties
        .into_iter()
        .map(|property| PropertyProjection {
            display_value: property.value.display_value(),
            file_id: property.file_id,
            key: property.key,
            value: property.value,
        })
        .collect())
}

pub(crate) fn headings(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<HeadingRecord>> {
    let mut statement = connection.prepare(
        "SELECT file_id, slug, title, level, byte_offset FROM headings \
         WHERE file_id = ?1 ORDER BY byte_offset, id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(
        params![file_id, limit as i64, offset as i64],
        row_to_heading,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn attachments(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<AttachmentRecord>> {
    let mut statement = connection.prepare(
        "SELECT source_file_id, source, raw_target, state, state_detail FROM attachments \
         WHERE source_file_id = ?1 ORDER BY raw_target, id LIMIT ?2 OFFSET ?3",
    )?;
    let rows = statement.query_map(
        params![file_id, limit as i64, offset as i64],
        row_to_attachment,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn attachment_projections(
    connection: &Connection,
    file_id: &str,
    offset: usize,
    limit: usize,
) -> MetadataStoreResult<Vec<AttachmentProjection>> {
    let attachments = attachments(connection, file_id, offset, limit)?;
    Ok(attachments
        .into_iter()
        .map(|attachment| AttachmentProjection {
            resolved_relative_path: match &attachment.state {
                AttachmentResolutionState::Resolved { relative_path } => {
                    Some(relative_path.clone())
                }
                _ => None,
            },
            source_file_id: attachment.source_file_id,
            raw_target: attachment.raw_target,
            source: attachment.source,
            state: attachment.state,
        })
        .collect())
}

pub(crate) const GRAPH_FILES_SQL: &str = "
    SELECT file_id, relative_path
    FROM files
    WHERE kind = 'markdown'
      AND status IN ('parsed', 'search_indexed')
      AND generation = ?1
    ORDER BY file_id
    LIMIT ?2";

pub(crate) const GRAPH_RESOLVED_EDGES_SQL: &str = "
    SELECT links.source_file_id,
           source_files.relative_path,
           links.resolved_target_file_id,
           target_files.relative_path,
           COUNT(*) AS weight
    FROM links INDEXED BY idx_links_resolved_pair
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    CROSS JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
    WHERE links.resolved_target_file_id IS NOT NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
      AND target_files.kind = 'markdown'
      AND target_files.status IN ('parsed', 'search_indexed')
      AND target_files.generation = ?1
    GROUP BY links.source_file_id, links.resolved_target_file_id
    ORDER BY links.source_file_id, links.resolved_target_file_id
    LIMIT ?2";

pub(crate) const GRAPH_RESOLVED_EDGES_COMPACT_SQL: &str = "
    SELECT links.source_file_id,
           '' AS source_relative_path,
           links.resolved_target_file_id,
           '' AS target_relative_path,
           COUNT(*) AS weight
    FROM links INDEXED BY idx_links_resolved_pair
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    CROSS JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
    WHERE links.resolved_target_file_id IS NOT NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
      AND target_files.kind = 'markdown'
      AND target_files.status IN ('parsed', 'search_indexed')
      AND target_files.generation = ?1
    GROUP BY links.source_file_id, links.resolved_target_file_id
    ORDER BY links.source_file_id, links.resolved_target_file_id
    LIMIT ?2";

pub(crate) const GRAPH_UNRESOLVED_EDGES_SQL: &str = "
    SELECT links.source_file_id,
           source_files.relative_path,
           MIN(links.target_text) AS target_text,
           COUNT(*) AS weight
    FROM links INDEXED BY idx_links_unresolved_source_target_key
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    WHERE links.resolved_target_file_id IS NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
    GROUP BY links.source_file_id, links.target_key
    ORDER BY links.source_file_id, links.target_key
    LIMIT ?2";

pub(crate) const GRAPH_ORPHANS_RESOLVED_ONLY_SQL: &str = "
    SELECT files.file_id, files.relative_path
    FROM files
    WHERE files.kind = 'markdown'
      AND files.status IN ('parsed', 'search_indexed')
      AND files.generation = ?1
      AND NOT EXISTS (
        SELECT 1 FROM links
        JOIN files AS source_files ON source_files.file_id = links.source_file_id
        JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
        WHERE links.resolved_target_file_id IS NOT NULL
          AND source_files.kind = 'markdown'
          AND source_files.status IN ('parsed', 'search_indexed')
          AND source_files.generation = ?1
          AND target_files.kind = 'markdown'
          AND target_files.status IN ('parsed', 'search_indexed')
          AND target_files.generation = ?1
          AND (links.source_file_id = files.file_id OR links.resolved_target_file_id = files.file_id)
      )
    ORDER BY files.file_id
    LIMIT ?2";

pub(crate) const GRAPH_ORPHANS_WITH_UNRESOLVED_SQL: &str = "
    SELECT files.file_id, files.relative_path
    FROM files
    WHERE files.kind = 'markdown'
      AND files.status IN ('parsed', 'search_indexed')
      AND files.generation = ?1
      AND NOT EXISTS (
        SELECT 1 FROM links
        JOIN files AS source_files ON source_files.file_id = links.source_file_id
        JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
        WHERE links.resolved_target_file_id IS NOT NULL
          AND source_files.kind = 'markdown'
          AND source_files.status IN ('parsed', 'search_indexed')
          AND source_files.generation = ?1
          AND target_files.kind = 'markdown'
          AND target_files.status IN ('parsed', 'search_indexed')
          AND target_files.generation = ?1
          AND (links.source_file_id = files.file_id OR links.resolved_target_file_id = files.file_id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM links
        WHERE links.resolved_target_file_id IS NULL
          AND links.source_file_id = files.file_id
      )
    ORDER BY files.file_id
    LIMIT ?2";

pub(crate) const GRAPH_TAGS_PLAN_SQL: &str = "
    SELECT file_id, tag FROM (
        SELECT tags.file_id, tags.tag,
               ROW_NUMBER() OVER (
                   PARTITION BY tags.file_id
                   ORDER BY tags.tag, tags.id
               ) AS tag_rank
        FROM tags
        WHERE tags.file_id IN (?1)
    )
    WHERE tag_rank <= ?2
    ORDER BY file_id, tag";

pub(crate) const GRAPH_RESOLVED_SOURCE_NODES_SQL: &str = "
    SELECT links.source_file_id AS node_id
    FROM links INDEXED BY idx_links_resolved_pair
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    CROSS JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
    WHERE links.resolved_target_file_id IS NOT NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
      AND target_files.kind = 'markdown'
      AND target_files.status IN ('parsed', 'search_indexed')
      AND target_files.generation = ?1";

pub(crate) const GRAPH_RESOLVED_TARGET_NODES_SQL: &str = "
    SELECT links.resolved_target_file_id AS node_id
    FROM links INDEXED BY idx_links_resolved_pair
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    CROSS JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
    WHERE links.resolved_target_file_id IS NOT NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
      AND target_files.kind = 'markdown'
      AND target_files.status IN ('parsed', 'search_indexed')
      AND target_files.generation = ?1";

pub(crate) const GRAPH_UNRESOLVED_SOURCE_NODES_SQL: &str = "
    SELECT links.source_file_id AS node_id
    FROM links INDEXED BY idx_links_unresolved_source_target_key
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    WHERE links.resolved_target_file_id IS NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1";

pub(crate) const GRAPH_UNRESOLVED_TARGET_NODES_SQL: &str = "
    SELECT 'unresolved:' || links.target_key AS node_id
    FROM links INDEXED BY idx_links_unresolved_source_target_key
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    WHERE links.resolved_target_file_id IS NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1";

pub(crate) const GRAPH_RESOLVED_EDGE_GROUPS_SQL: &str = "
    SELECT links.source_file_id, links.resolved_target_file_id
    FROM links INDEXED BY idx_links_resolved_pair
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    CROSS JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
    WHERE links.resolved_target_file_id IS NOT NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
      AND target_files.kind = 'markdown'
      AND target_files.status IN ('parsed', 'search_indexed')
      AND target_files.generation = ?1
    GROUP BY links.source_file_id, links.resolved_target_file_id";

pub(crate) const GRAPH_UNRESOLVED_EDGE_GROUPS_SQL: &str = "
    SELECT links.source_file_id, links.target_key
    FROM links INDEXED BY idx_links_unresolved_source_target_key
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    WHERE links.resolved_target_file_id IS NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
    GROUP BY links.source_file_id, links.target_key";

pub(crate) const GRAPH_ORPHAN_NODES_RESOLVED_ONLY_SQL: &str = "
    SELECT files.file_id AS node_id
    FROM files
    WHERE files.kind = 'markdown'
      AND files.status IN ('parsed', 'search_indexed')
      AND files.generation = ?1
      AND NOT EXISTS (
        SELECT 1 FROM links
        JOIN files AS source_files ON source_files.file_id = links.source_file_id
        JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
        WHERE links.resolved_target_file_id IS NOT NULL
          AND source_files.kind = 'markdown'
          AND source_files.status IN ('parsed', 'search_indexed')
          AND source_files.generation = ?1
          AND target_files.kind = 'markdown'
          AND target_files.status IN ('parsed', 'search_indexed')
          AND target_files.generation = ?1
          AND (links.source_file_id = files.file_id OR links.resolved_target_file_id = files.file_id)
      )";

pub(crate) const GRAPH_ORPHAN_NODES_WITH_UNRESOLVED_SQL: &str = "
    SELECT files.file_id AS node_id
    FROM files
    WHERE files.kind = 'markdown'
      AND files.status IN ('parsed', 'search_indexed')
      AND files.generation = ?1
      AND NOT EXISTS (
        SELECT 1 FROM links
        JOIN files AS source_files ON source_files.file_id = links.source_file_id
        JOIN files AS target_files ON target_files.file_id = links.resolved_target_file_id
        WHERE links.resolved_target_file_id IS NOT NULL
          AND source_files.kind = 'markdown'
          AND source_files.status IN ('parsed', 'search_indexed')
          AND source_files.generation = ?1
          AND target_files.kind = 'markdown'
          AND target_files.status IN ('parsed', 'search_indexed')
          AND target_files.generation = ?1
          AND (links.source_file_id = files.file_id OR links.resolved_target_file_id = files.file_id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM links
        WHERE links.resolved_target_file_id IS NULL
          AND links.source_file_id = files.file_id
      )";

pub(crate) fn graph_files(
    connection: &Connection,
    generation: u64,
    limit: usize,
) -> MetadataStoreResult<Vec<GraphFileRecord>> {
    let mut statement = connection.prepare(GRAPH_FILES_SQL)?;
    let rows = statement.query_map(
        params![generation as i64, limit_to_i64(limit)],
        row_to_graph_file,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn graph_resolved_edges(
    connection: &Connection,
    generation: u64,
    limit: usize,
) -> MetadataStoreResult<Vec<GraphResolvedEdgeRecord>> {
    let mut statement = connection.prepare(GRAPH_RESOLVED_EDGES_SQL)?;
    let rows = statement.query_map(
        params![generation as i64, limit_to_i64(limit)],
        row_to_graph_resolved_edge,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn graph_resolved_edges_compact(
    connection: &Connection,
    generation: u64,
    limit: usize,
) -> MetadataStoreResult<Vec<GraphResolvedEdgeRecord>> {
    let mut statement = connection.prepare(GRAPH_RESOLVED_EDGES_COMPACT_SQL)?;
    let rows = statement.query_map(
        params![generation as i64, limit_to_i64(limit)],
        row_to_graph_resolved_edge,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn graph_unresolved_edges(
    connection: &Connection,
    generation: u64,
    limit: usize,
) -> MetadataStoreResult<Vec<GraphUnresolvedEdgeRecord>> {
    let mut statement = connection.prepare(GRAPH_UNRESOLVED_EDGES_SQL)?;
    let rows = statement.query_map(
        params![generation as i64, limit_to_i64(limit)],
        row_to_graph_unresolved_edge,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn graph_orphan_files(
    connection: &Connection,
    generation: u64,
    include_unresolved: bool,
    limit: usize,
) -> MetadataStoreResult<Vec<GraphFileRecord>> {
    let sql = if include_unresolved {
        GRAPH_ORPHANS_WITH_UNRESOLVED_SQL
    } else {
        GRAPH_ORPHANS_RESOLVED_ONLY_SQL
    };
    let mut statement = connection.prepare(sql)?;
    let rows = statement.query_map(
        params![generation as i64, limit_to_i64(limit)],
        row_to_graph_file,
    )?;
    rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
}

pub(crate) fn graph_tags_for_files(
    connection: &Connection,
    file_ids: &[String],
    max_tags_per_file: usize,
) -> MetadataStoreResult<Vec<GraphTagRecord>> {
    if file_ids.is_empty() || max_tags_per_file == 0 {
        return Ok(Vec::new());
    }

    let mut tags = Vec::new();
    for chunk in file_ids.chunks(GRAPH_TAG_FILE_ID_CHUNK_SIZE) {
        let placeholders = std::iter::repeat_n("?", chunk.len())
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "SELECT file_id, tag FROM (
                SELECT tags.file_id, tags.tag,
                       ROW_NUMBER() OVER (
                           PARTITION BY tags.file_id
                           ORDER BY tags.tag, tags.id
                       ) AS tag_rank
                FROM tags
                WHERE tags.file_id IN ({placeholders})
            )
            WHERE tag_rank <= ?
            ORDER BY file_id, tag"
        );
        let mut statement = connection.prepare(&sql)?;
        let max_tags = limit_to_i64(max_tags_per_file);
        let mut params: Vec<&dyn rusqlite::ToSql> = Vec::with_capacity(chunk.len() + 1);
        for file_id in chunk {
            params.push(file_id);
        }
        params.push(&max_tags);
        let rows = statement.query_map(params.as_slice(), row_to_graph_tag)?;
        for row in rows {
            tags.push(row?);
        }
    }
    Ok(tags)
}

pub(crate) fn graph_visible_node_count(
    connection: &Connection,
    generation: u64,
    include_unresolved: bool,
    include_orphans: bool,
) -> MetadataStoreResult<usize> {
    let mut parts = vec![
        GRAPH_RESOLVED_SOURCE_NODES_SQL,
        GRAPH_RESOLVED_TARGET_NODES_SQL,
    ];
    if include_unresolved {
        parts.push(GRAPH_UNRESOLVED_SOURCE_NODES_SQL);
        parts.push(GRAPH_UNRESOLVED_TARGET_NODES_SQL);
    }
    if include_orphans {
        parts.push(if include_unresolved {
            GRAPH_ORPHAN_NODES_WITH_UNRESOLVED_SQL
        } else {
            GRAPH_ORPHAN_NODES_RESOLVED_ONLY_SQL
        });
    }
    let sql = format!("SELECT COUNT(*) FROM ({})", parts.join(" UNION "));
    connection
        .query_row(&sql, params![generation as i64], |row| row.get::<_, i64>(0))
        .map(|count| count as usize)
        .map_err(Into::into)
}

pub(crate) fn graph_visible_edge_count(
    connection: &Connection,
    generation: u64,
    include_unresolved: bool,
) -> MetadataStoreResult<usize> {
    let sql = if include_unresolved {
        format!(
            "SELECT COUNT(*) FROM ({GRAPH_RESOLVED_EDGE_GROUPS_SQL} UNION ALL {GRAPH_UNRESOLVED_EDGE_GROUPS_SQL})"
        )
    } else {
        format!("SELECT COUNT(*) FROM ({GRAPH_RESOLVED_EDGE_GROUPS_SQL})")
    };
    connection
        .query_row(&sql, params![generation as i64], |row| row.get::<_, i64>(0))
        .map(|count| count as usize)
        .map_err(Into::into)
}

pub(crate) fn graph_query_plan_summaries(
    connection: &Connection,
    generation: u64,
) -> MetadataStoreResult<Vec<GraphQueryPlanSummary>> {
    let queries = [
        (GraphQueryStage::Files, GRAPH_FILES_SQL),
        (GraphQueryStage::ResolvedEdges, GRAPH_RESOLVED_EDGES_SQL),
        (
            GraphQueryStage::ResolvedEdgesCompact,
            GRAPH_RESOLVED_EDGES_COMPACT_SQL,
        ),
        (GraphQueryStage::UnresolvedEdges, GRAPH_UNRESOLVED_EDGES_SQL),
        (
            GraphQueryStage::OrphansResolvedOnly,
            GRAPH_ORPHANS_RESOLVED_ONLY_SQL,
        ),
        (
            GraphQueryStage::OrphansWithUnresolved,
            GRAPH_ORPHANS_WITH_UNRESOLVED_SQL,
        ),
        (GraphQueryStage::Tags, GRAPH_TAGS_PLAN_SQL),
    ];
    let mut summaries = Vec::new();
    for (stage, sql) in queries {
        let explain = format!("EXPLAIN QUERY PLAN {sql}");
        let mut statement = connection.prepare(&explain)?;
        if stage == GraphQueryStage::Tags {
            let rows = statement.query_map(params!["graph-plan-placeholder", 1_i64], |row| {
                Ok(GraphQueryPlanSummary {
                    stage,
                    detail: row.get(3)?,
                })
            })?;
            for row in rows {
                summaries.push(row?);
            }
        } else {
            let rows = statement.query_map(params![generation as i64, 1_i64], |row| {
                Ok(GraphQueryPlanSummary {
                    stage,
                    detail: row.get(3)?,
                })
            })?;
            for row in rows {
                summaries.push(row?);
            }
        }
    }
    Ok(summaries)
}

fn limit_to_i64(limit: usize) -> i64 {
    limit.min(i64::MAX as usize) as i64
}
