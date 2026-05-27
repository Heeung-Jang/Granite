use std::path::Path;

use crate::adapters::sqlite::{IndexSchemaMetadata, MetadataStore};
use crate::adapters::tantivy::TantivySearchIndex;
use crate::read_api::{
    READ_BACKEND_NAME, READ_BACKEND_VERSION, READ_TOKENIZER_CONFIG, ReadOpenError, ReadOpenResult,
};

pub struct VaultReadApi {
    pub(crate) metadata: MetadataStore,
    pub(crate) search: TantivySearchIndex,
    pub(crate) generation: u64,
}

impl VaultReadApi {
    pub fn new(metadata: MetadataStore, search: TantivySearchIndex) -> Self {
        Self::with_generation(metadata, search, 0)
    }

    pub fn with_generation(
        metadata: MetadataStore,
        search: TantivySearchIndex,
        generation: u64,
    ) -> Self {
        Self {
            metadata,
            search,
            generation,
        }
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }
}

pub fn expected_read_schema_metadata() -> IndexSchemaMetadata {
    IndexSchemaMetadata::new(
        READ_BACKEND_NAME,
        READ_BACKEND_VERSION,
        READ_TOKENIZER_CONFIG,
        0,
    )
}

pub fn open_metadata_store_for_read(
    metadata_path: impl AsRef<Path>,
) -> ReadOpenResult<(MetadataStore, u64)> {
    let metadata_path = metadata_path.as_ref();
    if metadata_path.as_os_str().is_empty() {
        return Err(ReadOpenError::InvalidInput("metadata_path"));
    }
    if !metadata_path.is_file() {
        return Err(ReadOpenError::MissingMetadata);
    }

    let expected = expected_read_schema_metadata();
    let (metadata, stored) = MetadataStore::open_existing_read_only(metadata_path, &expected)
        .map_err(ReadOpenError::from_metadata_open)?;
    Ok((metadata, stored.generation))
}

pub fn open_tantivy_index_for_read(
    tantivy_path: impl AsRef<Path>,
) -> ReadOpenResult<TantivySearchIndex> {
    let tantivy_path = tantivy_path.as_ref();
    if tantivy_path.as_os_str().is_empty() {
        return Err(ReadOpenError::InvalidInput("tantivy_path"));
    }
    if !tantivy_path.is_dir() {
        return Err(ReadOpenError::MissingTantivyIndex);
    }
    TantivySearchIndex::open_existing_dir(tantivy_path)
        .map_err(|_| ReadOpenError::MissingTantivyIndex)
}

pub fn open_vault_read_api(
    metadata_path: impl AsRef<Path>,
    tantivy_path: impl AsRef<Path>,
) -> ReadOpenResult<VaultReadApi> {
    let (metadata, generation) = open_metadata_store_for_read(metadata_path)?;
    let search = open_tantivy_index_for_read(tantivy_path)?;
    Ok(VaultReadApi::with_generation(metadata, search, generation))
}
