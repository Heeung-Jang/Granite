use std::fmt;
use std::path::Path;

use rusqlite::{Connection, OpenFlags};

use crate::adapters::sqlite::schema::{create_schema, read_schema_metadata, write_schema_metadata};
use crate::index::IndexSchemaMetadata;

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
