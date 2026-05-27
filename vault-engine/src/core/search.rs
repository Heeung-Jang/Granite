use std::time::Duration;

use serde::Serialize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchDocument {
    pub file_id: String,
    pub path: String,
    pub title: String,
    pub body: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchResult {
    pub file_id: String,
    pub path: String,
    pub title: String,
    pub rank: f64,
    pub snippet: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchMeasurement {
    pub sample_count: usize,
    pub p95: Duration,
    pub index_size_bytes: u64,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SnippetStorageMode {
    StoredBody,
    LazySourceExperiment,
}

impl SnippetStorageMode {
    pub fn config_name(self) -> &'static str {
        match self {
            Self::StoredBody => "stored_body",
            Self::LazySourceExperiment => "lazy_source_experiment",
        }
    }
}
