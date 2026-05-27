use std::time::Duration;

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
