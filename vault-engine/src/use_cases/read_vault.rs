use std::path::Path;

use crate::adapters::sqlite::{FileRecord, FileTreeProjection, IndexSchemaMetadata, MetadataStore};
use crate::adapters::tantivy::{TantivySearchError, TantivySearchIndex};
use crate::read_api::{
    ENGINE_READ_SEARCH_MODE_BODY, ENGINE_READ_SEARCH_MODE_FILE_NAME, FileOpenMetadata,
    READ_BACKEND_NAME, READ_BACKEND_VERSION, READ_TOKENIZER_CONFIG, ReadApiError, ReadApiResult,
    SearchHit,
};

use super::read_types::{
    MAX_FILE_TREE_PAGE_LIMIT, MAX_PAGE_LIMIT, PageRequest, ReadOpenError, ReadOpenResult, ReadPage,
    ReadState, ReadValue,
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

    pub fn file_tree(&self, page: PageRequest) -> ReadApiResult<ReadPage<FileRecord>> {
        Ok(self.page_from_overfetch_with_limit(
            self.metadata
                .list_markdown_files(page.offset, page.file_tree_fetch_limit())?,
            page,
            MAX_FILE_TREE_PAGE_LIMIT,
        ))
    }

    pub fn file_tree_projection(
        &self,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<FileTreeProjection>> {
        Ok(self.page_from_overfetch_with_limit(
            self.metadata
                .file_tree_projection(page.offset, page.file_tree_fetch_limit())?,
            page,
            MAX_FILE_TREE_PAGE_LIMIT,
        ))
    }

    pub fn file_open_metadata(
        &self,
        file_id: &str,
    ) -> ReadApiResult<ReadValue<Option<FileOpenMetadata>>> {
        self.file_open_metadata_with_request(0, file_id)
    }

    pub fn file_open_metadata_with_request(
        &self,
        request_id: u64,
        file_id: &str,
    ) -> ReadApiResult<ReadValue<Option<FileOpenMetadata>>> {
        Ok(ReadValue {
            request_id,
            generation: self.generation,
            value: self
                .metadata
                .get_file(file_id)?
                .map(|file| FileOpenMetadata { file }),
            state: ReadState::Complete,
        })
    }

    pub fn file_name_search(
        &self,
        query: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<SearchHit>> {
        self.search(query, page)
    }

    pub fn body_search(
        &self,
        query: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<SearchHit>> {
        self.search(query, page)
    }

    pub fn search_with_mode(
        &self,
        mode: u32,
        query: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<SearchHit>> {
        match mode {
            ENGINE_READ_SEARCH_MODE_FILE_NAME => self.file_name_search(query, page),
            ENGINE_READ_SEARCH_MODE_BODY => self.body_search(query, page),
            _ => Err(ReadApiError::InvalidInput("search_mode")),
        }
    }

    fn search(&self, query: &str, page: PageRequest) -> ReadApiResult<ReadPage<SearchHit>> {
        let results = match self
            .search
            .search_page(query, page.offset, page.fetch_limit())
        {
            Ok(results) => results,
            Err(TantivySearchError::EmptyQuery) => {
                return Ok(ReadPage {
                    request_id: page.request_id,
                    generation: self.generation,
                    items: Vec::new(),
                    next_offset: None,
                    state: ReadState::Error,
                });
            }
            Err(error) => return Err(error.into()),
        };
        Ok(self.page_from_overfetch(results.into_iter().map(SearchHit::from).collect(), page))
    }

    pub(crate) fn page_from_overfetch<T>(&self, items: Vec<T>, page: PageRequest) -> ReadPage<T> {
        self.page_from_overfetch_with_limit(items, page, MAX_PAGE_LIMIT)
    }

    pub(crate) fn page_from_overfetch_with_limit<T>(
        &self,
        mut items: Vec<T>,
        page: PageRequest,
        max_limit: usize,
    ) -> ReadPage<T> {
        let visible_limit = page.visible_limit_capped(max_limit);
        let has_next = items.len() > visible_limit;
        if has_next {
            items.truncate(visible_limit);
        }
        ReadPage {
            request_id: page.request_id,
            generation: self.generation,
            items,
            next_offset: has_next.then_some(page.offset + visible_limit),
            state: if has_next {
                ReadState::Partial
            } else {
                ReadState::Complete
            },
        }
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
