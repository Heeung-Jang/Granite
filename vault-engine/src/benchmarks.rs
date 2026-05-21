use std::collections::{HashMap, HashSet};
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::Serialize;

use crate::graph::{
    WholeVaultGraphInputs, WholeVaultGraphRequest, WholeVaultGraphSnapshot,
    build_whole_vault_graph_snapshot,
};
use crate::index::{
    FileRecord, GraphFileRecord, GraphQueryStage, IndexSchemaMetadata, LinkEdgeRecord,
    MetadataStore, MetadataStoreError, TagRecord, TagSource,
};
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

#[derive(Debug, Clone)]
pub struct VaultBackendBenchmarkOptions {
    pub corpus_id: String,
    pub vault_root: PathBuf,
    pub queries: Vec<String>,
    pub result_limit: usize,
    pub work_dir: PathBuf,
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
    Metadata(MetadataStoreError),
    Json(serde_json::Error),
}

pub type BackendBenchmarkResultType<T> = Result<T, BackendBenchmarkError>;

pub fn load_search_documents_from_vault(
    vault_root: impl AsRef<Path>,
) -> BackendBenchmarkResultType<Vec<SearchDocument>> {
    let root = VaultRoot::open(vault_root).map_err(BackendBenchmarkError::Path)?;
    let sources = load_search_document_sources(&root)?;
    let mut documents = Vec::new();

    for source in &sources {
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

pub fn run_shared_backend_benchmark_from_vault(
    options: &VaultBackendBenchmarkOptions,
) -> BackendBenchmarkResultType<BackendBenchmarkArtifact> {
    if options.queries.is_empty() {
        return Err(BackendBenchmarkError::EmptyQueries);
    }

    let root = VaultRoot::open(&options.vault_root).map_err(BackendBenchmarkError::Path)?;
    let sources = load_search_document_sources(&root)?;
    if sources.is_empty() {
        return Err(BackendBenchmarkError::EmptyDocuments);
    }

    fs::create_dir_all(&options.work_dir)?;
    let sqlite = run_sqlite_benchmark_from_sources(options, &sources)?;
    let tantivy = run_tantivy_benchmark_from_sources(options, &sources)?;

    Ok(BackendBenchmarkArtifact {
        schema_version: 1,
        generated_at_unix_seconds: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        corpus_id: options.corpus_id.clone(),
        document_count: sources.len(),
        query_count: options.queries.len(),
        total_document_bytes: sqlite.total_document_bytes,
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

pub fn run_whole_vault_graph_snapshot_benchmark(
    options: &WholeVaultGraphBenchmarkOptions,
) -> BackendBenchmarkResultType<WholeVaultGraphBenchmarkArtifact> {
    let root = VaultRoot::open(&options.vault_root).map_err(BackendBenchmarkError::Path)?;
    let scan = scan_vault(&root).map_err(scan_error_to_string)?;
    let markdown_entries = scan
        .entries
        .into_iter()
        .filter(|entry| entry.kind == ScanEntryKind::Markdown)
        .collect::<Vec<_>>();
    if markdown_entries.is_empty() {
        return Err(BackendBenchmarkError::EmptyDocuments);
    }

    let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v2", "tantivy", 1);
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

    let request = WholeVaultGraphRequest::with_request_id(1, options.max_nodes, options.max_edges)
        .including_unresolved(options.include_unresolved)
        .including_orphans(options.include_orphans);
    let rss_before = current_rss_bytes();
    let snapshot_start = Instant::now();
    let node_fetch_limit = request.node_limit().saturating_add(1);
    let edge_fetch_limit = request.edge_limit().saturating_add(1);
    let (_, files_duration) = timed(|| Ok(store.graph_files(1, node_fetch_limit)?))?;
    let (resolved_edges, resolved_duration) =
        timed(|| Ok(store.graph_resolved_edges(1, edge_fetch_limit)?))?;
    let (unresolved_edges, unresolved_duration) = if request.include_unresolved {
        timed(|| Ok(store.graph_unresolved_edges(1, edge_fetch_limit)?))?
    } else {
        (Vec::new(), Duration::ZERO)
    };
    let (orphan_files, orphan_duration) = if request.include_orphans {
        timed(|| Ok(store.graph_orphan_files(1, request.include_unresolved, node_fetch_limit)?))?
    } else {
        (Vec::new(), Duration::ZERO)
    };
    let files = benchmark_graph_candidate_files(
        &resolved_edges,
        &unresolved_edges,
        &orphan_files,
        node_fetch_limit,
    );
    let file_ids = files
        .iter()
        .map(|file| file.file_id.clone())
        .collect::<Vec<_>>();
    let (tags, tags_duration) =
        timed(
            || Ok(store.graph_tags_for_files(&file_ids, request.tag_limit().saturating_add(1))?),
        )?;
    let node_count_total =
        store.graph_visible_node_count(1, request.include_unresolved, request.include_orphans)?;
    let edge_count_total = store.graph_visible_edge_count(1, request.include_unresolved)?;
    let assembly_start = Instant::now();
    let build = build_whole_vault_graph_snapshot(
        request,
        1,
        WholeVaultGraphInputs {
            node_count_total,
            edge_count_total,
            files,
            resolved_edges,
            unresolved_edges,
            orphan_files,
            tags,
        },
    );
    let encoded_payload_bytes = graph_payload_bytes(&build.snapshot)?;
    let assembly_duration = assembly_start.elapsed();
    let snapshot_duration = snapshot_start.elapsed();
    let rss_after = current_rss_bytes();
    let rss_delta = rss_before
        .zip(rss_after)
        .map(|(before, after)| after.saturating_sub(before));

    let plans = store.graph_query_plan_summaries(1)?;
    let indexed_access_summary = vec![
        indexed_access("files", &plans, GraphQueryStage::Files, files_duration),
        indexed_access(
            "resolvedEdges",
            &plans,
            GraphQueryStage::ResolvedEdges,
            resolved_duration,
        ),
        indexed_access(
            "unresolvedEdges",
            &plans,
            GraphQueryStage::UnresolvedEdges,
            unresolved_duration,
        ),
        indexed_access_for_orphans(&plans, orphan_duration),
        indexed_access("tags", &plans, GraphQueryStage::Tags, tags_duration),
        WholeVaultGraphIndexedAccess {
            stage: "assembly".to_string(),
            uses_index: false,
            scan_kind: "unknown".to_string(),
            duration_milliseconds: duration_millis(assembly_duration),
        },
    ];
    let snapshot_ms = duration_millis(snapshot_duration);
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
        backend_version: "metadata-v2".to_string(),
        store_schema_version: crate::index::INDEX_SCHEMA_VERSION,
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
            Self::Metadata(error) => write!(formatter, "backend benchmark metadata error: {error}"),
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

impl From<MetadataStoreError> for BackendBenchmarkError {
    fn from(error: MetadataStoreError) -> Self {
        Self::Metadata(error)
    }
}

impl From<serde_json::Error> for BackendBenchmarkError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

#[derive(Debug, Clone)]
struct SearchDocumentSource {
    relative_path: PathBuf,
    absolute_path: PathBuf,
    file_id: String,
}

struct StreamingBenchmarkResult {
    result: BackendBenchmarkResult,
    total_document_bytes: u64,
}

#[derive(Default)]
struct StreamingCorpusStats {
    document_count: usize,
    total_document_bytes: u64,
    first_document: Option<SearchDocument>,
}

impl StreamingCorpusStats {
    fn record(&mut self, document: &SearchDocument) {
        self.document_count += 1;
        self.total_document_bytes += document_bytes(document);
        if self.first_document.is_none() {
            self.first_document = Some(document.clone());
        }
    }

    fn first_document(&self) -> BackendBenchmarkResultType<&SearchDocument> {
        self.first_document
            .as_ref()
            .ok_or(BackendBenchmarkError::EmptyDocuments)
    }
}

fn load_search_document_sources(
    root: &VaultRoot,
) -> BackendBenchmarkResultType<Vec<SearchDocumentSource>> {
    let scan = scan_vault(root).map_err(scan_error_to_string)?;
    Ok(scan
        .entries
        .into_iter()
        .filter(|entry| entry.kind == ScanEntryKind::Markdown)
        .map(|entry| {
            let absolute_path = root.canonical_root().join(&entry.relative_path);
            SearchDocumentSource {
                file_id: lookup_key(&entry.relative_path),
                relative_path: entry.relative_path,
                absolute_path,
            }
        })
        .collect())
}

fn graph_target_map(entries: &[crate::scanner::ScanEntry]) -> HashMap<String, Vec<String>> {
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
    parsed: &crate::parser::ParsedMarkdown,
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

fn benchmark_graph_candidate_files(
    resolved_edges: &[crate::index::GraphResolvedEdgeRecord],
    unresolved_edges: &[crate::index::GraphUnresolvedEdgeRecord],
    orphan_files: &[GraphFileRecord],
    limit: usize,
) -> Vec<GraphFileRecord> {
    let mut files = Vec::new();
    let mut seen = HashSet::new();
    for edge in resolved_edges {
        push_graph_file(
            &mut files,
            &mut seen,
            &edge.source_file_id,
            &edge.source_relative_path,
            limit,
        );
        push_graph_file(
            &mut files,
            &mut seen,
            &edge.target_file_id,
            &edge.target_relative_path,
            limit,
        );
    }
    for edge in unresolved_edges {
        push_graph_file(
            &mut files,
            &mut seen,
            &edge.source_file_id,
            &edge.source_relative_path,
            limit,
        );
    }
    for file in orphan_files {
        push_graph_file(
            &mut files,
            &mut seen,
            &file.file_id,
            &file.relative_path,
            limit,
        );
    }
    files
}

fn push_graph_file(
    files: &mut Vec<GraphFileRecord>,
    seen: &mut HashSet<String>,
    file_id: &str,
    relative_path: &Path,
    limit: usize,
) {
    if files.len() >= limit || !seen.insert(file_id.to_string()) {
        return;
    }
    files.push(GraphFileRecord {
        file_id: file_id.to_string(),
        relative_path: relative_path.to_path_buf(),
    });
}

fn read_search_document(
    source: &SearchDocumentSource,
) -> BackendBenchmarkResultType<SearchDocument> {
    let body = fs::read_to_string(&source.absolute_path)?;
    let parsed = parse_markdown(&body);
    let title = parsed
        .headings
        .first()
        .map(|heading| heading.text.clone())
        .unwrap_or_else(|| fallback_title(&source.relative_path));
    Ok(SearchDocument {
        file_id: source.file_id.clone(),
        path: source.relative_path.to_string_lossy().to_string(),
        title,
        body,
    })
}

fn run_sqlite_benchmark(
    options: &BackendBenchmarkOptions,
    total_document_bytes: u64,
) -> BackendBenchmarkResultType<BackendBenchmarkResult> {
    let db_path = options.work_dir.join("sqlite-fts.sqlite");
    remove_sqlite_files(&db_path)?;
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

fn run_sqlite_benchmark_from_sources(
    options: &VaultBackendBenchmarkOptions,
    sources: &[SearchDocumentSource],
) -> BackendBenchmarkResultType<StreamingBenchmarkResult> {
    let db_path = options.work_dir.join("sqlite-fts.sqlite");
    remove_sqlite_files(&db_path)?;
    let mut index = SqliteFtsIndex::open(&db_path)?;
    let mut stats = StreamingCorpusStats::default();

    let index_start = Instant::now();
    for source in sources {
        let document = read_search_document(source)?;
        stats.record(&document);
        index.upsert_document(&document)?;
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
    let incremental_update_micros =
        measure_sqlite_incremental_update_doc(&mut index, stats.first_document()?)?;

    Ok(StreamingBenchmarkResult {
        result: backend_result(
            "sqlite_fts",
            index_duration,
            stats.document_count,
            stats.total_document_bytes,
            query_stats,
            incremental_update_micros,
            index.estimated_size_bytes()?,
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

fn run_tantivy_benchmark_from_sources(
    options: &VaultBackendBenchmarkOptions,
    sources: &[SearchDocumentSource],
) -> BackendBenchmarkResultType<StreamingBenchmarkResult> {
    let index_dir = options.work_dir.join("tantivy");
    reset_directory(&index_dir)?;
    let mut index = TantivySearchIndex::open_in_dir(&index_dir)?;
    let mut stats = StreamingCorpusStats::default();

    let index_start = Instant::now();
    index.replace_documents_from_result_iter(sources.iter().map(|source| {
        let document = read_search_document(source)?;
        stats.record(&document);
        Ok::<SearchDocument, BackendBenchmarkError>(document)
    }))?;
    let index_duration = index_start.elapsed();
    let query_stats = measure_queries(&options.queries, |query| {
        index
            .search(query, options.result_limit)
            .map_err(Into::into)
    })?;
    let incremental_update_micros =
        measure_tantivy_incremental_update_doc(&mut index, stats.first_document()?)?;

    Ok(StreamingBenchmarkResult {
        result: backend_result(
            "tantivy",
            index_duration,
            stats.document_count,
            stats.total_document_bytes,
            query_stats,
            incremental_update_micros,
            index.estimated_size_bytes()?,
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
    }
}

fn is_empty_query_error(error: &BackendBenchmarkError) -> bool {
    matches!(
        error,
        BackendBenchmarkError::Sqlite(SqliteFtsError::EmptyQuery)
            | BackendBenchmarkError::Tantivy(TantivySearchError::EmptyQuery)
    )
}

fn fallback_title(relative_path: &Path) -> String {
    relative_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Untitled")
        .to_string()
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

fn timed<T, F>(operation: F) -> BackendBenchmarkResultType<(T, Duration)>
where
    F: FnOnce() -> BackendBenchmarkResultType<T>,
{
    let start = Instant::now();
    let value = operation()?;
    Ok((value, start.elapsed()))
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WholeVaultGraphPayloadEnvelope<'a> {
    payload_version: u32,
    snapshot: &'a WholeVaultGraphSnapshot,
}

fn graph_payload_bytes(snapshot: &WholeVaultGraphSnapshot) -> BackendBenchmarkResultType<usize> {
    let payload = WholeVaultGraphPayloadEnvelope {
        payload_version: 1,
        snapshot,
    };
    Ok(serde_json::to_vec(&payload)?.len())
}

fn indexed_access(
    stage: &str,
    plans: &[crate::index::GraphQueryPlanSummary],
    query_stage: GraphQueryStage,
    duration: Duration,
) -> WholeVaultGraphIndexedAccess {
    let stage_plans = plans
        .iter()
        .filter(|plan| plan.stage == query_stage)
        .collect::<Vec<_>>();
    let uses_index = stage_plans.iter().any(|plan| plan.detail.contains("INDEX"));
    WholeVaultGraphIndexedAccess {
        stage: stage.to_string(),
        uses_index,
        scan_kind: if uses_index {
            "indexed".to_string()
        } else {
            "unknown".to_string()
        },
        duration_milliseconds: duration_millis(duration),
    }
}

fn indexed_access_for_orphans(
    plans: &[crate::index::GraphQueryPlanSummary],
    duration: Duration,
) -> WholeVaultGraphIndexedAccess {
    let uses_index = plans.iter().any(|plan| {
        matches!(
            plan.stage,
            GraphQueryStage::OrphansResolvedOnly | GraphQueryStage::OrphansWithUnresolved
        ) && plan.detail.contains("INDEX")
    });
    WholeVaultGraphIndexedAccess {
        stage: "orphans".to_string(),
        uses_index,
        scan_kind: if uses_index {
            "indexed".to_string()
        } else {
            "intentionalFullPass".to_string()
        },
        duration_milliseconds: duration_millis(duration),
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

#[cfg(target_os = "macos")]
fn current_rss_bytes() -> Option<u64> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage_info_v2>::zeroed();
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
    Some(unsafe { usage.assume_init().ri_resident_size })
}

#[cfg(target_os = "linux")]
fn current_rss_bytes() -> Option<u64> {
    let statm = fs::read_to_string("/proc/self/statm").ok()?;
    let resident_pages = statm.split_whitespace().nth(1)?.parse::<u64>().ok()?;
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

        assert_eq!(artifact.schema_version, 1);
        assert_eq!(artifact.document_count, options.documents.len());
        assert_eq!(artifact.query_count, options.queries.len());
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

        assert_eq!(artifact.document_count, 2);
        assert_eq!(artifact.query_count, 2);
        assert_eq!(artifact.backends.len(), 2);
        assert!(artifact.total_document_bytes > 0);
        assert!(artifact.backends.iter().all(|backend| {
            backend.index_size_bytes > 0 && backend.query_p95_micros <= backend.query_p99_micros
        }));
    }

    #[test]
    fn runs_whole_vault_graph_snapshot_benchmark_without_private_artifact_data() {
        let temp = tempfile::tempdir().expect("tempdir");
        let vault = temp.path().join("vault");
        fs::create_dir_all(vault.join("Folder")).expect("vault dirs");
        fs::write(
            vault.join("Home.md"),
            "# SecretProject\n[[Folder/Target]] [[ÄMissing]] [[ämissing]] #client@example.com",
        )
        .expect("home");
        fs::write(vault.join("Folder").join("Target.md"), "# Target").expect("target");
        fs::write(vault.join("Orphan.md"), "# Orphan").expect("orphan");

        let artifact = run_whole_vault_graph_snapshot_benchmark(&WholeVaultGraphBenchmarkOptions {
            vault_alias: "small-fixture".to_string(),
            code_revision: "abcdef0".to_string(),
            vault_root: vault,
            max_nodes: 100,
            max_edges: 100,
            include_unresolved: true,
            include_orphans: true,
            swift_decode_duration_milliseconds: 42.0,
            swift_decode_memory_bytes: 8 * 1024 * 1024,
        })
        .expect("graph benchmark");

        assert_eq!(artifact.counts.visible_node_count, 4);
        assert_eq!(artifact.counts.visible_edge_count, 2);
        assert!(
            artifact
                .measurements
                .iter()
                .any(|measurement| measurement.name == "encodedPayloadBytes")
        );
        assert!(
            artifact
                .measurements
                .iter()
                .any(|measurement| measurement.name == "decodeDuration")
        );
        assert!(
            artifact
                .measurements
                .iter()
                .any(|measurement| measurement.name == "swiftDecodeMemory")
        );
        assert_eq!(artifact.bridge_decision.format, "json");
        assert_eq!(
            artifact.bridge_decision.decision_reason,
            "withinJsonBudget"
        );
        assert!(
            artifact
                .indexed_access_summary
                .iter()
                .any(|access| access.stage == "resolvedEdges" && access.uses_index)
        );
        let json = serde_json::to_string(&artifact).expect("artifact json");
        assert!(!json.contains("SecretProject"));
        assert!(!json.contains("client@example.com"));
        assert!(!json.contains("Folder/Target"));
        assert!(!json.contains("ÄMissing"));
        assert!(json.contains("encodedPayloadBytes"));
    }

    #[test]
    fn graph_bridge_decision_requires_swift_decode_and_memory_budgets() {
        let within_budget = bridge_decision(1_024, 42.0, 8 * 1024 * 1024);
        assert_eq!(within_budget.format, "json");
        assert_eq!(within_budget.decision_reason, "withinJsonBudget");

        let slow_decode = bridge_decision(1_024, 1_501.0, 8 * 1024 * 1024);
        assert_eq!(slow_decode.format, "chunked");
        assert_eq!(slow_decode.decision_reason, "decodeTooSlow");

        let high_memory = bridge_decision(1_024, 42.0, 201 * 1024 * 1024);
        assert_eq!(high_memory.format, "chunked");
        assert_eq!(high_memory.decision_reason, "memoryTooHigh");
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
}
