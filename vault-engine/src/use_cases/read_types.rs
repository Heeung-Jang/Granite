use std::fmt;

use crate::adapters::sqlite::MetadataStoreError;

pub const ENGINE_READ_STATE_COMPLETE: u32 = 0;
pub const ENGINE_READ_STATE_PARTIAL: u32 = 1;
pub const ENGINE_READ_STATE_STALE: u32 = 2;
pub const ENGINE_READ_STATE_CANCELLED: u32 = 3;
pub const ENGINE_READ_STATE_ERROR: u32 = 4;
pub const ENGINE_READ_STATE_INDEX_UNAVAILABLE: u32 = 5;
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
