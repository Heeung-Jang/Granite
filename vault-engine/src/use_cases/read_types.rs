use std::fmt;

use crate::adapters::sqlite::MetadataStoreError;
use crate::adapters::tantivy::TantivySearchError;
use crate::core::metadata::FileRecord;
use crate::core::search::SearchResult;

pub const ENGINE_READ_STATE_COMPLETE: u32 = 0;
pub const ENGINE_READ_STATE_PARTIAL: u32 = 1;
pub const ENGINE_READ_STATE_STALE: u32 = 2;
pub const ENGINE_READ_STATE_CANCELLED: u32 = 3;
pub const ENGINE_READ_STATE_ERROR: u32 = 4;
pub const ENGINE_READ_STATE_INDEX_UNAVAILABLE: u32 = 5;
pub const READ_BACKEND_NAME: &str = "sqlite+tantivy";
pub const READ_BACKEND_VERSION: &str = "metadata-v2";
pub const READ_TOKENIZER_CONFIG: &str = "tantivy";
pub const ENGINE_READ_SEARCH_MODE_FILE_NAME: u32 = 1;
pub const ENGINE_READ_SEARCH_MODE_BODY: u32 = 2;
pub const ENGINE_READ_INSPECTOR_PANEL_BACKLINKS: u32 = 1;
pub const ENGINE_READ_INSPECTOR_PANEL_OUTGOING: u32 = 2;
pub const ENGINE_READ_INSPECTOR_PANEL_TAGS: u32 = 3;
pub const ENGINE_READ_INSPECTOR_PANEL_PROPERTIES: u32 = 4;
pub const ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS: u32 = 5;
pub const ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP: u32 = 1;
pub const ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP: u32 = 2;
pub(crate) const MAX_PAGE_LIMIT: usize = 100;
pub(crate) const MAX_FILE_TREE_PAGE_LIMIT: usize = 100_000;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LivePreviewMetadataItem {
    pub kind: LivePreviewMetadataItemKind,
    pub key: String,
    pub value: String,
    pub resolved_file_id: Option<String>,
    pub resolved_relative_path: Option<String>,
    pub heading: Option<String>,
    pub alias: Option<String>,
    pub state: LivePreviewMetadataState,
    pub source: LivePreviewMetadataSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivePreviewMetadataItemKind {
    Property,
    Tag,
    Link,
    Attachment,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivePreviewMetadataState {
    None,
    Resolved,
    Missing,
    Remote,
    Rejected,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivePreviewMetadataSource {
    None,
    Inline,
    WikiLink,
    MarkdownLink,
    WikiEmbed,
    MarkdownImage,
}

#[derive(Debug)]
pub enum ReadApiError {
    Metadata(MetadataStoreError),
    Search(TantivySearchError),
    InvalidInput(&'static str),
    NotFound(&'static str),
}

pub type ReadApiResult<T> = Result<T, ReadApiError>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadOpenError {
    MissingMetadata,
    CorruptMetadata,
    SchemaMismatch {
        stored: u32,
        expected: u32,
    },
    BackendMismatch {
        stored_name: String,
        stored_version: String,
        expected_name: String,
        expected_version: String,
    },
    TokenizerMismatch {
        stored: String,
        expected: String,
    },
    MissingTantivyIndex,
    InvalidInput(&'static str),
    Panic,
}

pub type ReadOpenResult<T> = Result<T, ReadOpenError>;

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

    pub(crate) fn fetch_limit(self) -> usize {
        self.fetch_limit_capped(MAX_PAGE_LIMIT)
    }

    pub(crate) fn file_tree_fetch_limit(self) -> usize {
        self.fetch_limit_capped(MAX_FILE_TREE_PAGE_LIMIT)
    }

    pub(crate) fn visible_limit_capped(self, max_limit: usize) -> usize {
        self.limit.clamp(1, max_limit)
    }

    pub(crate) fn fetch_limit_capped(self, max_limit: usize) -> usize {
        self.visible_limit_capped(max_limit) + 1
    }
}

impl ReadOpenError {
    pub fn abi_code(&self) -> &'static str {
        match self {
            Self::MissingMetadata => "missing_metadata",
            Self::CorruptMetadata => "corrupt_metadata",
            Self::SchemaMismatch { .. } => "schema_mismatch",
            Self::BackendMismatch { .. } => "backend_mismatch",
            Self::TokenizerMismatch { .. } => "tokenizer_mismatch",
            Self::MissingTantivyIndex => "missing_tantivy_index",
            Self::InvalidInput(_) => "invalid_input",
            Self::Panic => "panic",
        }
    }

    pub fn abi_numeric_code(&self) -> u32 {
        match self {
            Self::MissingMetadata => 1,
            Self::CorruptMetadata => 2,
            Self::SchemaMismatch { .. } => 3,
            Self::BackendMismatch { .. } => 4,
            Self::TokenizerMismatch { .. } => 5,
            Self::MissingTantivyIndex => 6,
            Self::InvalidInput(_) => 7,
            Self::Panic => 8,
        }
    }

    pub fn state_code(&self) -> u32 {
        match self {
            Self::MissingMetadata | Self::MissingTantivyIndex => {
                ENGINE_READ_STATE_INDEX_UNAVAILABLE
            }
            _ => ENGINE_READ_STATE_ERROR,
        }
    }

    pub(crate) fn from_metadata_open(error: MetadataStoreError) -> Self {
        match error {
            MetadataStoreError::SchemaMismatch { stored, expected } => {
                if stored.schema_version != expected.schema_version {
                    Self::SchemaMismatch {
                        stored: stored.schema_version,
                        expected: expected.schema_version,
                    }
                } else if stored.backend_name != expected.backend_name
                    || stored.backend_version != expected.backend_version
                {
                    Self::BackendMismatch {
                        stored_name: stored.backend_name,
                        stored_version: stored.backend_version,
                        expected_name: expected.backend_name,
                        expected_version: expected.backend_version,
                    }
                } else if stored.tokenizer_config != expected.tokenizer_config {
                    Self::TokenizerMismatch {
                        stored: stored.tokenizer_config,
                        expected: expected.tokenizer_config,
                    }
                } else {
                    Self::CorruptMetadata
                }
            }
            MetadataStoreError::Sqlite(_) | MetadataStoreError::InvalidStoredValue(_) => {
                Self::CorruptMetadata
            }
        }
    }
}

impl fmt::Display for ReadOpenError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingMetadata => write!(formatter, "metadata store is missing"),
            Self::CorruptMetadata => write!(formatter, "metadata store is corrupt"),
            Self::SchemaMismatch { stored, expected } => write!(
                formatter,
                "metadata schema mismatch: stored={stored}, expected={expected}"
            ),
            Self::BackendMismatch {
                stored_name,
                stored_version,
                expected_name,
                expected_version,
            } => write!(
                formatter,
                "metadata backend mismatch: stored={stored_name}/{stored_version}, expected={expected_name}/{expected_version}"
            ),
            Self::TokenizerMismatch { stored, expected } => write!(
                formatter,
                "metadata tokenizer mismatch: stored={stored}, expected={expected}"
            ),
            Self::MissingTantivyIndex => write!(formatter, "tantivy search index is missing"),
            Self::InvalidInput(field) => write!(formatter, "invalid read open input: {field}"),
            Self::Panic => write!(formatter, "read ffi panic"),
        }
    }
}

impl std::error::Error for ReadOpenError {}

impl fmt::Display for ReadApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Metadata(error) => write!(formatter, "read api metadata error: {error}"),
            Self::Search(error) => write!(formatter, "read api search error: {error}"),
            Self::InvalidInput(field) => write!(formatter, "invalid read api input: {field}"),
            Self::NotFound(field) => write!(formatter, "read api target not found: {field}"),
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
