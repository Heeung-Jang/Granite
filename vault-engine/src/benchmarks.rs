use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::parser::parse_markdown;
use crate::paths::{PathError, VaultRoot, lookup_key};
use crate::scanner::{ScanEntryKind, ScanError, scan_vault};
use crate::sqlite_fts::{SearchDocument, SearchResult, SqliteFtsError, SqliteFtsIndex};
use crate::tantivy_search::{TantivySearchError, TantivySearchIndex};

#[derive(Debug, Clone)]
pub struct BackendBenchmarkOptions {
    pub corpus_id: String,
    pub documents: Vec<SearchDocument>,
    pub queries: Vec<String>,
    pub result_limit: usize,
    pub work_dir: PathBuf,
}

#[derive(Debug, Serialize)]
pub struct BackendBenchmarkArtifact {
    pub schema_version: u32,
    pub generated_at_unix_seconds: u64,
    pub corpus_id: String,
    pub document_count: usize,
    pub query_count: usize,
    pub total_document_bytes: u64,
    pub backends: Vec<BackendBenchmarkResult>,
}

#[derive(Debug, Serialize)]
pub struct BackendBenchmarkResult {
    pub backend: String,
    pub initial_index_micros: u64,
    pub docs_per_second: f64,
    pub mb_per_second: f64,
    pub fts_ingest_per_second: f64,
    pub query_p95_micros: u64,
    pub query_p99_micros: u64,
    pub query_result_count: usize,
    pub snippet_result_count: usize,
    pub incremental_update_micros: u64,
    pub index_size_bytes: u64,
    pub peak_rss_bytes: Option<u64>,
}

#[derive(Debug)]
pub enum BackendBenchmarkError {
    EmptyDocuments,
    EmptyQueries,
    Io(std::io::Error),
    Path(PathError),
    Scan(String),
    Sqlite(SqliteFtsError),
    Tantivy(TantivySearchError),
    Json(serde_json::Error),
}

pub type BackendBenchmarkResultType<T> = Result<T, BackendBenchmarkError>;

pub fn load_search_documents_from_vault(
    vault_root: impl AsRef<Path>,
) -> BackendBenchmarkResultType<Vec<SearchDocument>> {
    let root = VaultRoot::open(vault_root).map_err(BackendBenchmarkError::Path)?;
    let scan = scan_vault(&root).map_err(scan_error_to_string)?;
    let mut documents = Vec::new();

    for entry in scan
        .entries
        .into_iter()
        .filter(|entry| entry.kind == ScanEntryKind::Markdown)
    {
        let absolute_path = root.canonical_root().join(&entry.relative_path);
        let body = fs::read_to_string(&absolute_path)?;
        let parsed = parse_markdown(&body);
        let title = parsed
            .headings
            .first()
            .map(|heading| heading.text.clone())
            .unwrap_or_else(|| fallback_title(&entry.relative_path));
        documents.push(SearchDocument {
            file_id: lookup_key(&entry.relative_path),
            path: entry.relative_path.to_string_lossy().to_string(),
            title,
            body,
        });
    }

    documents.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(documents)
}

pub fn run_shared_backend_benchmark(
    options: &BackendBenchmarkOptions,
) -> BackendBenchmarkResultType<BackendBenchmarkArtifact> {
    if options.documents.is_empty() {
        return Err(BackendBenchmarkError::EmptyDocuments);
    }
    if options.queries.is_empty() {
        return Err(BackendBenchmarkError::EmptyQueries);
    }

    fs::create_dir_all(&options.work_dir)?;
    let total_document_bytes = total_document_bytes(&options.documents);
    let sqlite = run_sqlite_benchmark(options, total_document_bytes)?;
    let tantivy = run_tantivy_benchmark(options, total_document_bytes)?;

    Ok(BackendBenchmarkArtifact {
        schema_version: 1,
        generated_at_unix_seconds: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        corpus_id: options.corpus_id.clone(),
        document_count: options.documents.len(),
        query_count: options.queries.len(),
        total_document_bytes,
        backends: vec![sqlite, tantivy],
    })
}

pub fn write_backend_benchmark_artifact(
    path: impl AsRef<Path>,
    artifact: &BackendBenchmarkArtifact,
    pretty: bool,
) -> BackendBenchmarkResultType<()> {
    let json = if pretty {
        serde_json::to_string_pretty(artifact)?
    } else {
        serde_json::to_string(artifact)?
    };
    fs::write(path, json)?;
    Ok(())
}

pub fn benchmark_module_ready() -> bool {
    true
}

impl fmt::Display for BackendBenchmarkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyDocuments => write!(formatter, "backend benchmark has no documents"),
            Self::EmptyQueries => write!(formatter, "backend benchmark has no queries"),
            Self::Io(error) => write!(formatter, "backend benchmark io error: {error}"),
            Self::Path(error) => write!(formatter, "backend benchmark path error: {error}"),
            Self::Scan(error) => write!(formatter, "backend benchmark scan error: {error}"),
            Self::Sqlite(error) => write!(formatter, "backend benchmark sqlite error: {error}"),
            Self::Tantivy(error) => write!(formatter, "backend benchmark tantivy error: {error}"),
            Self::Json(error) => write!(formatter, "backend benchmark json error: {error}"),
        }
    }
}

impl std::error::Error for BackendBenchmarkError {}

impl From<std::io::Error> for BackendBenchmarkError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<SqliteFtsError> for BackendBenchmarkError {
    fn from(error: SqliteFtsError) -> Self {
        Self::Sqlite(error)
    }
}

impl From<TantivySearchError> for BackendBenchmarkError {
    fn from(error: TantivySearchError) -> Self {
        Self::Tantivy(error)
    }
}

impl From<serde_json::Error> for BackendBenchmarkError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

fn run_sqlite_benchmark(
    options: &BackendBenchmarkOptions,
    total_document_bytes: u64,
) -> BackendBenchmarkResultType<BackendBenchmarkResult> {
    let db_path = options.work_dir.join("sqlite-fts.sqlite");
    remove_file_if_exists(&db_path)?;
    let mut index = SqliteFtsIndex::open(&db_path)?;

    let index_start = Instant::now();
    for document in &options.documents {
        index.upsert_document(document)?;
    }
    index.rebuild()?;
    index.integrity_check()?;
    index.optimize()?;
    let index_duration = index_start.elapsed();
    let query_stats = measure_queries(&options.queries, |query| {
        index
            .search(query, options.result_limit)
            .map_err(Into::into)
    })?;
    let incremental_update_micros = measure_sqlite_incremental_update(&mut index, options)?;

    Ok(backend_result(
        "sqlite_fts",
        index_duration,
        options.documents.len(),
        total_document_bytes,
        query_stats,
        incremental_update_micros,
        index.estimated_size_bytes()?,
    ))
}

fn run_tantivy_benchmark(
    options: &BackendBenchmarkOptions,
    total_document_bytes: u64,
) -> BackendBenchmarkResultType<BackendBenchmarkResult> {
    let index_dir = options.work_dir.join("tantivy");
    reset_directory(&index_dir)?;
    let mut index = TantivySearchIndex::open_in_dir(&index_dir)?;

    let index_start = Instant::now();
    index.replace_documents(&options.documents)?;
    let index_duration = index_start.elapsed();
    let query_stats = measure_queries(&options.queries, |query| {
        index
            .search(query, options.result_limit)
            .map_err(Into::into)
    })?;
    let incremental_update_micros = measure_tantivy_incremental_update(&mut index, options)?;

    Ok(backend_result(
        "tantivy",
        index_duration,
        options.documents.len(),
        total_document_bytes,
        query_stats,
        incremental_update_micros,
        index.estimated_size_bytes()?,
    ))
}

struct QueryStats {
    p95: Duration,
    p99: Duration,
    result_count: usize,
    snippet_count: usize,
}

fn measure_queries<F>(queries: &[String], mut search: F) -> BackendBenchmarkResultType<QueryStats>
where
    F: FnMut(&str) -> BackendBenchmarkResultType<Vec<SearchResult>>,
{
    let mut durations = Vec::with_capacity(queries.len());
    let mut result_count = 0;
    let mut snippet_count = 0;

    for query in queries {
        let start = Instant::now();
        let results = search(query)?;
        durations.push(start.elapsed());
        result_count += results.len();
        snippet_count += results
            .iter()
            .filter(|result| !result.snippet.is_empty())
            .count();
    }
    durations.sort();

    Ok(QueryStats {
        p95: percentile_duration(&durations, 95),
        p99: percentile_duration(&durations, 99),
        result_count,
        snippet_count,
    })
}

fn measure_sqlite_incremental_update(
    index: &mut SqliteFtsIndex,
    options: &BackendBenchmarkOptions,
) -> BackendBenchmarkResultType<u64> {
    let mut document = options.documents[0].clone();
    document.body.push_str("\nIncremental benchmark update.");
    let start = Instant::now();
    index.upsert_document(&document)?;
    index.rebuild()?;
    Ok(duration_micros(start.elapsed()))
}

fn measure_tantivy_incremental_update(
    index: &mut TantivySearchIndex,
    options: &BackendBenchmarkOptions,
) -> BackendBenchmarkResultType<u64> {
    let mut document = options.documents[0].clone();
    document.body.push_str("\nIncremental benchmark update.");
    let start = Instant::now();
    index.replace_documents(&[document])?;
    Ok(duration_micros(start.elapsed()))
}

fn backend_result(
    backend: &str,
    index_duration: Duration,
    document_count: usize,
    total_document_bytes: u64,
    query_stats: QueryStats,
    incremental_update_micros: u64,
    index_size_bytes: u64,
) -> BackendBenchmarkResult {
    BackendBenchmarkResult {
        backend: backend.to_string(),
        initial_index_micros: duration_micros(index_duration),
        docs_per_second: per_second(document_count as f64, index_duration),
        mb_per_second: per_second(total_document_bytes as f64 / 1_048_576.0, index_duration),
        fts_ingest_per_second: per_second(document_count as f64, index_duration),
        query_p95_micros: duration_micros(query_stats.p95),
        query_p99_micros: duration_micros(query_stats.p99),
        query_result_count: query_stats.result_count,
        snippet_result_count: query_stats.snippet_count,
        incremental_update_micros,
        index_size_bytes,
        peak_rss_bytes: peak_rss_bytes(),
    }
}

fn fallback_title(relative_path: &Path) -> String {
    relative_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Untitled")
        .to_string()
}

fn total_document_bytes(documents: &[SearchDocument]) -> u64 {
    documents
        .iter()
        .map(|document| {
            document.path.len() as u64 + document.title.len() as u64 + document.body.len() as u64
        })
        .sum()
}

fn percentile_duration(values: &[Duration], percentile: usize) -> Duration {
    if values.is_empty() {
        return Duration::ZERO;
    }
    let index = ((values.len() * percentile).div_ceil(100)).saturating_sub(1);
    values[index.min(values.len() - 1)]
}

fn per_second(count: f64, duration: Duration) -> f64 {
    let seconds = duration.as_secs_f64();
    if seconds == 0.0 { 0.0 } else { count / seconds }
}

fn duration_micros(duration: Duration) -> u64 {
    duration.as_micros().min(u128::from(u64::MAX)) as u64
}

fn remove_file_if_exists(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn reset_directory(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_dir_all(path)?;
    }
    fs::create_dir_all(path)
}

fn scan_error_to_string(error: ScanError) -> BackendBenchmarkError {
    BackendBenchmarkError::Scan(format!("{error:?}"))
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn peak_rss_bytes() -> Option<u64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    let result = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if result != 0 {
        return None;
    }
    let max_rss = unsafe { usage.assume_init().ru_maxrss as u64 };
    #[cfg(target_os = "linux")]
    {
        Some(max_rss.saturating_mul(1024))
    }
    #[cfg(target_os = "macos")]
    {
        Some(max_rss)
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn peak_rss_bytes() -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_both_backends_from_same_query_corpus_and_writes_json() {
        let temp = tempfile::tempdir().expect("tempdir");
        let artifact_path = temp.path().join("backend-benchmark.json");
        let options = BackendBenchmarkOptions {
            corpus_id: "fixture-smoke".to_string(),
            documents: fixture_documents(),
            queries: vec![
                "Home".to_string(),
                "Guide".to_string(),
                "compatibility fixture".to_string(),
            ],
            result_limit: 10,
            work_dir: temp.path().join("indexes"),
        };

        let artifact = run_shared_backend_benchmark(&options).expect("benchmark");
        write_backend_benchmark_artifact(&artifact_path, &artifact, true).expect("write artifact");
        let json = fs::read_to_string(&artifact_path).expect("artifact json");

        assert_eq!(artifact.schema_version, 1);
        assert_eq!(artifact.document_count, options.documents.len());
        assert_eq!(artifact.query_count, options.queries.len());
        assert_eq!(artifact.backends.len(), 2);
        assert!(artifact.backends.iter().all(|backend| {
            backend.query_p95_micros <= backend.query_p99_micros
                && backend.index_size_bytes > 0
                && backend.snippet_result_count > 0
        }));
        assert!(json.contains("\"sqlite_fts\""));
        assert!(json.contains("\"tantivy\""));
        assert!(!json.contains("Welcome to the compatibility fixture vault"));
    }

    fn fixture_documents() -> Vec<SearchDocument> {
        vec![
            SearchDocument {
                file_id: "home.md".to_string(),
                path: "Home.md".to_string(),
                title: "Home".to_string(),
                body: "Welcome to the compatibility fixture vault.".to_string(),
            },
            SearchDocument {
                file_id: "docs/guide.md".to_string(),
                path: "Docs/Guide.md".to_string(),
                title: "Guide".to_string(),
                body: "Guide links back to Home.".to_string(),
            },
            SearchDocument {
                file_id: "folder/target.md".to_string(),
                path: "Folder/Target.md".to_string(),
                title: "Target".to_string(),
                body: "This note is the resolved target for heading links.".to_string(),
            },
        ]
    }
}
