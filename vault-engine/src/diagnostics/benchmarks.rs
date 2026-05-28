use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::adapters::fs::path_resolver::VaultRoot;
use crate::adapters::fs::scanner::{ScanError, scan_vault};
use crate::adapters::sqlite::{
    FileRecord, GraphQueryStage, IndexSchemaMetadata, LinkEdgeRecord, MetadataStore,
    MetadataStoreError, MetadataTable, TagRecord, TagSource,
};
use crate::adapters::sqlite::{SqliteFtsError, SqliteFtsIndex};
use crate::adapters::tantivy::{
    TantivyIndexingStageMetrics, TantivySearchError, TantivySearchIndex,
};
use crate::core::document::ParsedMarkdown;
#[cfg(test)]
use crate::core::files::FileIdentity;
use crate::core::graph::{WholeVaultGraphRequest, WholeVaultGraphSnapshot};
use crate::core::markdown_parser::parse_markdown;
use crate::core::paths::{PathError, lookup_key};
use crate::core::scan::{ScanEntry, ScanEntryKind};
use crate::core::search::{SearchDocument, SearchResult};
use crate::use_cases::build_graph::build_whole_vault_graph_from_metadata;
use crate::use_cases::index_rebuild::IndexRebuildPaths;
#[cfg(test)]
use crate::use_cases::indexing_pipeline::read_parse_source;
pub use crate::use_cases::indexing_pipeline::{
    IndexingMode, IndexingPipelineOptions, MAX_DEFAULT_READ_PARSE_WORKERS, SnippetStorageMode,
};
use crate::use_cases::indexing_pipeline::{
    IndexingPipelineError, PipelineCorpusStageMetrics, PipelineCorpusStats, SearchDocumentSource,
    load_search_document_sources, read_search_document, run_full_rebuild_pipeline,
    run_read_parse_pipeline, run_tantivy_rebuild_pipeline,
};
use crate::use_cases::read_vault::expected_read_schema_metadata_for_generation;

pub const BACKEND_BENCHMARK_ARTIFACT_SCHEMA_VERSION: u32 = 7;

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
    pub time_to_usable_sample_count: usize,
    pub snippet_storage_mode: SnippetStorageMode,
    pub include_sqlite_fts: bool,
}

#[derive(Debug, Clone)]
pub struct WholeVaultGraphBenchmarkOptions {
    pub vault_alias: String,
    pub code_revision: String,
    pub vault_root: PathBuf,
    pub max_nodes: usize,
    pub max_edges: usize,
    pub include_unresolved: bool,
    pub include_orphans: bool,
    pub swift_decode_duration_milliseconds: f64,
    pub swift_decode_memory_bytes: u64,
    pub private_payload_output: Option<PathBuf>,
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
    pub time_to_usable_micros: Option<u64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub time_to_usable_samples: Vec<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata_store: Option<BenchmarkMetadataStoreMetrics>,
    pub backends: Vec<BackendBenchmarkResult>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WholeVaultGraphBenchmarkArtifact {
    pub artifact_version: u32,
    pub generated_at: String,
    pub vault_alias: String,
    pub code_revision: String,
    pub artifact_kind: String,
    pub stage: String,
    pub backend_version: String,
    pub store_schema_version: u32,
    pub renderer_kind: String,
    pub graph_generation: u64,
    pub graph_state: String,
    pub counts: WholeVaultGraphBenchmarkCounts,
    pub measurements: Vec<WholeVaultGraphMeasurement>,
    pub indexed_access_summary: Vec<WholeVaultGraphIndexedAccess>,
    pub bridge_decision: WholeVaultGraphBridgeDecision,
    pub budget_results: Vec<WholeVaultGraphBudgetResult>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WholeVaultGraphBenchmarkCounts {
    pub node_count: usize,
    pub edge_count: usize,
    pub visible_node_count: usize,
    pub visible_edge_count: usize,
    pub component_count: usize,
    pub partial_reason_count: usize,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WholeVaultGraphMeasurement {
    pub name: String,
    pub unit: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocker_code: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WholeVaultGraphIndexedAccess {
    pub stage: String,
    pub uses_index: bool,
    pub scan_kind: String,
    pub duration_milliseconds: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WholeVaultGraphBridgeDecision {
    pub format: String,
    pub encoded_payload_bytes: usize,
    pub decision_reason: String,
    pub payload_version: u32,
    pub request_scoped: bool,
    pub byte_cap_bytes: usize,
    pub count_validation: bool,
    pub duplicate_node_validation: bool,
    pub enum_validation: bool,
    pub edge_reference_validation: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WholeVaultGraphBudgetResult {
    pub name: String,
    pub unit: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub measured: Option<f64>,
    pub target: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blocker_code: Option<String>,
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
        time_to_usable_micros: None,
        time_to_usable_samples: Vec::new(),
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
    let pipeline_options = IndexingPipelineOptions {
        snippet_storage_mode: options.snippet_storage_mode,
        ..Default::default()
    };
    let metadata_store = run_sqlite_metadata_benchmark_from_sources(
        options,
        &loaded_sources.sources,
        &pipeline_options,
    )?;
    let tantivy =
        run_tantivy_benchmark_from_sources(options, &loaded_sources.sources, &pipeline_options)?;
    let sqlite = if options.include_sqlite_fts {
        Some(run_sqlite_benchmark_from_sources(
            options,
            &loaded_sources.sources,
            &pipeline_options,
        )?)
    } else {
        None
    };
    let total_document_bytes = sqlite
        .as_ref()
        .map(|benchmark| benchmark.total_document_bytes)
        .unwrap_or(tantivy.total_document_bytes);
    let time_to_usable_micros = loaded_sources.stages.scan_micros
        + loaded_sources.stages.source_collection_micros
        + metadata_store.sqlite_metadata_write_micros
        + tantivy.result.initial_index_micros;
    let mut time_to_usable_samples = vec![time_to_usable_micros.max(1)];
    for sample_index in 1..options.time_to_usable_sample_count.max(1) {
        time_to_usable_samples.push(measure_time_to_usable_sample(
            options,
            &loaded_sources.sources,
            &pipeline_options,
            sample_index,
        )?);
    }

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
        total_document_bytes,
        time_to_usable_micros: time_to_usable_samples.first().copied(),
        time_to_usable_samples,
        metadata_store: Some(metadata_store),
        backends: match sqlite {
            Some(sqlite) => vec![sqlite.result, tantivy.result],
            None => vec![tantivy.result],
        },
    })
}

pub fn run_whole_vault_graph_snapshot_benchmark(
    options: &WholeVaultGraphBenchmarkOptions,
) -> BackendBenchmarkResultType<WholeVaultGraphBenchmarkArtifact> {
    let root = VaultRoot::open(&options.vault_root).map_err(BackendBenchmarkError::Path)?;
    let setup_rss_before = current_rss_bytes();
    let scan = scan_vault(&root).map_err(scan_error_to_string)?;
    let markdown_entries = scan
        .entries
        .into_iter()
        .filter(|entry| entry.kind == ScanEntryKind::Markdown)
        .collect::<Vec<_>>();
    if markdown_entries.is_empty() {
        return Err(BackendBenchmarkError::EmptyDocuments);
    }

    let metadata = expected_read_schema_metadata_for_generation(1);
    let mut store = MetadataStore::open_in_memory(&metadata)?;
    let target_map = graph_target_map(&markdown_entries);
    for entry in &markdown_entries {
        let source = fs::read_to_string(root.canonical_root().join(&entry.relative_path))?;
        let parsed = parse_markdown(&source);
        let mut file = FileRecord::from_scan_entry(entry, 1);
        file.mark_search_indexed();
        let links = graph_link_records(&file.file_id, &parsed, &target_map);
        let tags = parsed
            .tags
            .into_iter()
            .map(|tag| TagRecord {
                file_id: file.file_id.clone(),
                tag,
                source: TagSource::Inline,
            })
            .collect::<Vec<_>>();
        store.replace_file_records(&file, &links, &tags, &[], &[], &[])?;
    }

    let setup_rss_after = current_rss_bytes();
    let setup_rss_delta = setup_rss_before
        .zip(setup_rss_after)
        .map(|(before, after)| after.saturating_sub(before));
    let request = WholeVaultGraphRequest::with_request_id(1, options.max_nodes, options.max_edges)
        .including_unresolved(options.include_unresolved)
        .including_orphans(options.include_orphans);
    store.release_memory()?;
    release_benchmark_allocator_memory();
    let rss_before = current_rss_bytes();
    let snapshot_start = Instant::now();
    let build = build_whole_vault_graph_from_metadata(&store, 1, request)?;
    let snapshot_duration = snapshot_start.elapsed();
    let snapshot_ms = duration_millis(snapshot_duration);
    let encoded_payload_bytes = graph_payload_bytes(&build.snapshot, snapshot_ms)?;
    store.release_memory()?;
    release_benchmark_allocator_memory();
    let rss_after = current_rss_bytes();
    let rss_delta = rss_before
        .zip(rss_after)
        .map(|(before, after)| after.saturating_sub(before));
    if let Some(path) = &options.private_payload_output {
        write_private_graph_payload(path, &build.snapshot, snapshot_ms, encoded_payload_bytes)?;
    }

    let plans = store.graph_query_plan_summaries(1)?;
    let node_count_start = Instant::now();
    let _ =
        store.graph_visible_node_count(1, request.include_unresolved, request.include_orphans)?;
    let node_count_duration = node_count_start.elapsed();
    let edge_count_start = Instant::now();
    let _ = store.graph_visible_edge_count(1, request.include_unresolved)?;
    let edge_count_duration = edge_count_start.elapsed();
    let indexed_access_summary = graph_indexed_access_summary(
        &plans,
        request,
        snapshot_duration,
        node_count_duration,
        edge_count_duration,
    );
    let memory_target = 250.0 * 1024.0 * 1024.0;
    let swift_decode_target = 1_500.0;
    let swift_decode_memory_target = 200.0 * 1024.0 * 1024.0;
    let bridge_decision = bridge_decision(
        encoded_payload_bytes,
        options.swift_decode_duration_milliseconds,
        options.swift_decode_memory_bytes,
    );
    Ok(WholeVaultGraphBenchmarkArtifact {
        artifact_version: 1,
        generated_at: rfc3339_now(),
        vault_alias: options.vault_alias.clone(),
        code_revision: options.code_revision.clone(),
        artifact_kind: "stage".to_string(),
        stage: "snapshot".to_string(),
        backend_version: metadata.backend_version,
        store_schema_version: crate::adapters::sqlite::INDEX_SCHEMA_VERSION,
        renderer_kind: "none".to_string(),
        graph_generation: 1,
        graph_state: if build.partial {
            "partial".to_string()
        } else {
            "complete".to_string()
        },
        counts: WholeVaultGraphBenchmarkCounts {
            node_count: build.snapshot.node_count_total,
            edge_count: build.snapshot.edge_count_total,
            visible_node_count: build.snapshot.nodes.len(),
            visible_edge_count: build.snapshot.edges.len(),
            component_count: 0,
            partial_reason_count: build.snapshot.partial_reasons.len(),
        },
        measurements: vec![
            measurement(
                "snapshotDuration",
                "milliseconds",
                Some(snapshot_ms),
                Some(2_500.0),
            ),
            measurement(
                "encodedPayloadBytes",
                "bytes",
                Some(encoded_payload_bytes as f64),
                Some(64.0 * 1024.0 * 1024.0),
            ),
            measurement(
                "decodeDuration",
                "milliseconds",
                Some(options.swift_decode_duration_milliseconds),
                Some(swift_decode_target),
            ),
            measurement(
                "swiftDecodeMemory",
                "bytes",
                Some(options.swift_decode_memory_bytes as f64),
                Some(swift_decode_memory_target),
            ),
            match rss_delta {
                Some(value) => measurement(
                    "rustSnapshotMemory",
                    "bytes",
                    Some(value as f64),
                    Some(memory_target),
                ),
                None => blocked_measurement("rustSnapshotMemory", "bytes", "unknown"),
            },
            match setup_rss_delta {
                Some(value) => measurement("graphSetupMemory", "bytes", Some(value as f64), None),
                None => blocked_measurement("graphSetupMemory", "bytes", "unknown"),
            },
        ],
        indexed_access_summary,
        bridge_decision,
        budget_results: vec![
            budget_result("rustSnapshot", "milliseconds", snapshot_ms, 2_500.0),
            budget_result(
                "swiftDecode",
                "milliseconds",
                options.swift_decode_duration_milliseconds,
                swift_decode_target,
            ),
            match rss_delta {
                Some(value) => {
                    budget_result("rustSnapshotMemory", "bytes", value as f64, memory_target)
                }
                None => {
                    blocked_budget_result("rustSnapshotMemory", "bytes", memory_target, "unknown")
                }
            },
            budget_result(
                "swiftDecodeMemory",
                "bytes",
                options.swift_decode_memory_bytes as f64,
                swift_decode_memory_target,
            ),
        ],
    })
}

fn write_private_graph_payload(
    path: &Path,
    snapshot: &WholeVaultGraphSnapshot,
    snapshot_duration_milliseconds: f64,
    encoded_payload_bytes: usize,
) -> BackendBenchmarkResultType<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let file = fs::File::create(path)?;
    serde_json::to_writer(
        file,
        &graph_payload_envelope(
            snapshot,
            snapshot_duration_milliseconds,
            encoded_payload_bytes,
        ),
    )?;
    Ok(())
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
            IndexingPipelineError::Path(error) => Self::Path(error),
            IndexingPipelineError::Scan(error) => Self::Scan(error),
            IndexingPipelineError::Rebuild(error) => Self::Scan(error.to_string()),
            IndexingPipelineError::Metadata(error) => Self::Metadata(error),
            IndexingPipelineError::Queue(error) => Self::Scan(error.to_string()),
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
    let metadata = IndexSchemaMetadata::new(
        "sqlite",
        "metadata-v1",
        pipeline_options
            .normalized()
            .snippet_storage_mode
            .config_name(),
        0,
    );
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

fn measure_time_to_usable_sample(
    options: &VaultBackendBenchmarkOptions,
    sources: &[SearchDocumentSource],
    pipeline_options: &IndexingPipelineOptions,
    sample_index: usize,
) -> BackendBenchmarkResultType<u64> {
    let sample_root = options
        .work_dir
        .join(format!("time-to-usable-sample-{sample_index}"));
    reset_directory(&sample_root)?;
    let paths = IndexRebuildPaths::new(
        &options.vault_root,
        &sample_root,
        sample_root.join("data"),
        sample_root.join("rebuild"),
    );
    let metadata = IndexSchemaMetadata::new(
        "sqlite+tantivy",
        "metadata-v1",
        pipeline_options
            .normalized()
            .snippet_storage_mode
            .config_name(),
        0,
    );
    let result = run_full_rebuild_pipeline(&paths, sources, &metadata, pipeline_options)?;
    Ok(result.time_to_usable_micros.unwrap_or(1).max(1))
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
    let mut index = TantivySearchIndex::open_in_dir_with_snippet_mode(
        &index_dir,
        pipeline_options.snippet_storage_mode,
    )?;

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
            tantivy_backend_name(pipeline_options.snippet_storage_mode),
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

fn tantivy_backend_name(snippet_storage_mode: SnippetStorageMode) -> &'static str {
    match snippet_storage_mode {
        SnippetStorageMode::StoredBody => "tantivy",
        SnippetStorageMode::LazySourceExperiment => "tantivy_lazy_source_experiment",
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

fn duration_millis(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1_000.0
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

fn graph_target_map(entries: &[ScanEntry]) -> HashMap<String, Vec<String>> {
    let mut targets: HashMap<String, Vec<String>> = HashMap::new();
    for entry in entries {
        for key in graph_note_keys(&entry.relative_path) {
            targets
                .entry(key)
                .or_default()
                .push(lookup_key(&entry.relative_path));
        }
    }
    targets
}

fn graph_note_keys(relative_path: &Path) -> Vec<String> {
    let without_extension = relative_path.with_extension("");
    let mut keys = vec![benchmark_link_target_key(
        &without_extension.to_string_lossy(),
    )];
    if let Some(stem) = relative_path.file_stem().and_then(|value| value.to_str()) {
        let basename_key = benchmark_link_target_key(stem);
        if !keys.contains(&basename_key) {
            keys.push(basename_key);
        }
    }
    keys
}

fn benchmark_link_target_key(target: &str) -> String {
    target.trim().trim_end_matches(".md").to_lowercase()
}

fn graph_link_records(
    source_file_id: &str,
    parsed: &ParsedMarkdown,
    target_map: &HashMap<String, Vec<String>>,
) -> Vec<LinkEdgeRecord> {
    let mut links = Vec::new();
    for link in &parsed.wikilinks {
        links.push(LinkEdgeRecord {
            source_file_id: source_file_id.to_string(),
            target_text: link.target.clone(),
            resolved_target_file_id: resolve_benchmark_target(&link.target, target_map),
            heading: link.heading.clone(),
            alias: link.alias.clone(),
            is_embed: false,
        });
    }
    for link in &parsed.embeds {
        links.push(LinkEdgeRecord {
            source_file_id: source_file_id.to_string(),
            target_text: link.target.clone(),
            resolved_target_file_id: resolve_benchmark_target(&link.target, target_map),
            heading: link.heading.clone(),
            alias: link.alias.clone(),
            is_embed: true,
        });
    }
    for link in &parsed.markdown_links {
        if link.image || !is_markdown_graph_target(&link.target) {
            continue;
        }
        links.push(LinkEdgeRecord {
            source_file_id: source_file_id.to_string(),
            target_text: link.target.clone(),
            resolved_target_file_id: resolve_benchmark_target(&link.target, target_map),
            heading: None,
            alias: Some(link.text.clone()),
            is_embed: false,
        });
    }
    links
}

fn is_markdown_graph_target(target: &str) -> bool {
    let lower = target.to_ascii_lowercase();
    !lower.contains("://")
        && lower
            .split('#')
            .next()
            .is_some_and(|path| path.ends_with(".md"))
}

fn resolve_benchmark_target(
    target: &str,
    target_map: &HashMap<String, Vec<String>>,
) -> Option<String> {
    let candidates = target_map.get(&benchmark_link_target_key(target))?;
    (candidates.len() == 1).then(|| candidates[0].clone())
}

#[derive(Serialize)]
struct WholeVaultGraphPayloadEnvelope<'a> {
    ok: bool,
    value: WholeVaultGraphPayloadValue<'a>,
    error: Option<WholeVaultGraphPayloadError>,
}

#[derive(Serialize)]
struct WholeVaultGraphPayloadValue<'a> {
    payload_version: u32,
    request_id: u64,
    generation: u64,
    state: &'static str,
    metrics: WholeVaultGraphPayloadMetrics,
    snapshot: &'a WholeVaultGraphSnapshot,
}

#[derive(Serialize)]
struct WholeVaultGraphPayloadMetrics {
    snapshot_duration_milliseconds: f64,
    encoded_payload_bytes: usize,
}

#[derive(Serialize)]
struct WholeVaultGraphPayloadError {}

fn graph_payload_envelope(
    snapshot: &WholeVaultGraphSnapshot,
    snapshot_duration_milliseconds: f64,
    encoded_payload_bytes: usize,
) -> WholeVaultGraphPayloadEnvelope<'_> {
    WholeVaultGraphPayloadEnvelope {
        ok: true,
        value: WholeVaultGraphPayloadValue {
            payload_version: 1,
            request_id: snapshot.request_id,
            generation: snapshot.generation,
            state: if snapshot.partial_reasons.is_empty() {
                "complete"
            } else {
                "partial"
            },
            metrics: WholeVaultGraphPayloadMetrics {
                snapshot_duration_milliseconds,
                encoded_payload_bytes,
            },
            snapshot,
        },
        error: None,
    }
}

fn graph_payload_bytes(
    snapshot: &WholeVaultGraphSnapshot,
    snapshot_duration_milliseconds: f64,
) -> BackendBenchmarkResultType<usize> {
    let mut encoded_payload_bytes = 0;
    for _ in 0..4 {
        let next = count_json_bytes(&graph_payload_envelope(
            snapshot,
            snapshot_duration_milliseconds,
            encoded_payload_bytes,
        ))?;
        if next == encoded_payload_bytes {
            return Ok(next);
        }
        encoded_payload_bytes = next;
    }
    Ok(encoded_payload_bytes)
}

fn count_json_bytes<T: Serialize>(value: &T) -> BackendBenchmarkResultType<usize> {
    let mut writer = CountingWriter::default();
    serde_json::to_writer(&mut writer, value)?;
    Ok(writer.bytes)
}

#[derive(Default)]
struct CountingWriter {
    bytes: usize,
}

impl Write for CountingWriter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.bytes = self.bytes.saturating_add(buffer.len());
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn graph_indexed_access_summary(
    plans: &[crate::adapters::sqlite::GraphQueryPlanSummary],
    request: WholeVaultGraphRequest,
    snapshot_duration: Duration,
    node_count_duration: Duration,
    edge_count_duration: Duration,
) -> Vec<WholeVaultGraphIndexedAccess> {
    vec![
        indexed_access("files", plans, GraphQueryStage::Files, Duration::ZERO),
        indexed_access_any(
            "resolvedEdges",
            plans,
            &[
                GraphQueryStage::ResolvedEdgesCompact,
                GraphQueryStage::ResolvedEdges,
            ],
            Duration::ZERO,
            "unknown",
        ),
        if request.include_unresolved {
            indexed_access(
                "unresolvedEdges",
                plans,
                GraphQueryStage::UnresolvedEdges,
                Duration::ZERO,
            )
        } else {
            skipped_indexed_access("unresolvedEdges")
        },
        if request.include_orphans {
            indexed_access_any(
                "orphans",
                plans,
                &[
                    GraphQueryStage::OrphansResolvedOnly,
                    GraphQueryStage::OrphansWithUnresolved,
                ],
                Duration::ZERO,
                "intentionalFullPass",
            )
        } else {
            skipped_indexed_access("orphans")
        },
        if request.group_rule_count > 0 {
            indexed_access("tags", plans, GraphQueryStage::Tags, Duration::ZERO)
        } else {
            skipped_indexed_access("tags")
        },
        WholeVaultGraphIndexedAccess {
            stage: "productionSnapshot".to_string(),
            uses_index: false,
            scan_kind: "productionUseCase".to_string(),
            duration_milliseconds: duration_millis(snapshot_duration),
        },
        WholeVaultGraphIndexedAccess {
            stage: "nodeCount".to_string(),
            uses_index: true,
            scan_kind: "diagnosticCount".to_string(),
            duration_milliseconds: duration_millis(node_count_duration),
        },
        WholeVaultGraphIndexedAccess {
            stage: "edgeCount".to_string(),
            uses_index: true,
            scan_kind: "diagnosticCount".to_string(),
            duration_milliseconds: duration_millis(edge_count_duration),
        },
    ]
}

fn indexed_access(
    stage: &str,
    plans: &[crate::adapters::sqlite::GraphQueryPlanSummary],
    query_stage: GraphQueryStage,
    duration: Duration,
) -> WholeVaultGraphIndexedAccess {
    indexed_access_any(stage, plans, &[query_stage], duration, "unknown")
}

fn indexed_access_any(
    stage: &str,
    plans: &[crate::adapters::sqlite::GraphQueryPlanSummary],
    query_stages: &[GraphQueryStage],
    duration: Duration,
    fallback_scan_kind: &str,
) -> WholeVaultGraphIndexedAccess {
    let stage_plans = plans
        .iter()
        .filter(|plan| query_stages.contains(&plan.stage))
        .collect::<Vec<_>>();
    let uses_index = stage_plans.iter().any(|plan| plan.detail.contains("INDEX"));
    WholeVaultGraphIndexedAccess {
        stage: stage.to_string(),
        uses_index,
        scan_kind: if uses_index {
            "indexed".to_string()
        } else {
            fallback_scan_kind.to_string()
        },
        duration_milliseconds: duration_millis(duration),
    }
}

fn skipped_indexed_access(stage: &str) -> WholeVaultGraphIndexedAccess {
    WholeVaultGraphIndexedAccess {
        stage: stage.to_string(),
        uses_index: false,
        scan_kind: "skipped".to_string(),
        duration_milliseconds: 0.0,
    }
}

fn measurement(
    name: &str,
    unit: &str,
    value: Option<f64>,
    target: Option<f64>,
) -> WholeVaultGraphMeasurement {
    WholeVaultGraphMeasurement {
        name: name.to_string(),
        unit: unit.to_string(),
        status: value
            .zip(target)
            .map(|(value, target)| if value <= target { "passed" } else { "failed" })
            .unwrap_or("passed")
            .to_string(),
        value,
        target,
        blocker_code: None,
    }
}

fn blocked_measurement(name: &str, unit: &str, blocker_code: &str) -> WholeVaultGraphMeasurement {
    WholeVaultGraphMeasurement {
        name: name.to_string(),
        unit: unit.to_string(),
        status: "notMeasured".to_string(),
        value: None,
        target: None,
        blocker_code: Some(blocker_code.to_string()),
    }
}

fn budget_result(
    name: &str,
    unit: &str,
    measured: f64,
    target: f64,
) -> WholeVaultGraphBudgetResult {
    WholeVaultGraphBudgetResult {
        name: name.to_string(),
        unit: unit.to_string(),
        status: if measured <= target {
            "passed".to_string()
        } else {
            "failed".to_string()
        },
        measured: Some(measured),
        target,
        blocker_code: None,
    }
}

fn blocked_budget_result(
    name: &str,
    unit: &str,
    target: f64,
    blocker_code: &str,
) -> WholeVaultGraphBudgetResult {
    WholeVaultGraphBudgetResult {
        name: name.to_string(),
        unit: unit.to_string(),
        status: "notMeasured".to_string(),
        measured: None,
        target,
        blocker_code: Some(blocker_code.to_string()),
    }
}

fn bridge_decision(
    encoded_payload_bytes: usize,
    swift_decode_duration_milliseconds: f64,
    swift_decode_memory_bytes: u64,
) -> WholeVaultGraphBridgeDecision {
    let json_budget = 64 * 1024 * 1024;
    let hard_cap = 128 * 1024 * 1024;
    let swift_decode_target = 1_500.0;
    let swift_memory_target = 200 * 1024 * 1024;
    let (format, decision_reason) = if encoded_payload_bytes <= json_budget
        && swift_decode_duration_milliseconds <= swift_decode_target
        && swift_decode_memory_bytes <= swift_memory_target
    {
        ("json", "withinJsonBudget")
    } else if encoded_payload_bytes <= hard_cap {
        let reason = if encoded_payload_bytes > json_budget {
            "payloadTooLarge"
        } else if swift_decode_duration_milliseconds > swift_decode_target {
            "decodeTooSlow"
        } else {
            "memoryTooHigh"
        };
        ("chunked", reason)
    } else {
        ("binary", "payloadTooLarge")
    };
    WholeVaultGraphBridgeDecision {
        format: format.to_string(),
        encoded_payload_bytes,
        decision_reason: decision_reason.to_string(),
        payload_version: 1,
        request_scoped: true,
        byte_cap_bytes: hard_cap,
        count_validation: true,
        duplicate_node_validation: true,
        enum_validation: true,
        edge_reference_validation: true,
    }
}

fn rfc3339_now() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    unix_seconds_to_rfc3339(seconds)
}

fn unix_seconds_to_rfc3339(seconds: i64) -> String {
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3_600;
    let minute = (seconds_of_day % 3_600) / 60;
    let second = seconds_of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    let year = year + if month <= 2 { 1 } else { 0 };
    (year, month, day)
}

fn scan_error_to_string(error: ScanError) -> BackendBenchmarkError {
    BackendBenchmarkError::Scan(format!("{error:?}"))
}

#[cfg(target_os = "macos")]
fn current_rss_bytes() -> Option<u64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
    // SAFETY: `usage` points to writable `rusage_info_v2` storage and the
    // kernel writes at most that struct when the call succeeds.
    let result = unsafe {
        libc::proc_pid_rusage(
            libc::getpid(),
            libc::RUSAGE_INFO_V2,
            usage.as_mut_ptr().cast(),
        )
    };
    if result != 0 {
        return None;
    }
    // SAFETY: `proc_pid_rusage` returned success, so `usage` has been
    // initialized by the kernel.
    Some(unsafe { usage.assume_init().ri_resident_size })
}

#[cfg(target_os = "linux")]
fn current_rss_bytes() -> Option<u64> {
    let statm = fs::read_to_string("/proc/self/statm").ok()?;
    let resident_pages = statm.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    // SAFETY: `sysconf(_SC_PAGESIZE)` has no pointer arguments and does not
    // retain Rust-managed memory.
    let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    if page_size <= 0 {
        return None;
    }
    Some(resident_pages.saturating_mul(page_size as u64))
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn current_rss_bytes() -> Option<u64> {
    None
}

fn release_benchmark_allocator_memory() {}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn peak_rss_bytes() -> Option<u64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::zeroed();
    // SAFETY: `usage` points to writable `rusage` storage and the kernel
    // initializes it when `getrusage` returns success.
    let result = unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) };
    if result != 0 {
        return None;
    }
    // SAFETY: `getrusage` returned success, so `usage` is initialized.
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
        assert_eq!(artifact.time_to_usable_micros, None);
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
            time_to_usable_sample_count: 1,
            snippet_storage_mode: SnippetStorageMode::StoredBody,
            include_sqlite_fts: true,
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
            time_to_usable_sample_count: 1,
            snippet_storage_mode: SnippetStorageMode::StoredBody,
            include_sqlite_fts: true,
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
        assert!(
            artifact
                .time_to_usable_micros
                .is_some_and(|value| value > 0)
        );
        let metadata_store = artifact.metadata_store.as_ref().expect("metadata store");
        assert!(metadata_store.sqlite_metadata_write_micros > 0);
        assert_eq!(metadata_store.table_counts.files, artifact.document_count);
        assert_eq!(
            metadata_store.table_counts.headings,
            artifact.document_count
        );
        assert!(json.contains("\"sqlite_metadata_write_micros\""));
        assert!(json.contains("\"table_counts\""));
        assert!(json.contains("\"time_to_usable_micros\""));
        assert!(json.contains("\"snippet_storage_mode\": \"stored_body\""));
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

        let lazy_options = VaultBackendBenchmarkOptions {
            corpus_id: "vault-lazy-source-smoke".to_string(),
            vault_root: options.vault_root.clone(),
            queries: options.queries.clone(),
            result_limit: options.result_limit,
            work_dir: temp.path().join("lazy-indexes"),
            time_to_usable_sample_count: 1,
            snippet_storage_mode: SnippetStorageMode::LazySourceExperiment,
            include_sqlite_fts: false,
        };
        let lazy_artifact =
            run_shared_backend_benchmark_from_vault(&lazy_options).expect("lazy benchmark");
        let lazy_artifact_path = temp.path().join("lazy-vault-benchmark.json");
        write_backend_benchmark_artifact(&lazy_artifact_path, &lazy_artifact, true)
            .expect("lazy artifact");
        let lazy_json = fs::read_to_string(&lazy_artifact_path).expect("lazy artifact json");

        assert_eq!(
            lazy_artifact.pipeline_config.snippet_storage_mode,
            SnippetStorageMode::LazySourceExperiment
        );
        assert_eq!(lazy_artifact.backends.len(), 1);
        assert!(lazy_artifact.backends.iter().any(|backend| {
            backend.backend == "tantivy_lazy_source_experiment"
                && backend.snippet_result_count == 0
                && backend.query_result_count > 0
        }));
        assert!(lazy_json.contains("\"snippet_storage_mode\": \"lazy_source_experiment\""));
        assert!(!lazy_json.contains("Welcome to the streaming benchmark fixture"));
        assert!(!lazy_json.contains("Guide links back to Home"));
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
