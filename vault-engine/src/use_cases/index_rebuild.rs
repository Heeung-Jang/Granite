use std::fmt;
use std::path::Path;

use crate::index_rebuild::IndexRebuildPaths;
use crate::indexing_pipeline::{
    IndexingPipelineOptions, load_search_document_sources, run_full_rebuild_pipeline_and_commit,
};
use crate::paths::{PathError, VaultRoot};

use super::read_vault::expected_read_schema_metadata;

#[derive(Debug)]
pub enum ReadIndexRebuildError {
    InvalidInput(&'static str),
    Path(PathError),
    RebuildFailed(String),
}

pub type ReadIndexRebuildResult<T> = Result<T, ReadIndexRebuildError>;

pub fn rebuild_read_index(
    vault_path: &Path,
    data_path: &Path,
    rebuild_path: &Path,
) -> ReadIndexRebuildResult<u64> {
    let root = VaultRoot::open(vault_path).map_err(ReadIndexRebuildError::Path)?;
    let index_root = data_path
        .parent()
        .ok_or(ReadIndexRebuildError::InvalidInput("data_path"))?;
    let paths = IndexRebuildPaths::new(root.canonical_root(), index_root, data_path, rebuild_path);
    let loaded = load_search_document_sources(&root)
        .map_err(|error| ReadIndexRebuildError::RebuildFailed(error.to_string()))?;
    let metadata = expected_read_schema_metadata();
    let result = run_full_rebuild_pipeline_and_commit(
        &paths,
        &loaded.sources,
        &metadata,
        &IndexingPipelineOptions::default(),
    )
    .map_err(|error| ReadIndexRebuildError::RebuildFailed(error.to_string()))?;

    Ok(result.generation)
}

impl fmt::Display for ReadIndexRebuildError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(field) => write!(formatter, "{field}: invalid path"),
            Self::Path(error) => write!(formatter, "{error}"),
            Self::RebuildFailed(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for ReadIndexRebuildError {}
