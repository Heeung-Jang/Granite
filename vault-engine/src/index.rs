use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::adapters::sqlite::schema::{
    create_projection_indexes, create_schema, drop_projection_indexes, read_schema_metadata,
    write_schema_metadata,
};
use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};

use crate::graph_key::unresolved_target_key;
use crate::paths::{FileIdentity, lookup_key};
use crate::scanner::{ScanEntry, ScanEntryKind};

pub const INDEX_SCHEMA_VERSION: u32 = 2;
pub const MAX_INDEX_ERROR_CHARS: usize = 512;

pub use crate::core::metadata::{
    AttachmentRecord, FileIndexStatus, FileMetadataRecords, FileRecord, HeadingRecord,
    IndexPropertyValue, IndexSchemaMetadata, IndexedFileRecords, LinkEdgeRecord, PropertyRecord,
    TagRecord, TagSource,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphFileRecord {
    pub file_id: String,
    pub relative_path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphResolvedEdgeRecord {
    pub source_file_id: String,
    pub source_relative_path: PathBuf,
    pub target_file_id: String,
    pub target_relative_path: PathBuf,
    pub weight: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphUnresolvedEdgeRecord {
    pub source_file_id: String,
    pub source_relative_path: PathBuf,
    pub target_text: String,
    pub weight: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphTagRecord {
    pub file_id: String,
    pub tag: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphQueryStage {
    Files,
    ResolvedEdges,
    ResolvedEdgesCompact,
    UnresolvedEdges,
    OrphansResolvedOnly,
    OrphansWithUnresolved,
    Tags,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GraphQueryPlanSummary {
    pub stage: GraphQueryStage,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileLookupProjection {
    pub file_id: String,
    pub relative_path: PathBuf,
    pub display_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTreeProjection {
    pub file: FileRecord,
    pub display_path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkProjection {
    pub source_file_id: String,
    pub source_relative_path: Option<PathBuf>,
    pub target_file_id: Option<String>,
    pub target_relative_path: Option<PathBuf>,
    pub target_text: String,
    pub heading: Option<String>,
    pub alias: Option<String>,
    pub is_embed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagNoteProjection {
    pub file_id: String,
    pub relative_path: PathBuf,
    pub tag: String,
    pub source: TagSource,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyProjection {
    pub file_id: String,
    pub key: String,
    pub value: IndexPropertyValue,
    pub display_value: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentProjection {
    pub source_file_id: String,
    pub raw_target: String,
    pub source: AttachmentReferenceSource,
    pub state: AttachmentResolutionState,
    pub resolved_relative_path: Option<PathBuf>,
}

pub struct MetadataStore {
    connection: Connection,
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

impl IndexSchemaMetadata {
    pub fn new(
        backend_name: impl Into<String>,
        backend_version: impl Into<String>,
        tokenizer_config: impl Into<String>,
        generation: u64,
    ) -> Self {
        Self {
            schema_version: INDEX_SCHEMA_VERSION,
            backend_name: backend_name.into(),
            backend_version: backend_version.into(),
            tokenizer_config: tokenizer_config.into(),
            generation,
        }
    }
}

impl FileRecord {
    pub fn from_scan_entry(entry: &ScanEntry, generation: u64) -> Self {
        Self {
            file_id: lookup_key(&entry.relative_path),
            relative_path: entry.relative_path.clone(),
            kind: entry.kind,
            size_bytes: entry.size_bytes,
            modified: entry.modified,
            file_identity: entry.file_identity.clone(),
            content_hash: None,
            generation,
            status: FileIndexStatus::SeenMetadata,
            last_error: None,
        }
    }

    pub fn mark_seen_metadata(&mut self, entry: &ScanEntry, generation: u64) {
        self.relative_path = entry.relative_path.clone();
        self.kind = entry.kind;
        self.size_bytes = entry.size_bytes;
        self.modified = entry.modified;
        self.file_identity = entry.file_identity.clone();
        self.generation = generation;
        self.status = FileIndexStatus::SeenMetadata;
        self.last_error = None;
    }

    pub fn mark_parsed(&mut self, content_hash: impl Into<String>) {
        self.content_hash = Some(content_hash.into());
        self.status = FileIndexStatus::Parsed;
        self.last_error = None;
    }

    pub fn mark_search_indexed(&mut self) {
        self.status = FileIndexStatus::SearchIndexed;
        self.last_error = None;
    }

    pub fn mark_tombstoned(&mut self, generation: u64) {
        self.generation = generation;
        self.status = FileIndexStatus::Tombstoned;
        self.last_error = None;
    }

    pub fn mark_error(&mut self, error: impl AsRef<str>) {
        self.status = FileIndexStatus::Error;
        self.last_error = Some(truncate_index_error(error.as_ref()));
    }
}

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

    fn from_connection(
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
        self.connection
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

    pub fn list_files(&self, offset: usize, limit: usize) -> MetadataStoreResult<Vec<FileRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT file_id, relative_path, kind, size_bytes, modified_unix_ms, \
             file_device, file_inode, content_hash, generation, status, last_error \
             FROM files ORDER BY relative_path LIMIT ?1 OFFSET ?2",
        )?;
        let rows = statement.query_map(params![limit as i64, offset as i64], row_to_file_record)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn list_markdown_files(
        &self,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<FileRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT file_id, relative_path, kind, size_bytes, modified_unix_ms, \
             file_device, file_inode, content_hash, generation, status, last_error \
             FROM files WHERE kind = 'markdown' ORDER BY relative_path LIMIT ?1 OFFSET ?2",
        )?;
        let rows = statement.query_map(params![limit as i64, offset as i64], row_to_file_record)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn lookup_file(
        &self,
        file_id_or_relative_path: &str,
    ) -> MetadataStoreResult<Option<FileLookupProjection>> {
        self.connection
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

    pub fn file_tree_projection(
        &self,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<FileTreeProjection>> {
        let files = self.list_markdown_files(offset, limit)?;
        Ok(files
            .into_iter()
            .map(|file| FileTreeProjection {
                display_path: path_to_string(&file.relative_path),
                file,
            })
            .collect())
    }

    pub fn outgoing_links(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkEdgeRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT source_file_id, target_text, resolved_target_file_id, heading, alias, is_embed \
             FROM links WHERE source_file_id = ?1 ORDER BY target_text, id LIMIT ?2 OFFSET ?3",
        )?;
        let rows =
            statement.query_map(params![file_id, limit as i64, offset as i64], row_to_link)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn backlinks(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkEdgeRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT source_file_id, target_text, resolved_target_file_id, heading, alias, is_embed \
             FROM links WHERE resolved_target_file_id = ?1 \
             ORDER BY source_file_id, target_text, id LIMIT ?2 OFFSET ?3",
        )?;
        let rows =
            statement.query_map(params![file_id, limit as i64, offset as i64], row_to_link)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn backlink_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkProjection>> {
        let mut statement = self.connection.prepare(
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

    pub fn outgoing_link_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<LinkProjection>> {
        let mut statement = self.connection.prepare(
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

    pub fn tags(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<TagRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT file_id, tag, source FROM tags \
             WHERE file_id = ?1 ORDER BY tag, source, id LIMIT ?2 OFFSET ?3",
        )?;
        let rows =
            statement.query_map(params![file_id, limit as i64, offset as i64], row_to_tag)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn graph_files(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphFileRecord>> {
        let mut statement = self.connection.prepare(GRAPH_FILES_SQL)?;
        let rows = statement.query_map(
            params![generation as i64, limit_to_i64(limit)],
            row_to_graph_file,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn graph_resolved_edges(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphResolvedEdgeRecord>> {
        let mut statement = self.connection.prepare(GRAPH_RESOLVED_EDGES_SQL)?;
        let rows = statement.query_map(
            params![generation as i64, limit_to_i64(limit)],
            row_to_graph_resolved_edge,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn graph_resolved_edges_compact(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphResolvedEdgeRecord>> {
        let mut statement = self.connection.prepare(GRAPH_RESOLVED_EDGES_COMPACT_SQL)?;
        let rows = statement.query_map(
            params![generation as i64, limit_to_i64(limit)],
            row_to_graph_resolved_edge,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn graph_unresolved_edges(
        &self,
        generation: u64,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphUnresolvedEdgeRecord>> {
        let mut statement = self.connection.prepare(GRAPH_UNRESOLVED_EDGES_SQL)?;
        let rows = statement.query_map(
            params![generation as i64, limit_to_i64(limit)],
            row_to_graph_unresolved_edge,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn graph_orphan_files(
        &self,
        generation: u64,
        include_unresolved: bool,
        limit: usize,
    ) -> MetadataStoreResult<Vec<GraphFileRecord>> {
        let sql = if include_unresolved {
            GRAPH_ORPHANS_WITH_UNRESOLVED_SQL
        } else {
            GRAPH_ORPHANS_RESOLVED_ONLY_SQL
        };
        let mut statement = self.connection.prepare(sql)?;
        let rows = statement.query_map(
            params![generation as i64, limit_to_i64(limit)],
            row_to_graph_file,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn graph_tags_for_files(
        &self,
        file_ids: &[String],
        max_tags_per_file: usize,
    ) -> MetadataStoreResult<Vec<GraphTagRecord>> {
        if file_ids.is_empty() || max_tags_per_file == 0 {
            return Ok(Vec::new());
        }

        let mut tags = Vec::new();
        for chunk in file_ids.chunks(400) {
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
            let mut statement = self.connection.prepare(&sql)?;
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

    pub fn graph_visible_node_count(
        &self,
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
        self.connection
            .query_row(&sql, params![generation as i64], |row| row.get::<_, i64>(0))
            .map(|count| count as usize)
            .map_err(Into::into)
    }

    pub fn graph_visible_edge_count(
        &self,
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
        self.connection
            .query_row(&sql, params![generation as i64], |row| row.get::<_, i64>(0))
            .map(|count| count as usize)
            .map_err(Into::into)
    }

    pub fn graph_query_plan_summaries(
        &self,
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
            let mut statement = self.connection.prepare(&explain)?;
            if stage == GraphQueryStage::Tags {
                let rows =
                    statement.query_map(params!["graph-plan-placeholder", 1_i64], |row| {
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

    pub fn tag_note_projections(
        &self,
        tag: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<TagNoteProjection>> {
        let mut statement = self.connection.prepare(
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

    pub fn properties(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<PropertyRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT file_id, key, value_kind, value_json FROM properties \
             WHERE file_id = ?1 ORDER BY key, id LIMIT ?2 OFFSET ?3",
        )?;
        let rows = statement.query_map(
            params![file_id, limit as i64, offset as i64],
            row_to_property,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn property_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<PropertyProjection>> {
        let properties = self.properties(file_id, offset, limit)?;
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

    pub fn headings(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<HeadingRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT file_id, slug, title, level, byte_offset FROM headings \
             WHERE file_id = ?1 ORDER BY byte_offset, id LIMIT ?2 OFFSET ?3",
        )?;
        let rows = statement.query_map(
            params![file_id, limit as i64, offset as i64],
            row_to_heading,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn attachments(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<AttachmentRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT source_file_id, source, raw_target, state, state_detail FROM attachments \
             WHERE source_file_id = ?1 ORDER BY raw_target, id LIMIT ?2 OFFSET ?3",
        )?;
        let rows = statement.query_map(
            params![file_id, limit as i64, offset as i64],
            row_to_attachment,
        )?;
        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    pub fn attachment_projections(
        &self,
        file_id: &str,
        offset: usize,
        limit: usize,
    ) -> MetadataStoreResult<Vec<AttachmentProjection>> {
        let attachments = self.attachments(file_id, offset, limit)?;
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

const GRAPH_FILES_SQL: &str = "
    SELECT file_id, relative_path
    FROM files
    WHERE kind = 'markdown'
      AND status IN ('parsed', 'search_indexed')
      AND generation = ?1
    ORDER BY file_id
    LIMIT ?2";

const GRAPH_RESOLVED_EDGES_SQL: &str = "
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

const GRAPH_RESOLVED_EDGES_COMPACT_SQL: &str = "
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

const GRAPH_UNRESOLVED_EDGES_SQL: &str = "
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

const GRAPH_ORPHANS_RESOLVED_ONLY_SQL: &str = "
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

const GRAPH_ORPHANS_WITH_UNRESOLVED_SQL: &str = "
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

const GRAPH_TAGS_PLAN_SQL: &str = "
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

const GRAPH_RESOLVED_SOURCE_NODES_SQL: &str = "
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

const GRAPH_RESOLVED_TARGET_NODES_SQL: &str = "
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

const GRAPH_UNRESOLVED_SOURCE_NODES_SQL: &str = "
    SELECT links.source_file_id AS node_id
    FROM links INDEXED BY idx_links_unresolved_source_target_key
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    WHERE links.resolved_target_file_id IS NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1";

const GRAPH_UNRESOLVED_TARGET_NODES_SQL: &str = "
    SELECT 'unresolved:' || links.target_key AS node_id
    FROM links INDEXED BY idx_links_unresolved_source_target_key
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    WHERE links.resolved_target_file_id IS NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1";

const GRAPH_RESOLVED_EDGE_GROUPS_SQL: &str = "
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

const GRAPH_UNRESOLVED_EDGE_GROUPS_SQL: &str = "
    SELECT links.source_file_id, links.target_key
    FROM links INDEXED BY idx_links_unresolved_source_target_key
    CROSS JOIN files AS source_files ON source_files.file_id = links.source_file_id
    WHERE links.resolved_target_file_id IS NULL
      AND source_files.kind = 'markdown'
      AND source_files.status IN ('parsed', 'search_indexed')
      AND source_files.generation = ?1
    GROUP BY links.source_file_id, links.target_key";

const GRAPH_ORPHAN_NODES_RESOLVED_ONLY_SQL: &str = "
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

const GRAPH_ORPHAN_NODES_WITH_UNRESOLVED_SQL: &str = "
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

pub fn slugify_heading(title: &str) -> String {
    title
        .trim()
        .to_lowercase()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("-")
}

fn truncate_index_error(error: &str) -> String {
    let trimmed = error.trim();
    if trimmed.chars().count() <= MAX_INDEX_ERROR_CHARS {
        return trimmed.to_string();
    }

    trimmed.chars().take(MAX_INDEX_ERROR_CHARS).collect()
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

fn upsert_file(connection: &Connection, file: &FileRecord) -> MetadataStoreResult<()> {
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

fn delete_child_records(connection: &Connection, file_id: &str) -> MetadataStoreResult<()> {
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

fn insert_link(connection: &Connection, link: &LinkEdgeRecord) -> MetadataStoreResult<()> {
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

fn insert_tag(connection: &Connection, tag: &TagRecord) -> MetadataStoreResult<()> {
    connection.execute(
        "INSERT INTO tags (file_id, tag, source) VALUES (?1, ?2, ?3)",
        params![&tag.file_id, &tag.tag, tag_source_to_str(tag.source)],
    )?;
    Ok(())
}

fn insert_property(connection: &Connection, property: &PropertyRecord) -> MetadataStoreResult<()> {
    let (kind, json) = property_value_to_storage(&property.value)?;
    connection.execute(
        "INSERT INTO properties (file_id, key, value_kind, value_json) VALUES (?1, ?2, ?3, ?4)",
        params![&property.file_id, &property.key, kind, json],
    )?;
    Ok(())
}

fn insert_heading(connection: &Connection, heading: &HeadingRecord) -> MetadataStoreResult<()> {
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

fn insert_attachment(
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

fn row_to_file_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<FileRecord> {
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

fn row_to_file_lookup_projection(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<FileLookupProjection> {
    let relative_path = PathBuf::from(row.get::<_, String>(1)?);
    Ok(FileLookupProjection {
        file_id: row.get(0)?,
        display_path: path_to_string(&relative_path),
        relative_path,
    })
}

fn row_to_link_projection(row: &rusqlite::Row<'_>) -> rusqlite::Result<LinkProjection> {
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

fn row_to_tag_note_projection(row: &rusqlite::Row<'_>) -> rusqlite::Result<TagNoteProjection> {
    let source: String = row.get(3)?;
    Ok(TagNoteProjection {
        file_id: row.get(0)?,
        relative_path: PathBuf::from(row.get::<_, String>(1)?),
        tag: row.get(2)?,
        source: tag_source_from_str(&source).map_err(|_| rusqlite::Error::InvalidQuery)?,
    })
}

fn row_to_link(row: &rusqlite::Row<'_>) -> rusqlite::Result<LinkEdgeRecord> {
    Ok(LinkEdgeRecord {
        source_file_id: row.get(0)?,
        target_text: row.get(1)?,
        resolved_target_file_id: row.get(2)?,
        heading: row.get(3)?,
        alias: row.get(4)?,
        is_embed: row.get::<_, i64>(5)? == 1,
    })
}

fn row_to_tag(row: &rusqlite::Row<'_>) -> rusqlite::Result<TagRecord> {
    let source: String = row.get(2)?;
    Ok(TagRecord {
        file_id: row.get(0)?,
        tag: row.get(1)?,
        source: tag_source_from_str(&source).map_err(|_| rusqlite::Error::InvalidQuery)?,
    })
}

fn row_to_graph_file(row: &rusqlite::Row<'_>) -> rusqlite::Result<GraphFileRecord> {
    Ok(GraphFileRecord {
        file_id: row.get(0)?,
        relative_path: PathBuf::from(row.get::<_, String>(1)?),
    })
}

fn row_to_graph_resolved_edge(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<GraphResolvedEdgeRecord> {
    Ok(GraphResolvedEdgeRecord {
        source_file_id: row.get(0)?,
        source_relative_path: PathBuf::from(row.get::<_, String>(1)?),
        target_file_id: row.get(2)?,
        target_relative_path: PathBuf::from(row.get::<_, String>(3)?),
        weight: row.get::<_, i64>(4)? as usize,
    })
}

fn row_to_graph_unresolved_edge(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<GraphUnresolvedEdgeRecord> {
    Ok(GraphUnresolvedEdgeRecord {
        source_file_id: row.get(0)?,
        source_relative_path: PathBuf::from(row.get::<_, String>(1)?),
        target_text: row.get(2)?,
        weight: row.get::<_, i64>(3)? as usize,
    })
}

fn row_to_graph_tag(row: &rusqlite::Row<'_>) -> rusqlite::Result<GraphTagRecord> {
    Ok(GraphTagRecord {
        file_id: row.get(0)?,
        tag: row.get(1)?,
    })
}

fn row_to_property(row: &rusqlite::Row<'_>) -> rusqlite::Result<PropertyRecord> {
    let kind: String = row.get(2)?;
    let json: String = row.get(3)?;
    Ok(PropertyRecord {
        file_id: row.get(0)?,
        key: row.get(1)?,
        value: property_value_from_storage(&kind, &json)
            .map_err(|_| rusqlite::Error::InvalidQuery)?,
    })
}

fn row_to_heading(row: &rusqlite::Row<'_>) -> rusqlite::Result<HeadingRecord> {
    Ok(HeadingRecord {
        file_id: row.get(0)?,
        slug: row.get(1)?,
        title: row.get(2)?,
        level: row.get::<_, i64>(3)? as u8,
        byte_offset: row.get::<_, Option<i64>>(4)?.map(|offset| offset as u64),
    })
}

fn row_to_attachment(row: &rusqlite::Row<'_>) -> rusqlite::Result<AttachmentRecord> {
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

fn property_value_to_storage(
    value: &IndexPropertyValue,
) -> MetadataStoreResult<(&'static str, String)> {
    let stored = match value {
        IndexPropertyValue::String(value) => ("string", serde_json::to_string(value)),
        IndexPropertyValue::Bool(value) => ("bool", serde_json::to_string(value)),
        IndexPropertyValue::List(values) => ("list", serde_json::to_string(values)),
    };
    Ok((
        stored.0,
        stored
            .1
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property"))?,
    ))
}

fn property_value_from_storage(kind: &str, json: &str) -> MetadataStoreResult<IndexPropertyValue> {
    match kind {
        "string" => serde_json::from_str(json)
            .map(IndexPropertyValue::String)
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property")),
        "bool" => serde_json::from_str(json)
            .map(IndexPropertyValue::Bool)
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property")),
        "list" => serde_json::from_str(json)
            .map(IndexPropertyValue::List)
            .map_err(|_| MetadataStoreError::InvalidStoredValue("property")),
        _ => Err(MetadataStoreError::InvalidStoredValue("property")),
    }
}

fn attachment_state_to_storage(
    state: &AttachmentResolutionState,
) -> MetadataStoreResult<(&'static str, Option<String>)> {
    match state {
        AttachmentResolutionState::Resolved { relative_path } => {
            Ok(("resolved", Some(path_to_string(relative_path))))
        }
        AttachmentResolutionState::Missing => Ok(("missing", None)),
        AttachmentResolutionState::Duplicate { candidates } => Ok((
            "duplicate",
            Some(
                serde_json::to_string(
                    &candidates
                        .iter()
                        .map(|path| path_to_string(path))
                        .collect::<Vec<_>>(),
                )
                .map_err(|_| MetadataStoreError::InvalidStoredValue("attachment"))?,
            ),
        )),
        AttachmentResolutionState::Remote => Ok(("remote", None)),
        AttachmentResolutionState::Rejected(reason) => {
            Ok(("rejected", Some(format!("{reason:?}"))))
        }
        AttachmentResolutionState::Unsupported => Ok(("unsupported", None)),
    }
}

fn attachment_state_from_storage(
    state: &str,
    detail: Option<&str>,
) -> MetadataStoreResult<AttachmentResolutionState> {
    match state {
        "resolved" => Ok(AttachmentResolutionState::Resolved {
            relative_path: PathBuf::from(required_detail(detail, "attachment")?),
        }),
        "missing" => Ok(AttachmentResolutionState::Missing),
        "duplicate" => {
            let values: Vec<String> = serde_json::from_str(required_detail(detail, "attachment")?)
                .map_err(|_| MetadataStoreError::InvalidStoredValue("attachment"))?;
            Ok(AttachmentResolutionState::Duplicate {
                candidates: values.into_iter().map(PathBuf::from).collect(),
            })
        }
        "remote" => Ok(AttachmentResolutionState::Remote),
        "rejected" => Ok(AttachmentResolutionState::Rejected(
            reject_reason_from_str(required_detail(detail, "attachment")?)
                .ok_or(MetadataStoreError::InvalidStoredValue("attachment"))?,
        )),
        "unsupported" => Ok(AttachmentResolutionState::Unsupported),
        _ => Err(MetadataStoreError::InvalidStoredValue("attachment")),
    }
}

fn required_detail<'a>(
    detail: Option<&'a str>,
    field: &'static str,
) -> MetadataStoreResult<&'a str> {
    detail.ok_or(MetadataStoreError::InvalidStoredValue(field))
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn optional_path(value: Option<String>) -> Option<PathBuf> {
    value.map(PathBuf::from)
}

fn bool_to_int(value: bool) -> i64 {
    if value { 1 } else { 0 }
}

fn int_to_bool(value: i64) -> bool {
    value != 0
}

fn system_time_to_unix_ms(time: Option<SystemTime>) -> Option<i64> {
    time.and_then(|time| {
        time.duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_millis() as i64)
    })
}

fn unix_ms_to_system_time(ms: Option<i64>) -> Option<SystemTime> {
    ms.map(|ms| UNIX_EPOCH + Duration::from_millis(ms as u64))
}

fn limit_to_i64(limit: usize) -> i64 {
    limit.min(i64::MAX as usize) as i64
}

fn scan_kind_to_str(kind: ScanEntryKind) -> &'static str {
    match kind {
        ScanEntryKind::Markdown => "markdown",
        ScanEntryKind::Attachment => "attachment",
        ScanEntryKind::Other => "other",
    }
}

fn scan_kind_from_str(kind: &str) -> Result<ScanEntryKind, ()> {
    match kind {
        "markdown" => Ok(ScanEntryKind::Markdown),
        "attachment" => Ok(ScanEntryKind::Attachment),
        "other" => Ok(ScanEntryKind::Other),
        _ => Err(()),
    }
}

fn file_status_to_str(status: FileIndexStatus) -> &'static str {
    match status {
        FileIndexStatus::SeenMetadata => "seen_metadata",
        FileIndexStatus::Parsed => "parsed",
        FileIndexStatus::SearchIndexed => "search_indexed",
        FileIndexStatus::Tombstoned => "tombstoned",
        FileIndexStatus::Error => "error",
    }
}

fn file_status_from_str(status: &str) -> Result<FileIndexStatus, ()> {
    match status {
        "seen_metadata" => Ok(FileIndexStatus::SeenMetadata),
        "parsed" => Ok(FileIndexStatus::Parsed),
        "search_indexed" => Ok(FileIndexStatus::SearchIndexed),
        "tombstoned" => Ok(FileIndexStatus::Tombstoned),
        "error" => Ok(FileIndexStatus::Error),
        _ => Err(()),
    }
}

fn tag_source_to_str(source: TagSource) -> &'static str {
    match source {
        TagSource::Inline => "inline",
        TagSource::Frontmatter => "frontmatter",
    }
}

fn tag_source_from_str(source: &str) -> Result<TagSource, ()> {
    match source {
        "inline" => Ok(TagSource::Inline),
        "frontmatter" => Ok(TagSource::Frontmatter),
        _ => Err(()),
    }
}

fn attachment_source_to_str(source: AttachmentReferenceSource) -> &'static str {
    match source {
        AttachmentReferenceSource::WikiEmbed => "wiki_embed",
        AttachmentReferenceSource::MarkdownImage => "markdown_image",
        AttachmentReferenceSource::MarkdownLink => "markdown_link",
    }
}

fn attachment_source_from_str(source: &str) -> Result<AttachmentReferenceSource, ()> {
    match source {
        "wiki_embed" => Ok(AttachmentReferenceSource::WikiEmbed),
        "markdown_image" => Ok(AttachmentReferenceSource::MarkdownImage),
        "markdown_link" => Ok(AttachmentReferenceSource::MarkdownLink),
        _ => Err(()),
    }
}

fn reject_reason_from_str(reason: &str) -> Option<crate::attachments::AttachmentRejectReason> {
    match reason {
        "ContainsNul" => Some(crate::attachments::AttachmentRejectReason::ContainsNul),
        "UrlScheme" => Some(crate::attachments::AttachmentRejectReason::UrlScheme),
        "TildePrefix" => Some(crate::attachments::AttachmentRejectReason::TildePrefix),
        "AbsolutePath" => Some(crate::attachments::AttachmentRejectReason::AbsolutePath),
        "OutsideVault" => Some(crate::attachments::AttachmentRejectReason::OutsideVault),
        "SymlinkEscape" => Some(crate::attachments::AttachmentRejectReason::SymlinkEscape),
        "InvalidRoot" => Some(crate::attachments::AttachmentRejectReason::InvalidRoot),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::attachments::{
        AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
    };
    use crate::parser::PropertyValue;
    use crate::paths::VaultRoot;
    use crate::scanner::scan_vault;
    use std::{path::PathBuf, time::Instant};

    #[test]
    fn fixture_file_transitions_from_seen_to_search_indexed() {
        let entry = fixture_entry("Home.md");
        let mut record = FileRecord::from_scan_entry(&entry, 1);

        assert_eq!(record.status, FileIndexStatus::SeenMetadata);
        assert_eq!(record.generation, 1);
        assert_eq!(record.file_id, "home.md");
        assert!(record.content_hash.is_none());

        record.mark_parsed("hash-home");
        assert_eq!(record.status, FileIndexStatus::Parsed);
        assert_eq!(record.content_hash.as_deref(), Some("hash-home"));

        record.mark_search_indexed();
        assert_eq!(record.status, FileIndexStatus::SearchIndexed);
        assert!(record.last_error.is_none());
    }

    #[test]
    fn fixture_file_can_be_tombstoned() {
        let entry = fixture_entry("Home.md");
        let mut record = FileRecord::from_scan_entry(&entry, 1);

        record.mark_tombstoned(2);

        assert_eq!(record.status, FileIndexStatus::Tombstoned);
        assert_eq!(record.generation, 2);
        assert!(record.last_error.is_none());
    }

    #[test]
    fn fixture_file_can_enter_error_state_with_bounded_error() {
        let entry = fixture_entry("Home.md");
        let mut record = FileRecord::from_scan_entry(&entry, 1);
        let error = "x".repeat(MAX_INDEX_ERROR_CHARS + 20);

        record.mark_error(&error);

        assert_eq!(record.status, FileIndexStatus::Error);
        assert_eq!(
            record.last_error.as_ref().expect("error").chars().count(),
            MAX_INDEX_ERROR_CHARS
        );
    }

    #[test]
    fn schema_metadata_and_related_records_are_represented() {
        let metadata = IndexSchemaMetadata::new("sqlite", "3.0", "unicode61", 7);
        assert_eq!(metadata.schema_version, INDEX_SCHEMA_VERSION);
        assert_eq!(metadata.generation, 7);

        let property = PropertyRecord::from_property_value(
            "home.md",
            "tags",
            &PropertyValue::List(vec!["home".to_string(), "project/native".to_string()]),
        );
        assert_eq!(
            property.value,
            IndexPropertyValue::List(vec!["home".to_string(), "project/native".to_string()])
        );

        let heading = HeadingRecord {
            file_id: "home.md".to_string(),
            slug: slugify_heading("Deep Heading"),
            title: "Deep Heading".to_string(),
            level: 2,
            byte_offset: None,
        };
        assert_eq!(heading.slug, "deep-heading");

        let link = LinkEdgeRecord {
            source_file_id: "home.md".to_string(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some("folder/target.md".to_string()),
            heading: Some("Deep Heading".to_string()),
            alias: None,
            is_embed: false,
        };
        assert_eq!(
            link.resolved_target_file_id.as_deref(),
            Some("folder/target.md")
        );

        let tag = TagRecord {
            file_id: "home.md".to_string(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };
        assert_eq!(tag.source, TagSource::Inline);

        let attachment = AttachmentRecord {
            source_file_id: "attachments.md".to_string(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };
        assert!(matches!(
            attachment.state,
            AttachmentResolutionState::Resolved { .. }
        ));
    }

    #[test]
    fn metadata_store_inserts_updates_and_deletes_fixture_records() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut file = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        file.mark_parsed("hash-home");

        let link = LinkEdgeRecord {
            source_file_id: file.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some("folder/target.md".to_string()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: file.file_id.clone(),
            tag: "home".to_string(),
            source: TagSource::Frontmatter,
        };
        let property = PropertyRecord::from_property_value(
            file.file_id.clone(),
            "status",
            &PropertyValue::String("active".to_string()),
        );
        let heading = HeadingRecord {
            file_id: file.file_id.clone(),
            slug: slugify_heading("Home"),
            title: "Home".to_string(),
            level: 1,
            byte_offset: Some(0),
        };
        let attachment = AttachmentRecord {
            source_file_id: file.file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };

        store
            .replace_file_records(
                &file,
                &[link],
                &[tag],
                &[property],
                &[heading],
                &[attachment],
            )
            .expect("insert records");

        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 1);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 1);
        assert_eq!(store.row_count(MetadataTable::Tags).expect("tags"), 1);
        assert_eq!(
            store
                .row_count(MetadataTable::Properties)
                .expect("properties"),
            1
        );
        assert_eq!(
            store.row_count(MetadataTable::Headings).expect("headings"),
            1
        );
        assert_eq!(
            store
                .row_count(MetadataTable::Attachments)
                .expect("attachments"),
            1
        );

        file.mark_search_indexed();
        store
            .replace_file_records(&file, &[], &[], &[], &[], &[])
            .expect("update records");
        let stored = store
            .get_file(&file.file_id)
            .expect("get file")
            .expect("stored file");
        assert_eq!(stored.status, FileIndexStatus::SearchIndexed);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 0);

        store.delete_file(&file.file_id).expect("delete file");
        assert!(
            store
                .get_file(&file.file_id)
                .expect("get deleted")
                .is_none()
        );
        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 0);
    }

    #[test]
    fn metadata_store_bulk_loads_fixture_records() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut home = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let link = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: home.file_id.clone(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };

        store
            .bulk_load_file_records(&[
                IndexedFileRecords {
                    file: home.clone(),
                    links: vec![link],
                    tags: vec![tag],
                    properties: Vec::new(),
                    headings: Vec::new(),
                    attachments: Vec::new(),
                },
                IndexedFileRecords {
                    file: target.clone(),
                    links: Vec::new(),
                    tags: Vec::new(),
                    properties: Vec::new(),
                    headings: Vec::new(),
                    attachments: Vec::new(),
                },
            ])
            .expect("bulk load");

        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 2);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 1);
        assert_eq!(
            store
                .backlink_projections(&target.file_id, 0, 10)
                .expect("backlinks")
                .len(),
            1
        );
        assert!(projection_index_exists(
            &store.connection,
            "idx_links_source_file_id"
        ));
    }

    #[test]
    fn metadata_store_returns_whole_vault_graph_bulk_records() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v2", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut home = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let mut orphan = FileRecord::from_scan_entry(&fixture_entry("Docs/Guide.md"), 1);
        orphan.mark_parsed("hash-guide");
        let mut old_generation =
            FileRecord::from_scan_entry(&fixture_entry("Folder/Duplicate.md"), 0);
        old_generation.mark_search_indexed();
        let mut attachment =
            FileRecord::from_scan_entry(&fixture_entry("attachments/diagram.svg"), 1);
        attachment.mark_search_indexed();

        let resolved = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let unresolved = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "ÄMissing".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: None,
            is_embed: false,
        };
        let unresolved_case_variant = LinkEdgeRecord {
            target_text: "ämissing".to_string(),
            ..unresolved.clone()
        };
        let attachment_link = LinkEdgeRecord {
            source_file_id: attachment.file_id.clone(),
            target_text: "Home".to_string(),
            resolved_target_file_id: Some(home.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let stale_link = LinkEdgeRecord {
            source_file_id: old_generation.file_id.clone(),
            target_text: "Docs/Guide".to_string(),
            resolved_target_file_id: Some(orphan.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };

        store
            .replace_file_records(
                &home,
                &[
                    resolved.clone(),
                    resolved.clone(),
                    unresolved.clone(),
                    unresolved.clone(),
                    unresolved_case_variant,
                ],
                &[
                    TagRecord {
                        file_id: home.file_id.clone(),
                        tag: "project/native".to_string(),
                        source: TagSource::Inline,
                    },
                    TagRecord {
                        file_id: home.file_id.clone(),
                        tag: "work".to_string(),
                        source: TagSource::Frontmatter,
                    },
                ],
                &[],
                &[],
                &[],
            )
            .expect("home records");
        store
            .replace_file_records(&target, &[], &[], &[], &[], &[])
            .expect("target records");
        store
            .replace_file_records(&orphan, &[], &[], &[], &[], &[])
            .expect("orphan records");
        store
            .replace_file_records(&old_generation, &[stale_link], &[], &[], &[], &[])
            .expect("old records");
        store
            .replace_file_records(&attachment, &[attachment_link], &[], &[], &[], &[])
            .expect("attachment records");

        let files = store.graph_files(1, 10).expect("graph files");
        let file_ids = files
            .iter()
            .map(|file| file.file_id.as_str())
            .collect::<std::collections::BTreeSet<_>>();
        let expected_file_ids = [
            orphan.file_id.as_str(),
            target.file_id.as_str(),
            home.file_id.as_str(),
        ]
        .into_iter()
        .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(file_ids, expected_file_ids);
        assert_eq!(
            files
                .iter()
                .find(|file| file.file_id == home.file_id)
                .expect("home graph file")
                .relative_path,
            home.relative_path
        );
        assert!(!files.iter().any(|file| file.file_id == attachment.file_id));
        assert!(
            !files
                .iter()
                .any(|file| file.file_id == old_generation.file_id)
        );

        let resolved_edges = store.graph_resolved_edges(1, 10).expect("resolved edges");
        assert_eq!(resolved_edges.len(), 1);
        assert_eq!(resolved_edges[0].source_file_id, home.file_id);
        assert_eq!(resolved_edges[0].source_relative_path, home.relative_path);
        assert_eq!(resolved_edges[0].target_file_id, target.file_id);
        assert_eq!(resolved_edges[0].target_relative_path, target.relative_path);
        assert_eq!(resolved_edges[0].weight, 2);

        let unresolved_edges = store
            .graph_unresolved_edges(1, 10)
            .expect("unresolved edges");
        assert_eq!(unresolved_edges.len(), 1);
        assert_eq!(unresolved_edges[0].source_file_id, home.file_id);
        assert_eq!(unresolved_edges[0].source_relative_path, home.relative_path);
        assert_eq!(unresolved_edges[0].target_text, "ÄMissing");
        assert_eq!(unresolved_edges[0].weight, 3);

        let orphans = store.graph_orphan_files(1, false, 10).expect("orphans");
        assert_eq!(
            orphans,
            vec![GraphFileRecord {
                file_id: orphan.file_id.clone(),
                relative_path: orphan.relative_path.clone(),
            }]
        );

        let tags = store
            .graph_tags_for_files(std::slice::from_ref(&home.file_id), 10)
            .expect("graph tags");
        assert_eq!(tags.len(), 2);
        assert!(tags.iter().all(|tag| tag.file_id == home.file_id));
        assert_eq!(
            store
                .graph_visible_node_count(1, false, false)
                .expect("resolved node count"),
            2
        );
        assert_eq!(
            store
                .graph_visible_node_count(1, true, true)
                .expect("full node count"),
            4
        );
        assert_eq!(
            store
                .graph_visible_edge_count(1, false)
                .expect("resolved edge count"),
            1
        );
        assert_eq!(
            store
                .graph_visible_edge_count(1, true)
                .expect("full edge count"),
            2
        );

        let plans = store.graph_query_plan_summaries(1).expect("plans");
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::Files)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::ResolvedEdges)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::UnresolvedEdges)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::OrphansResolvedOnly)
        );
        assert!(
            plans
                .iter()
                .any(|plan| plan.stage == GraphQueryStage::OrphansWithUnresolved)
        );
        assert!(plans.iter().any(|plan| plan.stage == GraphQueryStage::Tags));
        assert!(plans.iter().all(|plan| !plan.detail.contains("Home.md")));
        let unresolved_plan_details = plans
            .iter()
            .filter(|plan| plan.stage == GraphQueryStage::UnresolvedEdges)
            .map(|plan| plan.detail.as_str())
            .collect::<Vec<_>>();
        assert!(
            unresolved_plan_details
                .iter()
                .any(|detail| detail.contains("idx_links_unresolved_source_target_key"))
        );
        assert!(
            unresolved_plan_details
                .iter()
                .all(|detail| !detail.contains("USE TEMP B-TREE FOR GROUP BY"))
        );
        let edge_count_plan_sql = format!(
            "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM ({GRAPH_RESOLVED_EDGE_GROUPS_SQL} UNION ALL {GRAPH_UNRESOLVED_EDGE_GROUPS_SQL})"
        );
        let mut statement = store
            .connection
            .prepare(&edge_count_plan_sql)
            .expect("edge count plan");
        let edge_count_plan_details = statement
            .query_map(params![1_i64], |row| row.get::<_, String>(3))
            .expect("edge count plan rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("edge count plan details");
        assert!(
            edge_count_plan_details
                .iter()
                .any(|detail| detail.contains("idx_links_unresolved_source_target_key"))
        );
        assert!(
            edge_count_plan_details
                .iter()
                .all(|detail| !detail.contains("USE TEMP B-TREE FOR GROUP BY"))
        );
    }

    #[test]
    fn metadata_store_replaces_file_records_batch() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let home = metadata_records_for_file("Home.md", 1);
        let guide = metadata_records_for_file("Docs/Guide.md", 1);

        store
            .replace_file_records_batch(&[home.clone(), guide.clone()])
            .expect("batch insert");

        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 2);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 2);
        assert_eq!(store.row_count(MetadataTable::Tags).expect("tags"), 2);
        assert_eq!(
            store
                .row_count(MetadataTable::Properties)
                .expect("properties"),
            2
        );
        assert_eq!(
            store.row_count(MetadataTable::Headings).expect("headings"),
            2
        );
        assert_eq!(
            store
                .row_count(MetadataTable::Attachments)
                .expect("attachments"),
            2
        );
    }

    #[test]
    fn metadata_schema_has_projection_indexes() {
        let connection = Connection::open_in_memory().expect("connection");
        create_schema(&connection).expect("schema");
        let mut statement = connection
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index'")
            .expect("index query");
        let indexes = statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("index rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("index names");

        for expected in [
            "idx_files_relative_path",
            "idx_files_kind_status_generation",
            "idx_links_source_file_id",
            "idx_links_resolved_target_file_id",
            "idx_links_resolved_pair",
            "idx_links_unresolved_target_text",
            "idx_links_unresolved_source_target_key",
            "idx_tags_file_id",
            "idx_tags_tag",
            "idx_properties_file_id",
            "idx_headings_file_id",
            "idx_attachments_source_file_id",
        ] {
            assert!(
                indexes.iter().any(|index| index == expected),
                "missing index {expected}"
            );
        }
    }

    #[test]
    fn metadata_projections_return_display_ready_rows() {
        let ProjectionFixture {
            store,
            home,
            target,
            guide,
            ..
        } = projection_fixture();

        let lookup = store.lookup_file("Home.md").expect("lookup").expect("home");
        assert_eq!(lookup.file_id, home.file_id);
        assert_eq!(lookup.display_path, "Home.md");
        assert!(store.lookup_file("Missing.md").expect("missing").is_none());

        let tree = store.file_tree_projection(0, 2).expect("file tree");
        assert_eq!(
            tree.iter()
                .map(|item| item.display_path.as_str())
                .collect::<Vec<_>>(),
            vec!["Docs/Guide.md", "Folder/Target.md"]
        );
        assert!(
            tree.iter()
                .all(|item| item.file.kind == ScanEntryKind::Markdown)
        );
        assert!(
            store
                .file_tree_projection(0, 10)
                .expect("markdown tree")
                .iter()
                .all(|item| item.display_path.ends_with(".md"))
        );

        let backlinks = store
            .backlink_projections(&target.file_id, 0, 10)
            .expect("backlinks");
        assert_eq!(backlinks.len(), 1);
        assert_eq!(backlinks[0].source_file_id, home.file_id);
        assert_eq!(
            backlinks[0].source_relative_path.as_deref(),
            Some(Path::new("Home.md"))
        );
        assert_eq!(backlinks[0].target_text, "Folder/Target");

        let outgoing = store
            .outgoing_link_projections(&home.file_id, 0, 10)
            .expect("outgoing");
        assert_eq!(outgoing.len(), 2);
        assert!(outgoing.iter().any(|link| {
            link.target_file_id.as_deref() == Some(target.file_id.as_str())
                && link.target_relative_path.as_deref() == Some(Path::new("Folder/Target.md"))
        }));
        assert!(outgoing.iter().any(|link| {
            link.target_text == "Missing Note" && link.target_relative_path.is_none()
        }));

        let tags = store.tags(&home.file_id, 0, 10).expect("current tags");
        assert_eq!(tags.len(), 2);
        let tag_notes = store
            .tag_note_projections("project/native", 0, 2)
            .expect("tag notes");
        assert_eq!(tag_notes.len(), 2);
        assert_eq!(tag_notes[0].relative_path, PathBuf::from("Docs/Guide.md"));
        assert_eq!(
            tag_notes[1].relative_path,
            PathBuf::from("Folder/Target.md")
        );
        assert_eq!(
            store
                .tag_note_projections("project/native", 0, 10)
                .expect("deduped tag notes")
                .len(),
            3
        );

        let properties = store
            .property_projections(&home.file_id, 0, 10)
            .expect("properties");
        assert_eq!(
            properties
                .iter()
                .map(|property| (property.key.as_str(), property.display_value.as_str()))
                .collect::<Vec<_>>(),
            vec![("active", "true"), ("status", "stable"), ("tags", "a, b")]
        );

        let attachments = store
            .attachment_projections(&home.file_id, 0, 10)
            .expect("attachments");
        assert_eq!(attachments.len(), 6);
        assert!(attachments.iter().any(|attachment| {
            attachment.raw_target == "assets/image.png"
                && attachment.resolved_relative_path.as_deref()
                    == Some(Path::new("assets/image.png"))
        }));
        assert!(
            attachments
                .iter()
                .any(|attachment| matches!(attachment.state, AttachmentResolutionState::Missing))
        );
        assert!(attachments.iter().any(|attachment| matches!(
            attachment.state,
            AttachmentResolutionState::Duplicate { .. }
        )));
        assert!(
            attachments
                .iter()
                .any(|attachment| matches!(attachment.state, AttachmentResolutionState::Remote))
        );
        assert!(
            attachments.iter().any(|attachment| matches!(
                attachment.state,
                AttachmentResolutionState::Rejected(_)
            ))
        );
        assert!(
            attachments.iter().any(|attachment| matches!(
                attachment.state,
                AttachmentResolutionState::Unsupported
            ))
        );

        assert_eq!(guide.relative_path, PathBuf::from("Docs/Guide.md"));
    }

    #[test]
    fn projection_queries_are_bounded_smoke() {
        let ProjectionFixture {
            store,
            home,
            target,
            ..
        } = projection_fixture();
        let started = Instant::now();

        assert!(store.file_tree_projection(0, 2).expect("tree").len() <= 2);
        assert!(
            store
                .backlink_projections(&target.file_id, 0, 2)
                .expect("backlinks")
                .len()
                <= 2
        );
        assert!(
            store
                .outgoing_link_projections(&home.file_id, 0, 2)
                .expect("outgoing")
                .len()
                <= 2
        );
        assert!(
            store
                .tag_note_projections("project/native", 0, 2)
                .expect("tags")
                .len()
                <= 2
        );
        assert!(
            store
                .property_projections(&home.file_id, 0, 2)
                .expect("properties")
                .len()
                <= 2
        );
        assert!(
            store
                .attachment_projections(&home.file_id, 0, 2)
                .expect("attachments")
                .len()
                <= 2
        );

        assert!(started.elapsed().as_millis() < 250);
    }

    #[test]
    fn metadata_store_batch_is_atomic_on_mid_batch_failure() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let original_home = metadata_records_for_file("Home.md", 1);
        store
            .replace_file_records_batch(std::slice::from_ref(&original_home))
            .expect("initial insert");

        let mut changed_home = metadata_records_for_file("Home.md", 2);
        changed_home.file.mark_search_indexed();
        let mut invalid_guide = metadata_records_for_file("Docs/Guide.md", 2);
        invalid_guide.links[0].source_file_id = "missing.md".to_string();

        let result = store.replace_file_records_batch(&[changed_home, invalid_guide]);

        assert!(matches!(result, Err(MetadataStoreError::Sqlite(_))));
        let stored_home = store
            .get_file(&original_home.file.file_id)
            .expect("home lookup")
            .expect("home remains");
        assert_eq!(stored_home.status, FileIndexStatus::Parsed);
        assert_eq!(stored_home.generation, 1);
        assert_eq!(store.row_count(MetadataTable::Files).expect("files"), 1);
        assert_eq!(store.row_count(MetadataTable::Links).expect("links"), 1);
    }

    #[test]
    fn metadata_store_reports_schema_mismatch() {
        let expected = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let stored = IndexSchemaMetadata::new("sqlite", "metadata-v2", "none", 1);
        let connection = Connection::open_in_memory().expect("connection");
        create_schema(&connection).expect("schema");
        write_schema_metadata(&connection, &stored).expect("metadata");

        let result = MetadataStore::from_connection(connection, &expected);

        assert!(matches!(
            result,
            Err(MetadataStoreError::SchemaMismatch { .. })
        ));
    }

    struct ProjectionFixture {
        store: MetadataStore,
        home: FileRecord,
        target: FileRecord,
        guide: FileRecord,
    }

    fn projection_fixture() -> ProjectionFixture {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut home = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let mut guide = FileRecord::from_scan_entry(&fixture_entry("Docs/Guide.md"), 1);
        guide.mark_search_indexed();
        let attachment = FileRecord::from_scan_entry(&fixture_entry("attachments/diagram.svg"), 1);

        let resolved_link = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let missing_link = LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Missing Note".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: Some("Missing".to_string()),
            is_embed: true,
        };
        let home_tags = [
            TagRecord {
                file_id: home.file_id.clone(),
                tag: "project/native".to_string(),
                source: TagSource::Inline,
            },
            TagRecord {
                file_id: home.file_id.clone(),
                tag: "project/native".to_string(),
                source: TagSource::Frontmatter,
            },
        ];
        let properties = [
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "status",
                &PropertyValue::String("stable".to_string()),
            ),
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "active",
                &PropertyValue::Bool(true),
            ),
            PropertyRecord::from_property_value(
                home.file_id.clone(),
                "tags",
                &PropertyValue::List(vec!["a".to_string(), "b".to_string()]),
            ),
        ];
        let attachments = [
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "assets/image.png".to_string(),
                state: AttachmentResolutionState::Resolved {
                    relative_path: PathBuf::from("assets/image.png"),
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
                raw_target: "../escape.png".to_string(),
                state: AttachmentResolutionState::Rejected(AttachmentRejectReason::OutsideVault),
            },
            AttachmentRecord {
                source_file_id: home.file_id.clone(),
                source: AttachmentReferenceSource::MarkdownLink,
                raw_target: "note.md".to_string(),
                state: AttachmentResolutionState::Unsupported,
            },
        ];

        store
            .replace_file_records(
                &home,
                &[resolved_link, missing_link],
                &home_tags,
                &properties,
                &[],
                &attachments,
            )
            .expect("home");
        for file in [&target, &guide] {
            let tags = [TagRecord {
                file_id: file.file_id.clone(),
                tag: "project/native".to_string(),
                source: TagSource::Frontmatter,
            }];
            store
                .replace_file_records(file, &[], &tags, &[], &[], &[])
                .expect("tagged file");
        }
        store
            .replace_file_records(&attachment, &[], &[], &[], &[], &[])
            .expect("attachment");

        ProjectionFixture {
            store,
            home,
            target,
            guide,
        }
    }

    fn fixture_entry(relative_path: &str) -> crate::scanner::ScanEntry {
        let root_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault");
        let root = VaultRoot::open(root_path).expect("root");
        let scan = scan_vault(&root).expect("scan");
        scan.entries
            .into_iter()
            .find(|entry| entry.relative_path == PathBuf::from(relative_path))
            .expect("fixture entry")
    }

    fn metadata_records_for_file(relative_path: &str, generation: u64) -> FileMetadataRecords {
        let mut file = FileRecord::from_scan_entry(&fixture_entry(relative_path), generation);
        file.mark_parsed(format!("hash-{relative_path}"));
        FileMetadataRecords {
            links: vec![LinkEdgeRecord {
                source_file_id: file.file_id.clone(),
                target_text: "Folder/Target".to_string(),
                resolved_target_file_id: Some("folder/target.md".to_string()),
                heading: None,
                alias: None,
                is_embed: false,
            }],
            tags: vec![TagRecord {
                file_id: file.file_id.clone(),
                tag: "home".to_string(),
                source: TagSource::Frontmatter,
            }],
            properties: vec![PropertyRecord::from_property_value(
                file.file_id.clone(),
                "status",
                &PropertyValue::String("active".to_string()),
            )],
            headings: vec![HeadingRecord {
                file_id: file.file_id.clone(),
                slug: slugify_heading("Home"),
                title: "Home".to_string(),
                level: 1,
                byte_offset: Some(0),
            }],
            attachments: vec![AttachmentRecord {
                source_file_id: file.file_id.clone(),
                source: AttachmentReferenceSource::WikiEmbed,
                raw_target: "attachments/diagram.svg".to_string(),
                state: AttachmentResolutionState::Resolved {
                    relative_path: PathBuf::from("attachments/diagram.svg"),
                },
            }],
            file,
        }
    }

    fn projection_index_exists(connection: &Connection, name: &str) -> bool {
        connection
            .query_row(
                "SELECT EXISTS (
                    SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?1
                )",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .expect("index exists query")
            == 1
    }
}
