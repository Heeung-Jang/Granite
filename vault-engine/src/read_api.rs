use std::fmt;

use crate::index::{
    AttachmentRecord, FileRecord, HeadingRecord, LinkEdgeRecord, MetadataStore, MetadataStoreError,
    PropertyRecord, TagRecord,
};
use crate::sqlite_fts::SearchResult;
use crate::tantivy_search::{TantivySearchError, TantivySearchIndex};

const MAX_PAGE_LIMIT: usize = 100;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageRequest {
    pub request_id: u64,
    pub offset: usize,
    pub limit: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadPage<T> {
    pub request_id: u64,
    pub generation: u64,
    pub items: Vec<T>,
    pub next_offset: Option<usize>,
    pub state: ReadState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadValue<T> {
    pub request_id: u64,
    pub generation: u64,
    pub value: T,
    pub state: ReadState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadState {
    Complete,
    Partial,
    Stale,
    Cancelled,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub file_id: String,
    pub path: String,
    pub title: String,
    pub rank: f64,
    pub snippet: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileOpenMetadata {
    pub file: FileRecord,
}

pub struct VaultReadApi {
    metadata: MetadataStore,
    search: TantivySearchIndex,
    generation: u64,
}

#[derive(Debug)]
pub enum ReadApiError {
    Metadata(MetadataStoreError),
    Search(TantivySearchError),
}

pub type ReadApiResult<T> = Result<T, ReadApiError>;

impl PageRequest {
    pub fn new(offset: usize, limit: usize) -> Self {
        Self::with_request_id(0, offset, limit)
    }

    pub fn with_request_id(request_id: u64, offset: usize, limit: usize) -> Self {
        Self {
            request_id,
            offset,
            limit,
        }
    }

    fn visible_limit(self) -> usize {
        self.limit.clamp(1, MAX_PAGE_LIMIT)
    }

    fn fetch_limit(self) -> usize {
        self.visible_limit() + 1
    }
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

    pub fn file_tree(&self, page: PageRequest) -> ReadApiResult<ReadPage<FileRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata.list_files(page.offset, page.fetch_limit())?,
            page,
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

    pub fn backlinks(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<LinkEdgeRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .backlinks(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn outgoing_links(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<LinkEdgeRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .outgoing_links(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn tags(&self, file_id: &str, page: PageRequest) -> ReadApiResult<ReadPage<TagRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .tags(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn properties(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<PropertyRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .properties(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn headings(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<HeadingRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .headings(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn attachments(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<AttachmentRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .attachments(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
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

    fn page_from_overfetch<T>(&self, mut items: Vec<T>, page: PageRequest) -> ReadPage<T> {
        let visible_limit = page.visible_limit();
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

impl fmt::Display for ReadApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Metadata(error) => write!(formatter, "read api metadata error: {error}"),
            Self::Search(error) => write!(formatter, "read api search error: {error}"),
        }
    }
}

impl std::error::Error for ReadApiError {}

impl From<MetadataStoreError> for ReadApiError {
    fn from(error: MetadataStoreError) -> Self {
        Self::Metadata(error)
    }
}

impl From<TantivySearchError> for ReadApiError {
    fn from(error: TantivySearchError) -> Self {
        Self::Search(error)
    }
}

impl From<SearchResult> for SearchHit {
    fn from(result: SearchResult) -> Self {
        Self {
            file_id: result.file_id,
            path: result.path,
            title: result.title,
            rank: result.rank,
            snippet: result.snippet,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
    use crate::index::{
        HeadingRecord, IndexSchemaMetadata, MetadataStore, PropertyRecord, TagRecord, TagSource,
        slugify_heading,
    };
    use crate::parser::PropertyValue;
    use crate::paths::{VaultRoot, lookup_key};
    use crate::scanner::{ScanEntry, scan_vault};
    use crate::sqlite_fts::SearchDocument;
    use crate::tantivy_search::TantivySearchIndex;

    #[test]
    fn read_api_returns_paginated_metadata_and_search_states() {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut search = TantivySearchIndex::open_in_ram().expect("search");

        let mut home = crate::index::FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target =
            crate::index::FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();

        let link = crate::index::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: Some("Details".to_string()),
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: home.file_id.clone(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };
        let property = PropertyRecord::from_property_value(
            home.file_id.clone(),
            "status",
            &PropertyValue::String("active".to_string()),
        );
        let heading = HeadingRecord {
            file_id: home.file_id.clone(),
            slug: slugify_heading("Home"),
            title: "Home".to_string(),
            level: 1,
            byte_offset: Some(0),
        };
        let attachment = AttachmentRecord {
            source_file_id: home.file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };

        store
            .replace_file_records(
                &home,
                std::slice::from_ref(&link),
                std::slice::from_ref(&tag),
                std::slice::from_ref(&property),
                std::slice::from_ref(&heading),
                std::slice::from_ref(&attachment),
            )
            .expect("home records");
        store
            .replace_file_records(&target, &[], &[], &[], &[], &[])
            .expect("target records");
        search
            .replace_documents(&[
                SearchDocument {
                    file_id: home.file_id.clone(),
                    path: "Home.md".to_string(),
                    title: "Home".to_string(),
                    body: "Home body mentions compatibility and native search.".to_string(),
                },
                SearchDocument {
                    file_id: target.file_id.clone(),
                    path: "Folder/Target.md".to_string(),
                    title: "Target".to_string(),
                    body: "Target body receives backlinks.".to_string(),
                },
            ])
            .expect("index");

        let api = VaultReadApi::with_generation(store, search, 1);
        let first_file = api
            .file_tree(PageRequest::with_request_id(42, 0, 1))
            .expect("first file page");
        assert_eq!(first_file.request_id, 42);
        assert_eq!(first_file.generation, 1);
        assert_eq!(first_file.state, ReadState::Partial);
        assert_eq!(first_file.next_offset, Some(1));
        let open = api
            .file_open_metadata_with_request(43, &home.file_id)
            .expect("open metadata");
        assert_eq!(open.request_id, 43);
        assert_eq!(open.generation, 1);
        assert_eq!(open.state, ReadState::Complete);
        assert_eq!(
            open.value.expect("file").file.file_id,
            lookup_key("Home.md")
        );

        assert_eq!(
            api.file_name_search("Home", PageRequest::with_request_id(44, 0, 10))
                .expect("file name search")
                .state,
            ReadState::Complete
        );
        assert!(
            api.body_search("compatibility", PageRequest::new(0, 10))
                .expect("body search")
                .items
                .iter()
                .any(|hit| hit.file_id == home.file_id)
        );
        assert_eq!(
            api.body_search("!!!", PageRequest::new(0, 10))
                .expect("empty query")
                .state,
            ReadState::Error
        );
        assert_eq!(
            api.outgoing_links(&home.file_id, PageRequest::new(0, 10))
                .expect("outgoing")
                .items,
            vec![link.clone()]
        );
        assert_eq!(
            api.backlinks(&target.file_id, PageRequest::new(0, 10))
                .expect("backlinks")
                .items,
            vec![link]
        );
        assert_eq!(
            api.tags(&home.file_id, PageRequest::new(0, 10))
                .expect("tags")
                .items,
            vec![tag]
        );
        assert_eq!(
            api.properties(&home.file_id, PageRequest::new(0, 10))
                .expect("properties")
                .items,
            vec![property]
        );
        assert_eq!(
            api.headings(&home.file_id, PageRequest::new(0, 10))
                .expect("headings")
                .items,
            vec![heading]
        );
        assert_eq!(
            api.attachments(&home.file_id, PageRequest::new(0, 10))
                .expect("attachments")
                .items,
            vec![attachment]
        );
    }

    fn fixture_entry(relative_path: &str) -> ScanEntry {
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
}
