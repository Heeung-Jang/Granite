use std::fmt;
use std::path::Path;

use rusqlite::{Connection, OpenFlags, params};

use crate::adapters::sqlite::reads::{
    attachment_projections as read_attachment_projections, attachments as read_attachments,
    backlink_projections as read_backlink_projections, backlinks as read_backlinks,
    file_tree_projection as read_file_tree_projection, get_file as read_get_file,
    graph_files as read_graph_files, graph_orphan_files as read_graph_orphan_files,
    graph_query_plan_summaries as read_graph_query_plan_summaries,
    graph_resolved_edges as read_graph_resolved_edges,
    graph_resolved_edges_compact as read_graph_resolved_edges_compact,
    graph_tags_for_files as read_graph_tags_for_files,
    graph_unresolved_edges as read_graph_unresolved_edges,
    graph_visible_edge_count as read_graph_visible_edge_count,
    graph_visible_node_count as read_graph_visible_node_count, headings as read_headings,
    list_files as read_list_files, list_markdown_files as read_list_markdown_files,
    list_markdown_files_after as read_list_markdown_files_after, lookup_file as read_lookup_file,
    outgoing_link_projections as read_outgoing_link_projections,
    outgoing_links as read_outgoing_links, properties as read_properties,
    property_projections as read_property_projections,
    tag_note_projections as read_tag_note_projections, tags as read_tags,
};
use crate::adapters::sqlite::schema::{create_projection_indexes, drop_projection_indexes};
use crate::adapters::sqlite::schema::{create_schema, read_schema_metadata, write_schema_metadata};
use crate::adapters::sqlite::storage_values::{
    attachment_source_to_str, attachment_state_to_storage, bool_to_int, file_status_to_str,
    path_to_string, property_value_to_storage, scan_kind_to_str, system_time_to_unix_ms,
    tag_source_to_str,
};
use crate::adapters::sqlite::writes::{
    delete_child_records, insert_attachment, insert_heading, insert_link, insert_property,
    insert_tag, upsert_file,
};
use crate::adapters::sqlite::{
    AttachmentProjection, FileLookupProjection, FileTreeProjection, GraphFileRecord,
    GraphQueryPlanSummary, GraphResolvedEdgeRecord, GraphTagRecord, GraphUnresolvedEdgeRecord,
    IndexSchemaMetadata, LinkProjection, PropertyProjection, TagNoteProjection,
};
use crate::core::links::unresolved_target_key;
use crate::core::metadata::{
    AttachmentRecord, FileMetadataRecords, FileRecord, HeadingRecord, IndexedFileRecords,
    LinkEdgeRecord, PropertyRecord, TagRecord,
};

pub struct MetadataStore {
    pub(crate) connection: Connection,
}

#[derive(Debug)]
pub enum MetadataStoreError {
    Sqlite(rusqlite::Error),
    SchemaMismatch {
        stored: Box<IndexSchemaMetadata>,
        expected: Box<IndexSchemaMetadata>,
    },
    InvalidStoredValue(&'static str),
}

pub type MetadataStoreResult<T> = Result<T, MetadataStoreError>;

impl MetadataStore {
    pub fn open(
        path: impl AsRef<std::path::Path>,
        expected: &IndexSchemaMetadata,
    ) -> MetadataStoreResult<Self> {
        Self::from_connection(Connection::open(path)?, expected)
    }

    pub fn stored_schema_metadata(
        path: impl AsRef<std::path::Path>,
    ) -> MetadataStoreResult<Option<IndexSchemaMetadata>> {
        let connection = Connection::open(path)?;
        read_schema_metadata(&connection)
    }

    pub fn open_in_memory(expected: &IndexSchemaMetadata) -> MetadataStoreResult<Self> {
        Self::from_connection(Connection::open_in_memory()?, expected)
    }

    pub fn release_memory(&self) -> MetadataStoreResult<()> {
        self.connection.execute_batch("PRAGMA shrink_memory;")?;
        Ok(())
    }

    pub fn open_existing_read_only(
        path: impl AsRef<Path>,
        expected: &IndexSchemaMetadata,
    ) -> MetadataStoreResult<(Self, IndexSchemaMetadata)> {
        let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let stored = read_schema_metadata(&connection)?
            .ok_or(MetadataStoreError::InvalidStoredValue("schema_version"))?;
        let expected_with_stored_generation = IndexSchemaMetadata {
            generation: stored.generation,
            ..expected.clone()
        };
        if stored != expected_with_stored_generation {
            return Err(MetadataStoreError::SchemaMismatch {
                stored: Box::new(stored),
                expected: Box::new(expected_with_stored_generation),
            });
        }

        Ok((Self { connection }, stored))
    }

    pub(crate) fn from_connection(
        connection: Connection,
        expected: &IndexSchemaMetadata,
    ) -> MetadataStoreResult<Self> {
        create_schema(&connection)?;
        match read_schema_metadata(&connection)? {
            Some(stored) if stored != *expected => {
                return Err(MetadataStoreError::SchemaMismatch {
                    stored: Box::new(stored),
                    expected: Box::new(expected.clone()),
                });
            }
            Some(_) => {}
            None => write_schema_metadata(&connection, expected)?,
        }

        Ok(Self { connection })
    }
}

impl MetadataStore {
    pub fn replace_file_records(
        &mut self,
        file: &FileRecord,
        links: &[LinkEdgeRecord],
        tags: &[TagRecord],
        properties: &[PropertyRecord],
        headings: &[HeadingRecord],
        attachments: &[AttachmentRecord],
    ) -> MetadataStoreResult<()> {
        let transaction = self.connection.transaction()?;
        upsert_file(&transaction, file)?;
        delete_child_records(&transaction, &file.file_id)?;

        for link in links {
            insert_link(&transaction, link)?;
        }
        for tag in tags {
            insert_tag(&transaction, tag)?;
        }
        for property in properties {
            insert_property(&transaction, property)?;
        }
        for heading in headings {
            insert_heading(&transaction, heading)?;
        }
        for attachment in attachments {
            insert_attachment(&transaction, attachment)?;
        }

        transaction.commit()?;
        Ok(())
    }

    pub fn replace_file_records_batch(
        &mut self,
        records: &[FileMetadataRecords],
    ) -> MetadataStoreResult<()> {
        let transaction = self.connection.transaction()?;
        {
            let mut upsert_file = transaction.prepare(
                "INSERT INTO files (
                    file_id, relative_path, kind, size_bytes, modified_unix_ms, file_device,
                    file_inode, content_hash, generation, status, last_error
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
            )?;
            let mut delete_links =
                transaction.prepare("DELETE FROM links WHERE source_file_id = ?1")?;
            let mut delete_tags = transaction.prepare("DELETE FROM tags WHERE file_id = ?1")?;
            let mut delete_properties =
                transaction.prepare("DELETE FROM properties WHERE file_id = ?1")?;
            let mut delete_headings =
                transaction.prepare("DELETE FROM headings WHERE file_id = ?1")?;
            let mut delete_attachments =
                transaction.prepare("DELETE FROM attachments WHERE source_file_id = ?1")?;
            let mut insert_link = transaction.prepare(
                "INSERT INTO links (
                    source_file_id, target_text, target_key, resolved_target_file_id, heading, alias, is_embed
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            )?;
            let mut insert_tag = transaction
                .prepare("INSERT INTO tags (file_id, tag, source) VALUES (?1, ?2, ?3)")?;
            let mut insert_property = transaction.prepare(
                "INSERT INTO properties (file_id, key, value_kind, value_json)
                 VALUES (?1, ?2, ?3, ?4)",
            )?;
            let mut insert_heading = transaction.prepare(
                "INSERT INTO headings (file_id, slug, title, level, byte_offset)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;
            let mut insert_attachment = transaction.prepare(
                "INSERT INTO attachments (source_file_id, source, raw_target, state, state_detail)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
            )?;

            for record in records {
                let file = &record.file;
                upsert_file.execute(params![
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
                ])?;
                delete_links.execute(params![&file.file_id])?;
                delete_tags.execute(params![&file.file_id])?;
                delete_properties.execute(params![&file.file_id])?;
                delete_headings.execute(params![&file.file_id])?;
                delete_attachments.execute(params![&file.file_id])?;

                for link in &record.links {
                    let target_key = unresolved_target_key(&link.target_text);
                    insert_link.execute(params![
                        &link.source_file_id,
                        &link.target_text,
                        &target_key,
                        link.resolved_target_file_id.as_deref(),
                        link.heading.as_deref(),
                        link.alias.as_deref(),
                        bool_to_int(link.is_embed),
                    ])?;
                }
                for tag in &record.tags {
                    insert_tag.execute(params![
                        &tag.file_id,
                        &tag.tag,
                        tag_source_to_str(tag.source)
                    ])?;
                }
                for property in &record.properties {
                    let (kind, json) = property_value_to_storage(&property.value)?;
                    insert_property.execute(params![
                        &property.file_id,
                        &property.key,
                        kind,
                        json
                    ])?;
                }
                for heading in &record.headings {
                    insert_heading.execute(params![
                        &heading.file_id,
                        &heading.slug,
                        &heading.title,
                        heading.level as i64,
                        heading.byte_offset.map(|offset| offset as i64),
                    ])?;
                }
                for attachment in &record.attachments {
                    let (state, detail) = attachment_state_to_storage(&attachment.state)?;
                    insert_attachment.execute(params![
                        &attachment.source_file_id,
                        attachment_source_to_str(attachment.source),
                        &attachment.raw_target,
                        state,
                        detail,
                    ])?;
                }
            }
        }

        transaction.commit()?;
        Ok(())
    }

    pub fn bulk_load_file_records(
        &mut self,
        records: &[IndexedFileRecords],
    ) -> MetadataStoreResult<()> {
        self.connection.execute_batch(
            "
            PRAGMA synchronous = OFF;
            PRAGMA temp_store = MEMORY;
            ",
        )?;
        drop_projection_indexes(&self.connection)?;

        let load_result: MetadataStoreResult<()> = (|| {
            let transaction = self.connection.transaction()?;
            {
                let mut insert_file = transaction.prepare(
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
                )?;
                let mut insert_link = transaction.prepare(
                    "INSERT INTO links (
                        source_file_id, target_text, target_key, resolved_target_file_id, heading, alias, is_embed
                    ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                )?;
                let mut insert_tag = transaction
                    .prepare("INSERT INTO tags (file_id, tag, source) VALUES (?1, ?2, ?3)")?;
                let mut insert_property = transaction.prepare(
                    "INSERT INTO properties (file_id, key, value_kind, value_json) VALUES (?1, ?2, ?3, ?4)",
                )?;
                let mut insert_heading = transaction.prepare(
                    "INSERT INTO headings (file_id, slug, title, level, byte_offset)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                )?;
                let mut insert_attachment = transaction.prepare(
                    "INSERT INTO attachments (source_file_id, source, raw_target, state, state_detail)
                     VALUES (?1, ?2, ?3, ?4, ?5)",
                )?;

                for record in records {
                    let file = &record.file;
                    insert_file.execute(params![
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
                    ])?;

                    for link in &record.links {
                        let target_key = unresolved_target_key(&link.target_text);
                        insert_link.execute(params![
                            &link.source_file_id,
                            &link.target_text,
                            &target_key,
                            link.resolved_target_file_id.as_deref(),
                            link.heading.as_deref(),
                            link.alias.as_deref(),
                            bool_to_int(link.is_embed),
                        ])?;
                    }
                    for tag in &record.tags {
                        insert_tag.execute(params![
                            &tag.file_id,
                            &tag.tag,
                            tag_source_to_str(tag.source)
                        ])?;
                    }
                    for property in &record.properties {
                        let (kind, json) = property_value_to_storage(&property.value)?;
                        insert_property.execute(params![
                            &property.file_id,
                            &property.key,
                            kind,
                            json
                        ])?;
                    }
                    for heading in &record.headings {
                        insert_heading.execute(params![
                            &heading.file_id,
                            &heading.slug,
                            &heading.title,
                            heading.level as i64,
                            heading.byte_offset.map(|offset| offset as i64),
                        ])?;
                    }
                    for attachment in &record.attachments {
                        let (state, detail) = attachment_state_to_storage(&attachment.state)?;
                        insert_attachment.execute(params![
                            &attachment.source_file_id,
                            attachment_source_to_str(attachment.source),
                            &attachment.raw_target,
                            state,
                            detail,
                        ])?;
                    }
                }
            }

            transaction.commit()?;
            Ok(())
        })();
        let index_result = create_projection_indexes(&self.connection);
        let pragma_result = self
            .connection
            .execute_batch("PRAGMA synchronous = NORMAL;");

        load_result?;
        index_result?;
        pragma_result?;
        Ok(())
    }

    pub fn get_file(&self, file_id: &str) -> MetadataStoreResult<Option<FileRecord>> {
        read_get_file(&self.connection, file_id)
    }

    pub fn list_files(&self, offset: usize, limit: usize) -> MetadataStoreResult<Vec<FileRecord>> {
        read_list_files(&self.connection, offset, limit)
    }

    pub fn list_markdown_files(
        &self,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<FileRecord>> {
        read_list_markdown_files(&self.connection, offset, limit)
    }

    pub fn list_markdown_files_after(
        &self,
        after_relative_path: Option<&str>,
        limit: usize,
    ) -> MetadataStoreResult<Vec<FileRecord>> {
        read_list_markdown_files_after(&self.connection, after_relative_path, limit)
    }

    pub fn lookup_file(
        &self,
        file_id_or_relative_path: &str,
    ) -> MetadataStoreResult<Option<FileLookupProjection>> {
        read_lookup_file(&self.connection, file_id_or_relative_path)
    }

    pub fn file_tree_projection(
        &self,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<FileTreeProjection>> {
        read_file_tree_projection(&self.connection, offset, limit)
    }

    pub fn outgoing_links(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkEdgeRecord>> {
        read_outgoing_links(&self.connection, file_id, offset, limit)
    }

    pub fn backlinks(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkEdgeRecord>> {
        read_backlinks(&self.connection, file_id, offset, limit)
    }

    pub fn backlink_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkProjection>> {
        read_backlink_projections(&self.connection, file_id, offset, limit)
    }

    pub fn outgoing_link_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkProjection>> {
        read_outgoing_link_projections(&self.connection, file_id, offset, limit)
    }

    pub fn tags(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<TagRecord>> {
        read_tags(&self.connection, file_id, offset, limit)
    }

    pub fn graph_files(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphFileRecord>> {
        read_graph_files(&self.connection, generation, limit)
    }

    pub fn graph_resolved_edges(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphResolvedEdgeRecord>> {
        read_graph_resolved_edges(&self.connection, generation, limit)
    }

    pub fn graph_resolved_edges_compact(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphResolvedEdgeRecord>> {
        read_graph_resolved_edges_compact(&self.connection, generation, limit)
    }

    pub fn graph_unresolved_edges(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphUnresolvedEdgeRecord>> {
        read_graph_unresolved_edges(&self.connection, generation, limit)
    }

    pub fn graph_orphan_files(
        &self,
        generation: u64,
        include_unresolved: bool,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphFileRecord>> {
        read_graph_orphan_files(&self.connection, generation, include_unresolved, limit)
    }

    pub fn graph_tags_for_files(
        &self,
        file_ids: &[String],
        max_tags_per_file: usize,
    ) -> MetadataStoreResult<Vec<GraphTagRecord>> {
        read_graph_tags_for_files(&self.connection, file_ids, max_tags_per_file)
    }

    pub fn graph_visible_node_count(
        &self,
        generation: u64,
        include_unresolved: bool,
        include_orphans: bool,
    ) -> MetadataStoreResult<usize> {
        read_graph_visible_node_count(
            &self.connection,
            generation,
            include_unresolved,
            include_orphans,
        )
    }

    pub fn graph_visible_edge_count(
        &self,
        generation: u64,
        include_unresolved: bool,
    ) -> MetadataStoreResult<usize> {
        read_graph_visible_edge_count(&self.connection, generation, include_unresolved)
    }

    pub fn graph_query_plan_summaries(
        &self,
        generation: u64,
    ) -> MetadataStoreResult<Vec<GraphQueryPlanSummary>> {
        read_graph_query_plan_summaries(&self.connection, generation)
    }

    pub fn tag_note_projections(
        &self,
        tag: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<TagNoteProjection>> {
        read_tag_note_projections(&self.connection, tag, offset, limit)
    }

    pub fn properties(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<PropertyRecord>> {
        read_properties(&self.connection, file_id, offset, limit)
    }

    pub fn property_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<PropertyProjection>> {
        read_property_projections(&self.connection, file_id, offset, limit)
    }

    pub fn headings(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<HeadingRecord>> {
        read_headings(&self.connection, file_id, offset, limit)
    }

    pub fn attachments(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<AttachmentRecord>> {
        read_attachments(&self.connection, file_id, offset, limit)
    }

    pub fn attachment_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<AttachmentProjection>> {
        read_attachment_projections(&self.connection, file_id, offset, limit)
    }

    pub fn delete_file(&mut self, file_id: &str) -> MetadataStoreResult<()> {
        let transaction = self.connection.transaction()?;
        delete_child_records(&transaction, file_id)?;
        transaction.execute("DELETE FROM files WHERE file_id = ?1", params![file_id])?;
        transaction.commit()?;
        Ok(())
    }

    pub fn row_count(&self, table: MetadataTable) -> MetadataStoreResult<usize> {
        let sql = match table {
            MetadataTable::Files => "SELECT COUNT(*) FROM files",
            MetadataTable::Links => "SELECT COUNT(*) FROM links",
            MetadataTable::Tags => "SELECT COUNT(*) FROM tags",
            MetadataTable::Properties => "SELECT COUNT(*) FROM properties",
            MetadataTable::Headings => "SELECT COUNT(*) FROM headings",
            MetadataTable::Attachments => "SELECT COUNT(*) FROM attachments",
        };
        self.connection
            .query_row(sql, [], |row| row.get::<_, i64>(0))
            .map(|count| count as usize)
            .map_err(Into::into)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MetadataTable {
    Files,
    Links,
    Tags,
    Properties,
    Headings,
    Attachments,
}

impl fmt::Display for MetadataStoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(error) => write!(formatter, "sqlite metadata store error: {error}"),
            Self::SchemaMismatch { .. } => write!(formatter, "metadata schema mismatch"),
            Self::InvalidStoredValue(field) => {
                write!(formatter, "invalid stored metadata value for {field}")
            }
        }
    }
}

impl std::error::Error for MetadataStoreError {}

impl From<rusqlite::Error> for MetadataStoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}
