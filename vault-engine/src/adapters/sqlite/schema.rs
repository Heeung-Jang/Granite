use rusqlite::{Connection, OptionalExtension, params};

use crate::core::metadata::IndexSchemaMetadata;
use crate::index::{MetadataStoreError, MetadataStoreResult};

pub(crate) fn create_schema(connection: &Connection) -> MetadataStoreResult<()> {
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
            target_key TEXT NOT NULL,
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
        ",
    )?;
    create_projection_indexes(connection)?;
    Ok(())
}

pub(crate) fn create_projection_indexes(connection: &Connection) -> MetadataStoreResult<()> {
    connection.execute_batch(
        "
        CREATE INDEX IF NOT EXISTS idx_files_relative_path ON files(relative_path);
        CREATE INDEX IF NOT EXISTS idx_files_kind_status_generation
            ON files(kind, status, generation);
        CREATE INDEX IF NOT EXISTS idx_links_source_file_id ON links(source_file_id);
        CREATE INDEX IF NOT EXISTS idx_links_resolved_target_file_id
            ON links(resolved_target_file_id);
        CREATE INDEX IF NOT EXISTS idx_links_resolved_pair
            ON links(source_file_id, resolved_target_file_id);
        CREATE INDEX IF NOT EXISTS idx_links_unresolved_target_text
            ON links(target_text)
            WHERE resolved_target_file_id IS NULL;
        CREATE INDEX IF NOT EXISTS idx_links_unresolved_source_target_key
            ON links(source_file_id, target_key, target_text)
            WHERE resolved_target_file_id IS NULL;
        CREATE INDEX IF NOT EXISTS idx_tags_file_id ON tags(file_id);
        CREATE INDEX IF NOT EXISTS idx_tags_tag ON tags(tag);
        CREATE INDEX IF NOT EXISTS idx_properties_file_id ON properties(file_id);
        CREATE INDEX IF NOT EXISTS idx_headings_file_id ON headings(file_id);
        CREATE INDEX IF NOT EXISTS idx_attachments_source_file_id ON attachments(source_file_id);
        ",
    )?;
    Ok(())
}

pub(crate) fn drop_projection_indexes(connection: &Connection) -> MetadataStoreResult<()> {
    connection.execute_batch(
        "
        DROP INDEX IF EXISTS idx_files_relative_path;
        DROP INDEX IF EXISTS idx_files_kind_status_generation;
        DROP INDEX IF EXISTS idx_links_source_file_id;
        DROP INDEX IF EXISTS idx_links_resolved_target_file_id;
        DROP INDEX IF EXISTS idx_links_resolved_pair;
        DROP INDEX IF EXISTS idx_links_unresolved_target_text;
        DROP INDEX IF EXISTS idx_links_unresolved_source_target_key;
        DROP INDEX IF EXISTS idx_tags_file_id;
        DROP INDEX IF EXISTS idx_tags_tag;
        DROP INDEX IF EXISTS idx_properties_file_id;
        DROP INDEX IF EXISTS idx_headings_file_id;
        DROP INDEX IF EXISTS idx_attachments_source_file_id;
        ",
    )?;
    Ok(())
}

pub(crate) fn read_schema_metadata(
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

pub(crate) fn write_schema_metadata(
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
