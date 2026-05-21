use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
use rusqlite::{Connection, OptionalExtension, params};

use crate::parser::PropertyValue;
use crate::paths::{FileIdentity, lookup_key};
use crate::scanner::{ScanEntry, ScanEntryKind};

pub const INDEX_SCHEMA_VERSION: u32 = 1;
pub const MAX_INDEX_ERROR_CHARS: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexSchemaMetadata {
    pub schema_version: u32,
    pub backend_name: String,
    pub backend_version: String,
    pub tokenizer_config: String,
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRecord {
    pub file_id: String,
    pub relative_path: PathBuf,
    pub kind: ScanEntryKind,
    pub size_bytes: u64,
    pub modified: Option<SystemTime>,
    pub file_identity: FileIdentity,
    pub content_hash: Option<String>,
    pub generation: u64,
    pub status: FileIndexStatus,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileIndexStatus {
    SeenMetadata,
    Parsed,
    SearchIndexed,
    Tombstoned,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkEdgeRecord {
    pub source_file_id: String,
    pub target_text: String,
    pub resolved_target_file_id: Option<String>,
    pub heading: Option<String>,
    pub alias: Option<String>,
    pub is_embed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TagRecord {
    pub file_id: String,
    pub tag: String,
    pub source: TagSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TagSource {
    Inline,
    Frontmatter,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyRecord {
    pub file_id: String,
    pub key: String,
    pub value: IndexPropertyValue,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexPropertyValue {
    String(String),
    Bool(bool),
    List(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeadingRecord {
    pub file_id: String,
    pub slug: String,
    pub title: String,
    pub level: u8,
    pub byte_offset: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AttachmentRecord {
    pub source_file_id: String,
    pub source: AttachmentReferenceSource,
    pub raw_target: String,
    pub state: AttachmentResolutionState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileMetadataRecords {
    pub file: FileRecord,
    pub links: Vec<LinkEdgeRecord>,
    pub tags: Vec<TagRecord>,
    pub properties: Vec<PropertyRecord>,
    pub headings: Vec<HeadingRecord>,
    pub attachments: Vec<AttachmentRecord>,
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

impl PropertyRecord {
    pub fn from_property_value(
        file_id: impl Into<String>,
        key: impl Into<String>,
        value: &PropertyValue,
    ) -> Self {
        let value = match value {
            PropertyValue::String(value) => IndexPropertyValue::String(value.clone()),
            PropertyValue::Bool(value) => IndexPropertyValue::Bool(*value),
            PropertyValue::List(values) => IndexPropertyValue::List(values.clone()),
        };

        Self {
            file_id: file_id.into(),
            key: key.into(),
            value,
        }
    }
}

impl MetadataStore {
    pub fn open(
        path: impl AsRef<std::path::Path>,
        expected: &IndexSchemaMetadata,
    ) -> MetadataStoreResult<Self> {
        Self::from_connection(Connection::open(path)?, expected)
    }

    pub fn open_in_memory(expected: &IndexSchemaMetadata) -> MetadataStoreResult<Self> {
        Self::from_connection(Connection::open_in_memory()?, expected)
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
        self.replace_file_records_batch(&[FileMetadataRecords {
            file: file.clone(),
            links: links.to_vec(),
            tags: tags.to_vec(),
            properties: properties.to_vec(),
            headings: headings.to_vec(),
            attachments: attachments.to_vec(),
        }])
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
                    source_file_id, target_text, resolved_target_file_id, heading, alias, is_embed
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
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
                execute_upsert_file(&mut upsert_file, &record.file)?;
                execute_delete_child_records(
                    &mut delete_links,
                    &mut delete_tags,
                    &mut delete_properties,
                    &mut delete_headings,
                    &mut delete_attachments,
                    &record.file.file_id,
                )?;
                for link in &record.links {
                    execute_insert_link(&mut insert_link, link)?;
                }
                for tag in &record.tags {
                    execute_insert_tag(&mut insert_tag, tag)?;
                }
                for property in &record.properties {
                    execute_insert_property(&mut insert_property, property)?;
                }
                for heading in &record.headings {
                    execute_insert_heading(&mut insert_heading, heading)?;
                }
                for attachment in &record.attachments {
                    execute_insert_attachment(&mut insert_attachment, attachment)?;
                }
            }
        }

        transaction.commit()?;
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

fn create_schema(connection: &Connection) -> MetadataStoreResult<()> {
    connection.execute_batch(
        "
        PRAGMA foreign_keys = ON;
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA temp_store = MEMORY;
        CREATE TABLE IF NOT EXISTS index_metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS files (
            file_id TEXT PRIMARY KEY,
            relative_path TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            modified_unix_ms INTEGER,
            file_device TEXT NOT NULL,
            file_inode TEXT NOT NULL,
            content_hash TEXT,
            generation INTEGER NOT NULL,
            status TEXT NOT NULL,
            last_error TEXT
        );
        CREATE TABLE IF NOT EXISTS links (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_file_id TEXT NOT NULL,
            target_text TEXT NOT NULL,
            resolved_target_file_id TEXT,
            heading TEXT,
            alias TEXT,
            is_embed INTEGER NOT NULL,
            FOREIGN KEY(source_file_id) REFERENCES files(file_id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL,
            tag TEXT NOT NULL,
            source TEXT NOT NULL,
            FOREIGN KEY(file_id) REFERENCES files(file_id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS properties (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL,
            key TEXT NOT NULL,
            value_kind TEXT NOT NULL,
            value_json TEXT NOT NULL,
            FOREIGN KEY(file_id) REFERENCES files(file_id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS headings (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL,
            slug TEXT NOT NULL,
            title TEXT NOT NULL,
            level INTEGER NOT NULL,
            byte_offset INTEGER,
            FOREIGN KEY(file_id) REFERENCES files(file_id) ON DELETE CASCADE
        );
        CREATE TABLE IF NOT EXISTS attachments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_file_id TEXT NOT NULL,
            source TEXT NOT NULL,
            raw_target TEXT NOT NULL,
            state TEXT NOT NULL,
            state_detail TEXT,
            FOREIGN KEY(source_file_id) REFERENCES files(file_id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_links_source_file_id
            ON links(source_file_id);
        CREATE INDEX IF NOT EXISTS idx_links_resolved_target_file_id
            ON links(resolved_target_file_id);
        CREATE INDEX IF NOT EXISTS idx_tags_file_id
            ON tags(file_id);
        CREATE INDEX IF NOT EXISTS idx_properties_file_id
            ON properties(file_id);
        CREATE INDEX IF NOT EXISTS idx_headings_file_id
            ON headings(file_id);
        CREATE INDEX IF NOT EXISTS idx_attachments_source_file_id
            ON attachments(source_file_id);
        ",
    )?;
    Ok(())
}

fn read_schema_metadata(
    connection: &Connection,
) -> MetadataStoreResult<Option<IndexSchemaMetadata>> {
    let table_exists = connection.query_row(
        "SELECT EXISTS (
            SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'index_metadata'
        )",
        [],
        |row| row.get::<_, i64>(0),
    )? == 1;
    if !table_exists {
        return Ok(None);
    }

    let schema_version = read_metadata_value(connection, "schema_version")?;
    let Some(schema_version) = schema_version else {
        return Ok(None);
    };

    Ok(Some(IndexSchemaMetadata {
        schema_version: schema_version
            .parse()
            .map_err(|_| MetadataStoreError::InvalidStoredValue("schema_version"))?,
        backend_name: read_required_metadata_value(connection, "backend_name")?,
        backend_version: read_required_metadata_value(connection, "backend_version")?,
        tokenizer_config: read_required_metadata_value(connection, "tokenizer_config")?,
        generation: read_required_metadata_value(connection, "generation")?
            .parse()
            .map_err(|_| MetadataStoreError::InvalidStoredValue("generation"))?,
    }))
}

fn write_schema_metadata(
    connection: &Connection,
    metadata: &IndexSchemaMetadata,
) -> MetadataStoreResult<()> {
    let values = [
        ("schema_version", metadata.schema_version.to_string()),
        ("backend_name", metadata.backend_name.clone()),
        ("backend_version", metadata.backend_version.clone()),
        ("tokenizer_config", metadata.tokenizer_config.clone()),
        ("generation", metadata.generation.to_string()),
    ];

    for (key, value) in values {
        connection.execute(
            "INSERT OR REPLACE INTO index_metadata (key, value) VALUES (?1, ?2)",
            params![key, value],
        )?;
    }
    Ok(())
}

fn read_required_metadata_value(connection: &Connection, key: &str) -> MetadataStoreResult<String> {
    read_metadata_value(connection, key)?
        .ok_or(MetadataStoreError::InvalidStoredValue("index_metadata"))
}

fn read_metadata_value(connection: &Connection, key: &str) -> MetadataStoreResult<Option<String>> {
    connection
        .query_row(
            "SELECT value FROM index_metadata WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()
        .map_err(Into::into)
}

fn execute_upsert_file(
    statement: &mut rusqlite::Statement<'_>,
    file: &FileRecord,
) -> MetadataStoreResult<()> {
    statement.execute(params![
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
    Ok(())
}

fn execute_delete_child_records(
    delete_links: &mut rusqlite::Statement<'_>,
    delete_tags: &mut rusqlite::Statement<'_>,
    delete_properties: &mut rusqlite::Statement<'_>,
    delete_headings: &mut rusqlite::Statement<'_>,
    delete_attachments: &mut rusqlite::Statement<'_>,
    file_id: &str,
) -> MetadataStoreResult<()> {
    delete_links.execute(params![file_id])?;
    delete_tags.execute(params![file_id])?;
    delete_properties.execute(params![file_id])?;
    delete_headings.execute(params![file_id])?;
    delete_attachments.execute(params![file_id])?;
    Ok(())
}

fn execute_insert_link(
    statement: &mut rusqlite::Statement<'_>,
    link: &LinkEdgeRecord,
) -> MetadataStoreResult<()> {
    statement.execute(params![
        &link.source_file_id,
        &link.target_text,
        link.resolved_target_file_id.as_deref(),
        link.heading.as_deref(),
        link.alias.as_deref(),
        bool_to_int(link.is_embed),
    ])?;
    Ok(())
}

fn execute_insert_tag(
    statement: &mut rusqlite::Statement<'_>,
    tag: &TagRecord,
) -> MetadataStoreResult<()> {
    statement.execute(params![
        &tag.file_id,
        &tag.tag,
        tag_source_to_str(tag.source)
    ])?;
    Ok(())
}

fn execute_insert_property(
    statement: &mut rusqlite::Statement<'_>,
    property: &PropertyRecord,
) -> MetadataStoreResult<()> {
    let (kind, json) = property_value_to_storage(&property.value)?;
    statement.execute(params![&property.file_id, &property.key, kind, json])?;
    Ok(())
}

fn execute_insert_heading(
    statement: &mut rusqlite::Statement<'_>,
    heading: &HeadingRecord,
) -> MetadataStoreResult<()> {
    statement.execute(params![
        &heading.file_id,
        &heading.slug,
        &heading.title,
        heading.level as i64,
        heading.byte_offset.map(|offset| offset as i64),
    ])?;
    Ok(())
}

fn execute_insert_attachment(
    statement: &mut rusqlite::Statement<'_>,
    attachment: &AttachmentRecord,
) -> MetadataStoreResult<()> {
    let (state, detail) = attachment_state_to_storage(&attachment.state)?;
    statement.execute(params![
        &attachment.source_file_id,
        attachment_source_to_str(attachment.source),
        &attachment.raw_target,
        state,
        detail,
    ])?;
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

fn bool_to_int(value: bool) -> i64 {
    if value { 1 } else { 0 }
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
    use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
    use crate::paths::VaultRoot;
    use crate::scanner::scan_vault;
    use std::path::PathBuf;

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
    fn metadata_store_creates_child_lookup_indexes() {
        let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 1);
        let store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut statement = store
            .connection
            .prepare("SELECT name FROM sqlite_master WHERE type = 'index'")
            .expect("index query");
        let indexes = statement
            .query_map([], |row| row.get::<_, String>(0))
            .expect("index rows")
            .collect::<Result<Vec<_>, _>>()
            .expect("indexes");

        for expected in [
            "idx_links_source_file_id",
            "idx_links_resolved_target_file_id",
            "idx_tags_file_id",
            "idx_properties_file_id",
            "idx_headings_file_id",
            "idx_attachments_source_file_id",
        ] {
            assert!(
                indexes.iter().any(|name| name == expected),
                "missing index {expected}"
            );
        }
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
}
