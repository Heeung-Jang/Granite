use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::index::{IndexSchemaMetadata, MetadataStore, MetadataStoreError, MetadataTable};
#[cfg(test)]
use crate::indexing_pipeline::read_parse_source;
pub use crate::indexing_pipeline::{
    IndexingMode, IndexingPipelineOptions, MAX_DEFAULT_READ_PARSE_WORKERS, SnippetStorageMode,
};
use crate::indexing_pipeline::{
    IndexingPipelineError, PipelineCorpusStageMetrics, PipelineCorpusStats, SearchDocumentSource,
    load_search_document_sources, read_search_document, run_read_parse_pipeline,
    run_tantivy_rebuild_pipeline,
};
#[cfg(test)]
use crate::paths::{FileIdentity, lookup_key};
use crate::paths::{PathError, VaultRoot};
#[cfg(test)]
use crate::scanner::ScanEntryKind;
use crate::sqlite_fts::{SearchDocument, SearchResult, SqliteFtsError, SqliteFtsIndex};
use crate::tantivy_search::{TantivyIndexingStageMetrics, TantivySearchError, TantivySearchIndex};

pub const BACKEND_BENCHMARK_ARTIFACT_SCHEMA_VERSION: u32 = 6;

#[derive(Debug, Clone)]
pub struct BackendBenchmarkOptions {
    pub corpus_id: String,
    pub documents: Vec<SearchDocument>,
    pub queries: Vec<String>,
    pub result_limit: usize,
    pub work_dir: PathBuf,
}

#[derive(Debug, Clone)]
pub struct VaultBackendBenchmarkOptions {
    pub corpus_id: String,
    pub vault_root: PathBuf,
    pub queries: Vec<String>,
    pub result_limit: usize,
    pub work_dir: PathBuf,
}

#[derive(Debug, Serialize)]
pub struct BackendBenchmarkArtifact {
    pub schema_version: u32,
    pub generated_at_unix_seconds: u64,
    pub corpus_id: String,
    pub run_metadata: BenchmarkRunMetadata,
    pub pipeline_config: BenchmarkPipelineConfig,
    pub corpus_stages: BenchmarkCorpusStageMetrics,
    pub document_count: usize,
    pub query_count: usize,
    pub total_document_bytes: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata_store: Option<BenchmarkMetadataStoreMetrics>,
    pub backends: Vec<BackendBenchmarkResult>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BenchmarkMetadataStoreMetrics {
    pub sqlite_metadata_write_micros: u64,
    pub table_counts: BenchmarkMetadataTableCounts,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct BenchmarkMetadataTableCounts {
    pub files: usize,
    pub links: usize,
    pub tags: usize,
    pub properties: usize,
    pub headings: usize,
    pub attachments: usize,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BenchmarkPipelineConfig {
    pub read_parse_workers: usize,
    pub channel_capacity: usize,
    pub writer_memory_budget_bytes: usize,
    pub writer_thread_count: Option<usize>,
    pub metadata_batch_size: usize,
    pub snippet_storage_mode: SnippetStorageMode,
}

impl From<&IndexingPipelineOptions> for BenchmarkPipelineConfig {
    fn from(options: &IndexingPipelineOptions) -> Self {
        let options = options.normalized();
        Self {
            read_parse_workers: options.read_parse_workers,
            channel_capacity: options.channel_capacity,
            writer_memory_budget_bytes: options.writer_options.memory_budget_bytes,
            writer_thread_count: options.writer_options.writer_thread_count,
            metadata_batch_size: options.metadata_batch_size,
            snippet_storage_mode: options.snippet_storage_mode,
        }
    }
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
    pub skipped_query_count: usize,
    pub snippet_result_count: usize,
    pub incremental_update_micros: u64,
    pub index_size_bytes: u64,
    pub peak_rss_bytes: Option<u64>,
    pub stages: BenchmarkBackendStageMetrics,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct BenchmarkCorpusStageMetrics {
    pub scan_micros: u64,
    pub source_collection_micros: u64,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct BenchmarkBackendStageMetrics {
    pub read_parse: BenchmarkReadParseStageMetrics,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sqlite_upsert_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sqlite_rebuild_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sqlite_integrity_check_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sqlite_optimize_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tantivy_add_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tantivy_commit_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tantivy_reader_reload_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub added_document_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deleted_document_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skipped_document_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub failed_document_count: Option<usize>,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct BenchmarkReadParseStageMetrics {
    pub sample_count: usize,
    pub total_bytes: u64,
    pub peak_in_flight_items: usize,
    pub read: BenchmarkDurationSummary,
    pub parse: BenchmarkDurationSummary,
    pub combined: BenchmarkDurationSummary,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
pub struct BenchmarkDurationSummary {
    pub sample_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p50_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p95_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub p99_micros: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_micros: Option<u64>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct BenchmarkRunMetadata {
    pub build_mode: String,
    pub run_condition: String,
    pub sample_count: usize,
    pub git_commit_hash: Option<String>,
    pub redaction_enabled: bool,
}

#[derive(Debug)]
pub enum BackendBenchmarkError {
    EmptyDocuments,
    EmptyQueries,
    Io(std::io::Error),
    Path(PathError),
    Scan(String),
    Metadata(MetadataStoreError),
    Sqlite(SqliteFtsError),
    Tantivy(TantivySearchError),
    Json(serde_json::Error),
}

pub type BackendBenchmarkResultType<T> = Result<T, BackendBenchmarkError>;

pub fn load_search_documents_from_vault(
    vault_root: impl AsRef<Path>,
) -> BackendBenchmarkResultType<Vec<SearchDocument>> {
    let root = VaultRoot::open(vault_root).map_err(BackendBenchmarkError::Path)?;
    let loaded_sources = load_search_document_sources(&root)?;
    let mut documents = Vec::new();

    for source in &loaded_sources.sources {
        documents.push(read_search_document(source)?);
    }

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
    let pipeline_options = IndexingPipelineOptions::default();
    let total_document_bytes = total_document_bytes(&options.documents);
    let sqlite = run_sqlite_benchmark(options, total_document_bytes)?;
    let tantivy = run_tantivy_benchmark(options, total_document_bytes)?;

    Ok(BackendBenchmarkArtifact {
        schema_version: BACKEND_BENCHMARK_ARTIFACT_SCHEMA_VERSION,
        generated_at_unix_seconds: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        corpus_id: options.corpus_id.clone(),
        run_metadata: benchmark_run_metadata("in_memory_documents", options.queries.len()),
        pipeline_config: BenchmarkPipelineConfig::from(&pipeline_options),
        corpus_stages: BenchmarkCorpusStageMetrics::default(),
        document_count: options.documents.len(),
        query_count: options.queries.len(),
        total_document_bytes,
        metadata_store: None,
        backends: vec![sqlite, tantivy],
    })
}

pub fn run_shared_backend_benchmark_from_vault(
    options: &VaultBackendBenchmarkOptions,
) -> BackendBenchmarkResultType<BackendBenchmarkArtifact> {
    if options.queries.is_empty() {
        return Err(BackendBenchmarkError::EmptyQueries);
    }

    let root = VaultRoot::open(&options.vault_root).map_err(BackendBenchmarkError::Path)?;
    let loaded_sources = load_search_document_sources(&root)?;
    if loaded_sources.sources.is_empty() {
        return Err(BackendBenchmarkError::EmptyDocuments);
    }

    fs::create_dir_all(&options.work_dir)?;
    let pipeline_options = IndexingPipelineOptions::default();
    let metadata_store = run_sqlite_metadata_benchmark_from_sources(
        options,
        &loaded_sources.sources,
        &pipeline_options,
    )?;
    let sqlite =
        run_sqlite_benchmark_from_sources(options, &loaded_sources.sources, &pipeline_options)?;
    let tantivy =
        run_tantivy_benchmark_from_sources(options, &loaded_sources.sources, &pipeline_options)?;

    Ok(BackendBenchmarkArtifact {
        schema_version: BACKEND_BENCHMARK_ARTIFACT_SCHEMA_VERSION,
        generated_at_unix_seconds: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        corpus_id: options.corpus_id.clone(),
        run_metadata: benchmark_run_metadata("streaming_vault", options.queries.len()),
        pipeline_config: BenchmarkPipelineConfig::from(&pipeline_options),
        corpus_stages: BenchmarkCorpusStageMetrics::from(loaded_sources.stages),
        document_count: loaded_sources.sources.len(),
        query_count: options.queries.len(),
        total_document_bytes: sqlite.total_document_bytes,
        metadata_store: Some(metadata_store),
        backends: vec![sqlite.result, tantivy.result],
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

fn benchmark_run_metadata(run_condition: &str, sample_count: usize) -> BenchmarkRunMetadata {
    BenchmarkRunMetadata {
        build_mode: current_build_mode().to_string(),
        run_condition: run_condition.to_string(),
        sample_count,
        git_commit_hash: current_git_commit_hash(),
        redaction_enabled: true,
    }
}

fn current_build_mode() -> &'static str {
    if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    }
}

fn current_git_commit_hash() -> Option<String> {
    std::env::var("GIT_COMMIT_HASH")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            std::env::var("GITHUB_SHA")
                .ok()
                .filter(|value| !value.trim().is_empty())
        })
}

impl fmt::Display for BackendBenchmarkError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyDocuments => write!(formatter, "backend benchmark has no documents"),
            Self::EmptyQueries => write!(formatter, "backend benchmark has no queries"),
            Self::Io(error) => write!(formatter, "backend benchmark io error: {error}"),
            Self::Path(error) => write!(formatter, "backend benchmark path error: {error}"),
            Self::Scan(error) => write!(formatter, "backend benchmark scan error: {error}"),
            Self::Metadata(error) => {
                write!(formatter, "backend benchmark metadata error: {error}")
            }
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

impl From<MetadataStoreError> for BackendBenchmarkError {
    fn from(error: MetadataStoreError) -> Self {
        Self::Metadata(error)
    }
}

impl From<TantivySearchError> for BackendBenchmarkError {
    fn from(error: TantivySearchError) -> Self {
        Self::Tantivy(error)
    }
}

impl From<IndexingPipelineError> for BackendBenchmarkError {
    fn from(error: IndexingPipelineError) -> Self {
        match error {
            IndexingPipelineError::Io(error) => Self::Io(error),
            IndexingPipelineError::Scan(error) => Self::Scan(error),
            IndexingPipelineError::Tantivy(error) => Self::Tantivy(error),
        }
    }
}

impl From<serde_json::Error> for BackendBenchmarkError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

struct StreamingBenchmarkResult {
    result: BackendBenchmarkResult,
    total_document_bytes: u64,
}

impl From<PipelineCorpusStageMetrics> for BenchmarkCorpusStageMetrics {
    fn from(stages: PipelineCorpusStageMetrics) -> Self {
        Self {
            scan_micros: stages.scan_micros,
            source_collection_micros: stages.source_collection_micros,
        }
    }
}

fn read_parse_metrics(
    stats: &PipelineCorpusStats,
    peak_in_flight_items: usize,
) -> BenchmarkReadParseStageMetrics {
    BenchmarkReadParseStageMetrics {
        sample_count: stats.read_micros.len(),
        total_bytes: stats.read_parse_bytes,
        peak_in_flight_items,
        read: duration_summary(&stats.read_micros),
        parse: duration_summary(&stats.parse_micros),
        combined: duration_summary(&stats.combined_micros),
    }
}

fn run_sqlite_benchmark(
    options: &BackendBenchmarkOptions,
    total_document_bytes: u64,
) -> BackendBenchmarkResultType<BackendBenchmarkResult> {
    let db_path = options.work_dir.join("sqlite-fts.sqlite");
    remove_sqlite_files(&db_path)?;
    let mut index = SqliteFtsIndex::open(&db_path)?;

    let index_start = Instant::now();
    let upsert_start = Instant::now();
    for document in &options.documents {
        index.upsert_document(document)?;
    }
    let sqlite_upsert_micros = duration_micros_nonzero(upsert_start.elapsed());
    let rebuild_start = Instant::now();
    index.rebuild()?;
    let sqlite_rebuild_micros = duration_micros_nonzero(rebuild_start.elapsed());
    let integrity_check_start = Instant::now();
    index.integrity_check()?;
    let sqlite_integrity_check_micros = duration_micros_nonzero(integrity_check_start.elapsed());
    let optimize_start = Instant::now();
    index.optimize()?;
    let sqlite_optimize_micros = duration_micros_nonzero(optimize_start.elapsed());
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
        BenchmarkBackendStageMetrics {
            sqlite_upsert_micros: Some(sqlite_upsert_micros),
            sqlite_rebuild_micros: Some(sqlite_rebuild_micros),
            sqlite_integrity_check_micros: Some(sqlite_integrity_check_micros),
            sqlite_optimize_micros: Some(sqlite_optimize_micros),
            ..Default::default()
        },
    ))
}

fn run_sqlite_metadata_benchmark_from_sources(
    options: &VaultBackendBenchmarkOptions,
    sources: &[SearchDocumentSource],
    pipeline_options: &IndexingPipelineOptions,
) -> BackendBenchmarkResultType<BenchmarkMetadataStoreMetrics> {
    let db_path = options.work_dir.join("sqlite-metadata.sqlite");
    remove_sqlite_files(&db_path)?;
    let metadata = IndexSchemaMetadata::new("sqlite", "metadata-v1", "none", 0);
    let mut store = MetadataStore::open(&db_path, &metadata)?;
    let batch_size = pipeline_options.normalized().metadata_batch_size;
    let mut pending = Vec::with_capacity(batch_size);
    let mut sqlite_metadata_write_micros = 0;

    run_read_parse_pipeline(sources, pipeline_options, |timed| {
        pending.push(timed.work_item.metadata_records);
        if pending.len() >= batch_size {
            let start = Instant::now();
            store.replace_file_records_batch(&pending)?;
            sqlite_metadata_write_micros += duration_micros_nonzero(start.elapsed());
            pending.clear();
        }
        Ok::<(), BackendBenchmarkError>(())
    })?;

    if !pending.is_empty() {
        let start = Instant::now();
        store.replace_file_records_batch(&pending)?;
        sqlite_metadata_write_micros += duration_micros_nonzero(start.elapsed());
    }

    Ok(BenchmarkMetadataStoreMetrics {
        sqlite_metadata_write_micros,
        table_counts: metadata_table_counts(&store)?,
    })
}

fn metadata_table_counts(
    store: &MetadataStore,
) -> BackendBenchmarkResultType<BenchmarkMetadataTableCounts> {
    Ok(BenchmarkMetadataTableCounts {
        files: store.row_count(MetadataTable::Files)?,
        links: store.row_count(MetadataTable::Links)?,
        tags: store.row_count(MetadataTable::Tags)?,
        properties: store.row_count(MetadataTable::Properties)?,
        headings: store.row_count(MetadataTable::Headings)?,
        attachments: store.row_count(MetadataTable::Attachments)?,
    })
}

fn run_sqlite_benchmark_from_sources(
    options: &VaultBackendBenchmarkOptions,
    sources: &[SearchDocumentSource],
    pipeline_options: &IndexingPipelineOptions,
) -> BackendBenchmarkResultType<StreamingBenchmarkResult> {
    let db_path = options.work_dir.join("sqlite-fts.sqlite");
    remove_sqlite_files(&db_path)?;
    let mut index = SqliteFtsIndex::open(&db_path)?;

    let index_start = Instant::now();
    let mut sqlite_upsert_micros = 0;
    let pipeline = run_read_parse_pipeline(sources, pipeline_options, |timed| {
        let upsert_start = Instant::now();
        index.upsert_document(&timed.document)?;
        sqlite_upsert_micros += duration_micros_nonzero(upsert_start.elapsed());
        Ok::<(), BackendBenchmarkError>(())
    })?;
    let stats = pipeline.stats;
    let rebuild_start = Instant::now();
    index.rebuild()?;
    let sqlite_rebuild_micros = duration_micros_nonzero(rebuild_start.elapsed());
    let integrity_check_start = Instant::now();
    index.integrity_check()?;
    let sqlite_integrity_check_micros = duration_micros_nonzero(integrity_check_start.elapsed());
    let optimize_start = Instant::now();
    index.optimize()?;
    let sqlite_optimize_micros = duration_micros_nonzero(optimize_start.elapsed());
    let index_duration = index_start.elapsed();
    let query_stats = measure_queries(&options.queries, |query| {
        index
            .search(query, options.result_limit)
            .map_err(Into::into)
    })?;
    let incremental_update_micros = measure_sqlite_incremental_update_doc(
        &mut index,
        stats
            .first_document()
            .ok_or(BackendBenchmarkError::EmptyDocuments)?,
    )?;

    Ok(StreamingBenchmarkResult {
        result: backend_result(
            "sqlite_fts",
            index_duration,
            stats.document_count,
            stats.total_document_bytes,
            query_stats,
            incremental_update_micros,
            index.estimated_size_bytes()?,
            BenchmarkBackendStageMetrics {
                sqlite_upsert_micros: Some(sqlite_upsert_micros),
                sqlite_rebuild_micros: Some(sqlite_rebuild_micros),
                sqlite_integrity_check_micros: Some(sqlite_integrity_check_micros),
                sqlite_optimize_micros: Some(sqlite_optimize_micros),
                read_parse: read_parse_metrics(&stats, pipeline.peak_in_flight_items),
                ..Default::default()
            },
        ),
        total_document_bytes: stats.total_document_bytes,
    })
}

fn run_tantivy_benchmark(
    options: &BackendBenchmarkOptions,
    total_document_bytes: u64,
) -> BackendBenchmarkResultType<BackendBenchmarkResult> {
    let index_dir = options.work_dir.join("tantivy");
    reset_directory(&index_dir)?;
    let mut index = TantivySearchIndex::open_in_dir(&index_dir)?;

    let index_start = Instant::now();
    let tantivy_stages = index.replace_documents_with_stage_durations(&options.documents)?;
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
        tantivy_stage_metrics(tantivy_stages),
    ))
}

fn run_tantivy_benchmark_from_sources(
    options: &VaultBackendBenchmarkOptions,
    sources: &[SearchDocumentSource],
    pipeline_options: &IndexingPipelineOptions,
) -> BackendBenchmarkResultType<StreamingBenchmarkResult> {
    let index_dir = options.work_dir.join("tantivy");
    reset_directory(&index_dir)?;
    let mut index = TantivySearchIndex::open_in_dir(&index_dir)?;

    let index_start = Instant::now();
    let pipeline = run_tantivy_rebuild_pipeline(&mut index, sources, pipeline_options)?;
    let stats = pipeline.stats;
    let index_duration = index_start.elapsed();
    let query_stats = measure_queries(&options.queries, |query| {
        index
            .search(query, options.result_limit)
            .map_err(Into::into)
    })?;
    let incremental_update_micros = measure_tantivy_incremental_update_doc(
        &mut index,
        stats
            .first_document()
            .ok_or(BackendBenchmarkError::EmptyDocuments)?,
    )?;

    Ok(StreamingBenchmarkResult {
        result: backend_result(
            "tantivy",
            index_duration,
            stats.document_count,
            stats.total_document_bytes,
            query_stats,
            incremental_update_micros,
            index.estimated_size_bytes()?,
            BenchmarkBackendStageMetrics {
                read_parse: read_parse_metrics(&stats, pipeline.peak_in_flight_items),
                ..tantivy_stage_metrics(pipeline.stages)
            },
        ),
        total_document_bytes: stats.total_document_bytes,
    })
}

struct QueryStats {
    p95: Duration,
    p99: Duration,
    result_count: usize,
    skipped_count: usize,
    snippet_count: usize,
}

fn measure_queries<F>(queries: &[String], mut search: F) -> BackendBenchmarkResultType<QueryStats>
where
    F: FnMut(&str) -> BackendBenchmarkResultType<Vec<SearchResult>>,
{
    let mut durations = Vec::with_capacity(queries.len());
    let mut result_count = 0;
    let mut skipped_count = 0;
    let mut snippet_count = 0;

    for query in queries {
        let start = Instant::now();
        let results = match search(query) {
            Ok(results) => results,
            Err(error) if is_empty_query_error(&error) => {
                skipped_count += 1;
                continue;
            }
            Err(error) => return Err(error),
        };
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
        skipped_count,
        snippet_count,
    })
}

fn measure_sqlite_incremental_update(
    index: &mut SqliteFtsIndex,
    options: &BackendBenchmarkOptions,
) -> BackendBenchmarkResultType<u64> {
    measure_sqlite_incremental_update_doc(index, &options.documents[0])
}

fn measure_sqlite_incremental_update_doc(
    index: &mut SqliteFtsIndex,
    document: &SearchDocument,
) -> BackendBenchmarkResultType<u64> {
    let mut document = document.clone();
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
    measure_tantivy_incremental_update_doc(index, &options.documents[0])
}

fn measure_tantivy_incremental_update_doc(
    index: &mut TantivySearchIndex,
    document: &SearchDocument,
) -> BackendBenchmarkResultType<u64> {
    let mut document = document.clone();
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
    stages: BenchmarkBackendStageMetrics,
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
        skipped_query_count: query_stats.skipped_count,
        snippet_result_count: query_stats.snippet_count,
        incremental_update_micros,
        index_size_bytes,
        peak_rss_bytes: peak_rss_bytes(),
        stages,
    }
}

fn tantivy_stage_metrics(stages: TantivyIndexingStageMetrics) -> BenchmarkBackendStageMetrics {
    BenchmarkBackendStageMetrics {
        tantivy_add_micros: Some(stages.add_micros),
        tantivy_commit_micros: Some(stages.commit_micros),
        tantivy_reader_reload_micros: Some(stages.reader_reload_micros),
        added_document_count: Some(stages.added_document_count),
        deleted_document_count: Some(stages.deleted_document_count),
        skipped_document_count: Some(stages.skipped_document_count),
        failed_document_count: Some(stages.failed_document_count),
        ..Default::default()
    }
}

fn is_empty_query_error(error: &BackendBenchmarkError) -> bool {
    matches!(
        error,
        BackendBenchmarkError::Sqlite(SqliteFtsError::EmptyQuery)
            | BackendBenchmarkError::Tantivy(TantivySearchError::EmptyQuery)
    )
}

fn total_document_bytes(documents: &[SearchDocument]) -> u64 {
    documents.iter().map(document_bytes).sum()
}

fn document_bytes(document: &SearchDocument) -> u64 {
    document.path.len() as u64 + document.title.len() as u64 + document.body.len() as u64
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

fn duration_micros_nonzero(duration: Duration) -> u64 {
    duration_micros(duration).max(1)
}

fn duration_summary(values: &[u64]) -> BenchmarkDurationSummary {
    if values.is_empty() {
        return BenchmarkDurationSummary::default();
    }

    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    let include_percentiles = sorted.len() > 1;

    BenchmarkDurationSummary {
        sample_count: sorted.len(),
        p50_micros: include_percentiles.then(|| percentile_value(&sorted, 50)),
        p95_micros: include_percentiles.then(|| percentile_value(&sorted, 95)),
        p99_micros: include_percentiles.then(|| percentile_value(&sorted, 99)),
        max_micros: sorted.last().copied(),
    }
}

fn percentile_value(values: &[u64], percentile: usize) -> u64 {
    let index = ((values.len() * percentile).div_ceil(100)).saturating_sub(1);
    values[index.min(values.len() - 1)]
}

fn remove_file_if_exists(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn remove_sqlite_files(path: &Path) -> std::io::Result<()> {
    remove_file_if_exists(path)?;
    remove_file_if_exists(&path.with_extension("sqlite-wal"))?;
    remove_file_if_exists(&path.with_extension("sqlite-shm"))?;
    Ok(())
}

fn reset_directory(path: &Path) -> std::io::Result<()> {
    if path.exists() {
        fs::remove_dir_all(path)?;
    }
    fs::create_dir_all(path)
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
                "!!!".to_string(),
            ],
            result_limit: 10,
            work_dir: temp.path().join("indexes"),
        };

        let artifact = run_shared_backend_benchmark(&options).expect("benchmark");
        write_backend_benchmark_artifact(&artifact_path, &artifact, true).expect("write artifact");
        let json = fs::read_to_string(&artifact_path).expect("artifact json");

        assert_eq!(
            artifact.schema_version,
            BACKEND_BENCHMARK_ARTIFACT_SCHEMA_VERSION
        );
        assert_eq!(artifact.document_count, options.documents.len());
        assert_eq!(artifact.query_count, options.queries.len());
        assert_eq!(artifact.run_metadata.run_condition, "in_memory_documents");
        assert_eq!(artifact.run_metadata.sample_count, options.queries.len());
        assert!(artifact.run_metadata.redaction_enabled);
        assert!(artifact.pipeline_config.read_parse_workers > 0);
        assert!(artifact.pipeline_config.channel_capacity > 0);
        assert_eq!(artifact.backends.len(), 2);
        assert!(artifact.backends.iter().all(|backend| {
            backend.query_p95_micros <= backend.query_p99_micros
                && backend.index_size_bytes > 0
                && backend.skipped_query_count == 1
                && backend.snippet_result_count > 0
        }));
        assert!(json.contains("\"sqlite_fts\""));
        assert!(json.contains("\"tantivy\""));
        assert!(!json.contains("Welcome to the compatibility fixture vault"));
    }

    #[test]
    fn benchmark_module_ready() {
        assert!(super::benchmark_module_ready());
        assert_eq!(BenchmarkCorpusStageMetrics::default().scan_micros, 0);
        assert_eq!(
            BenchmarkBackendStageMetrics::default()
                .read_parse
                .sample_count,
            0
        );
    }

    #[test]
    fn pipeline_options_defaults_are_bounded() {
        let options = IndexingPipelineOptions::default();

        assert!(options.read_parse_workers > 0);
        assert!(options.read_parse_workers <= MAX_DEFAULT_READ_PARSE_WORKERS);
        assert!(options.channel_capacity > 0);
        assert!(options.metadata_batch_size > 0);
        assert_eq!(options.snippet_storage_mode, SnippetStorageMode::StoredBody);
    }

    #[test]
    fn source_fixture_builds_markdown_and_attachment_sources() {
        let temp = tempfile::tempdir().expect("tempdir");
        let markdown = source_fixture(temp.path(), "Home.md", ScanEntryKind::Markdown);
        let attachment = source_fixture(
            temp.path(),
            "attachments/diagram.svg",
            ScanEntryKind::Attachment,
        );

        assert_eq!(markdown.kind, ScanEntryKind::Markdown);
        assert_eq!(markdown.file_id, "home.md");
        assert_eq!(attachment.kind, ScanEntryKind::Attachment);
        assert_eq!(
            attachment.relative_path,
            PathBuf::from("attachments/diagram.svg")
        );
    }

    #[test]
    fn read_parse_source_reports_nonzero_bytes() {
        let temp = tempfile::tempdir().expect("tempdir");
        let path = temp.path().join("Home.md");
        fs::write(&path, "# Home\nFixture body.").expect("fixture markdown");
        let source = source_fixture(temp.path(), "Home.md", ScanEntryKind::Markdown);

        let timed = read_parse_source(&source).expect("timed document");

        assert_eq!(timed.document.title, "Home");
        assert_eq!(timed.work_item.file_id, "home.md");
        assert_eq!(timed.work_item.relative_path, PathBuf::from("Home.md"));
        assert_eq!(timed.work_item.title, "Home");
        assert!(timed.work_item.body_len > 0);
        assert!(timed.work_item.timing.bytes > 0);
        assert!(timed.work_item.timing.read_micros > 0);
        assert!(timed.work_item.timing.parse_micros > 0);
        assert!(timed.work_item.timing.combined_micros > 0);
    }

    #[test]
    fn read_parse_source_uses_heading_and_fallback_titles() {
        let temp = tempfile::tempdir().expect("tempdir");
        fs::write(temp.path().join("Heading.md"), "# Heading Title\nBody").expect("heading");
        fs::write(temp.path().join("NoHeading.md"), "Body only").expect("fallback");

        let heading = read_parse_source(&source_fixture(
            temp.path(),
            "Heading.md",
            ScanEntryKind::Markdown,
        ))
        .expect("heading source");
        let fallback = read_parse_source(&source_fixture(
            temp.path(),
            "NoHeading.md",
            ScanEntryKind::Markdown,
        ))
        .expect("fallback source");

        assert_eq!(heading.document.title, "Heading Title");
        assert_eq!(fallback.document.title, "NoHeading");
    }

    #[test]
    fn parsed_work_item_counts_compatibility_fixture_metadata() {
        let root = workspace_root().join("fixtures/compatibility-vault");
        let source = source_fixture(&root, "Home.md", ScanEntryKind::Markdown);

        let timed = read_parse_source(&source).expect("fixture source");
        let counts = timed.work_item.metadata_counts;

        assert!(counts.link_count > 0);
        assert!(counts.tag_count > 0);
        assert!(counts.property_count > 0);
        assert!(counts.heading_count > 0);
        assert!(counts.attachment_count > 0);
        assert_eq!(
            timed.work_item.metadata_records.links.len(),
            counts.link_count
        );
        assert_eq!(
            timed.work_item.metadata_records.tags.len(),
            counts.tag_count
        );
        assert_eq!(
            timed.work_item.metadata_records.properties.len(),
            counts.property_count
        );
        assert_eq!(
            timed.work_item.metadata_records.headings.len(),
            counts.heading_count
        );
        assert_eq!(
            timed.work_item.metadata_records.attachments.len(),
            counts.attachment_count
        );
    }

    #[test]
    fn bounded_read_parse_pipeline_drains_more_items_than_capacity() {
        let temp = tempfile::tempdir().expect("tempdir");
        let mut sources = Vec::new();
        for index in 0..5 {
            let file_name = format!("Note{index}.md");
            fs::write(
                temp.path().join(&file_name),
                format!("# Note {index}\nBody"),
            )
            .expect("write note");
            sources.push(source_fixture(
                temp.path(),
                &file_name,
                ScanEntryKind::Markdown,
            ));
        }
        let options = IndexingPipelineOptions {
            read_parse_workers: 1,
            channel_capacity: 2,
            ..IndexingPipelineOptions::serial()
        };
        let mut drained = 0;

        let run = run_read_parse_pipeline(&sources, &options, |_| {
            drained += 1;
            Ok::<(), BackendBenchmarkError>(())
        })
        .expect("pipeline");

        assert_eq!(drained, 5);
        assert_eq!(run.stats.document_count, 5);
        assert!(run.peak_in_flight_items > 0);
    }

    #[test]
    fn read_parse_pipeline_propagates_missing_file_error() {
        let temp = tempfile::tempdir().expect("tempdir");
        let sources = vec![source_fixture(
            temp.path(),
            "Missing.md",
            ScanEntryKind::Markdown,
        )];

        let error =
            match run_read_parse_pipeline(&sources, &IndexingPipelineOptions::serial(), |_| {
                Ok::<(), BackendBenchmarkError>(())
            }) {
                Ok(_) => panic!("missing file should fail"),
                Err(error) => error,
            };

        assert!(matches!(error, BackendBenchmarkError::Io(_)));
    }

    #[test]
    fn fixture_query_counts_match_serial_and_worker_pipeline() {
        let temp = tempfile::tempdir().expect("tempdir");
        let vault = temp.path().join("vault");
        fs::create_dir_all(vault.join("Docs")).expect("docs dir");
        fs::write(vault.join("Home.md"), "# Home\nShared phrase.").expect("home");
        fs::write(
            vault.join("Docs").join("Guide.md"),
            "# Guide\nShared phrase.",
        )
        .expect("guide");
        let root = VaultRoot::open(&vault).expect("vault root");
        let loaded = load_search_document_sources(&root).expect("sources");
        let base_options = VaultBackendBenchmarkOptions {
            corpus_id: "deterministic-pipeline".to_string(),
            vault_root: vault,
            queries: vec!["Shared phrase".to_string()],
            result_limit: 10,
            work_dir: temp.path().join("indexes"),
        };
        let serial_options = IndexingPipelineOptions::serial();
        let worker_options = IndexingPipelineOptions {
            read_parse_workers: 2,
            channel_capacity: 1,
            ..IndexingPipelineOptions::default()
        };

        let serial =
            run_tantivy_benchmark_from_sources(&base_options, &loaded.sources, &serial_options)
                .expect("serial");
        let worker =
            run_tantivy_benchmark_from_sources(&base_options, &loaded.sources, &worker_options)
                .expect("worker");

        assert_eq!(
            serial.result.query_result_count,
            worker.result.query_result_count
        );
        assert_eq!(worker.result.stages.added_document_count, Some(2));
    }

    #[test]
    fn duration_summary_handles_empty_single_and_multi_item_inputs() {
        assert_eq!(duration_summary(&[]), BenchmarkDurationSummary::default());

        let single = duration_summary(&[7]);
        assert_eq!(single.sample_count, 1);
        assert_eq!(single.p50_micros, None);
        assert_eq!(single.p95_micros, None);
        assert_eq!(single.p99_micros, None);
        assert_eq!(single.max_micros, Some(7));

        let multi = duration_summary(&[30, 10, 20]);
        assert_eq!(multi.sample_count, 3);
        assert_eq!(multi.p50_micros, Some(20));
        assert_eq!(multi.p95_micros, Some(30));
        assert_eq!(multi.p99_micros, Some(30));
        assert_eq!(multi.max_micros, Some(30));
    }

    #[test]
    fn runs_vault_benchmark_without_preloading_document_bodies() {
        let temp = tempfile::tempdir().expect("tempdir");
        let vault = temp.path().join("vault");
        fs::create_dir_all(vault.join("Docs")).expect("docs dir");
        fs::write(
            vault.join("Home.md"),
            "# Home\nWelcome to the streaming benchmark fixture.",
        )
        .expect("home");
        fs::write(
            vault.join("Docs").join("Guide.md"),
            "# Guide\nGuide links back to Home.",
        )
        .expect("guide");

        let options = VaultBackendBenchmarkOptions {
            corpus_id: "vault-streaming-smoke".to_string(),
            vault_root: vault,
            queries: vec!["Home".to_string(), "Guide".to_string()],
            result_limit: 10,
            work_dir: temp.path().join("indexes"),
        };

        let artifact = run_shared_backend_benchmark_from_vault(&options).expect("benchmark");
        let artifact_path = temp.path().join("vault-benchmark.json");
        write_backend_benchmark_artifact(&artifact_path, &artifact, true).expect("artifact");
        let json = fs::read_to_string(&artifact_path).expect("artifact json");

        assert_eq!(artifact.document_count, 2);
        assert_eq!(artifact.query_count, 2);
        assert!(artifact.pipeline_config.read_parse_workers > 0);
        assert_eq!(
            artifact.pipeline_config.snippet_storage_mode,
            SnippetStorageMode::StoredBody
        );
        assert!(artifact.corpus_stages.scan_micros > 0);
        assert!(artifact.corpus_stages.source_collection_micros > 0);
        let metadata_store = artifact.metadata_store.as_ref().expect("metadata store");
        assert!(metadata_store.sqlite_metadata_write_micros > 0);
        assert_eq!(metadata_store.table_counts.files, artifact.document_count);
        assert_eq!(
            metadata_store.table_counts.headings,
            artifact.document_count
        );
        assert!(json.contains("\"sqlite_metadata_write_micros\""));
        assert!(json.contains("\"table_counts\""));
        assert_eq!(artifact.run_metadata.run_condition, "streaming_vault");
        assert_eq!(artifact.run_metadata.sample_count, options.queries.len());
        assert!(artifact.run_metadata.redaction_enabled);
        assert_eq!(artifact.backends.len(), 2);
        assert!(artifact.total_document_bytes > 0);
        assert!(artifact.backends.iter().all(|backend| {
            backend.index_size_bytes > 0 && backend.query_p95_micros <= backend.query_p99_micros
        }));
        assert!(artifact.backends.iter().all(|backend| {
            backend.stages.read_parse.sample_count == artifact.document_count
                && backend.stages.read_parse.total_bytes > 0
                && backend.stages.read_parse.peak_in_flight_items > 0
                && backend.stages.read_parse.read.sample_count == artifact.document_count
                && backend.stages.read_parse.parse.sample_count == artifact.document_count
                && backend.stages.read_parse.combined.sample_count == artifact.document_count
        }));
        let sqlite = artifact
            .backends
            .iter()
            .find(|backend| backend.backend == "sqlite_fts")
            .expect("sqlite backend");
        assert!(sqlite.stages.sqlite_upsert_micros.expect("sqlite upsert") > 0);
        assert!(sqlite.stages.sqlite_rebuild_micros.expect("sqlite rebuild") > 0);
        assert!(
            sqlite
                .stages
                .sqlite_integrity_check_micros
                .expect("sqlite integrity")
                > 0
        );
        assert!(
            sqlite
                .stages
                .sqlite_optimize_micros
                .expect("sqlite optimize")
                > 0
        );
        let tantivy = artifact
            .backends
            .iter()
            .find(|backend| backend.backend == "tantivy")
            .expect("tantivy backend");
        assert!(tantivy.stages.tantivy_add_micros.expect("tantivy add") > 0);
        assert!(
            tantivy
                .stages
                .tantivy_commit_micros
                .expect("tantivy commit")
                > 0
        );
        assert!(
            tantivy
                .stages
                .tantivy_reader_reload_micros
                .expect("tantivy reload")
                > 0
        );
        assert_eq!(
            tantivy.stages.added_document_count,
            Some(artifact.document_count)
        );
        assert_eq!(tantivy.stages.deleted_document_count, Some(0));
        assert_eq!(tantivy.stages.skipped_document_count, Some(0));
        assert_eq!(tantivy.stages.failed_document_count, Some(0));
    }

    #[test]
    fn benchmark_artifact_omits_queries_paths_and_note_snippets() {
        let temp = tempfile::tempdir().expect("tempdir");
        let artifact_path = temp.path().join("privacy-benchmark.json");
        let options = BackendBenchmarkOptions {
            corpus_id: "privacy-smoke".to_string(),
            documents: vec![SearchDocument {
                file_id: "private-file-id".to_string(),
                path: "Private/Secret Note.md".to_string(),
                title: "Secret Note".to_string(),
                body: "private body phrase should not be serialized".to_string(),
            }],
            queries: vec!["private body phrase".to_string()],
            result_limit: 10,
            work_dir: temp.path().join("indexes"),
        };

        let artifact = run_shared_backend_benchmark(&options).expect("benchmark");
        write_backend_benchmark_artifact(&artifact_path, &artifact, true).expect("artifact");
        let json = fs::read_to_string(&artifact_path).expect("json");

        assert!(!json.contains("private body phrase"));
        assert!(!json.contains("Private/Secret Note.md"));
        assert!(!json.contains("Secret Note"));
        assert!(!json.contains("private-file-id"));
        assert!(json.contains("\"run_metadata\""));
        assert!(json.contains("\"pipeline_config\""));
        assert!(json.contains("\"read_parse_workers\""));
        assert!(json.contains("\"channel_capacity\""));
        assert!(json.contains("\"sample_count\": 1"));
        assert!(json.contains("\"redaction_enabled\": true"));
        assert!(json.contains("\"corpus_stages\""));
        assert!(json.contains("\"scan_micros\""));
        assert!(json.contains("\"source_collection_micros\""));
        assert!(json.contains("\"stages\""));
        assert!(json.contains("\"read_parse\""));
        assert!(json.contains("\"sqlite_upsert_micros\""));
        assert!(json.contains("\"tantivy_add_micros\""));
        assert!(json.contains("\"tantivy_commit_micros\""));
        assert!(json.contains("\"tantivy_reader_reload_micros\""));
        assert!(json.contains("\"added_document_count\""));
        assert!(json.contains("\"deleted_document_count\""));
        assert!(json.contains("\"skipped_document_count\""));
        assert!(json.contains("\"failed_document_count\""));
        assert!(json.contains("\"snippet_result_count\""));
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

    fn source_fixture(
        root: &Path,
        relative_path: &str,
        kind: ScanEntryKind,
    ) -> SearchDocumentSource {
        let relative_path = PathBuf::from(relative_path);
        let absolute_path = root.join(&relative_path);
        let metadata = fs::metadata(&absolute_path).ok();
        SearchDocumentSource {
            file_id: lookup_key(&relative_path),
            relative_path,
            absolute_path,
            kind,
            size_bytes: metadata.as_ref().map_or(0, |metadata| metadata.len()),
            modified: metadata.and_then(|metadata| metadata.modified().ok()),
            file_identity: FileIdentity {
                device: 1,
                inode: 1,
            },
        }
    }

    fn workspace_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("workspace root")
            .to_path_buf()
    }
}
