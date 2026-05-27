use crate::{
    VaultIdentity, public_artifact_salt, redacted_private_value, redacted_vault_identity,
    salted_private_hash,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::error::Error;
use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;
use vault_engine::read_api::{
    LocalGraphDepth, LocalGraphRequest, PageRequest, ReadApiError, ReadState, open_vault_read_api,
};

#[derive(Debug, Clone)]
pub struct ReadApiBenchmarkOptions {
    pub vault_root: PathBuf,
    pub metadata_path: PathBuf,
    pub tantivy_path: PathBuf,
    pub queries: Vec<String>,
    pub query_file: Option<PathBuf>,
    pub runbook_path: Option<PathBuf>,
    pub sampled_paths: Vec<String>,
    pub sampled_paths_file: Option<PathBuf>,
    pub result_limit: usize,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct ReadApiBenchmarkArtifact {
    pub schema_version: u32,
    pub tool: String,
    pub vault: VaultIdentity,
    pub metadata_path_hash: String,
    pub tantivy_path_hash: String,
    pub result_limit: usize,
    pub summaries: Vec<ReadApiSurfaceSummary>,
    pub samples: Vec<ReadApiBenchmarkSample>,
    pub privacy: ReadApiBenchmarkPrivacy,
    pub notes: Vec<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
pub struct ReadApiBenchmarkPrivacy {
    pub raw_queries_committed: bool,
    pub raw_note_bodies_committed: bool,
    pub absolute_paths_committed: bool,
    pub input_material: String,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct ReadApiSurfaceSummary {
    pub surface: String,
    pub sample_count: usize,
    pub measured_sample_count: usize,
    pub error_sample_count: usize,
    pub state_counts: BTreeMap<String, usize>,
    pub p50_ms: Option<f64>,
    pub p95_ms: Option<f64>,
    pub p99_ms: Option<f64>,
}

#[derive(Debug, Serialize, PartialEq)]
pub struct ReadApiBenchmarkSample {
    pub sample_id: String,
    pub surface: String,
    pub input_hash: String,
    pub duration_ms: Option<f64>,
    pub result_count: Option<usize>,
    pub state: String,
    pub notes: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct PrivateRunbookEntry {
    raw_query: String,
}

pub fn run_read_api_benchmark(
    options: &ReadApiBenchmarkOptions,
) -> Result<ReadApiBenchmarkArtifact, Box<dyn Error>> {
    let api = open_vault_read_api(&options.metadata_path, &options.tantivy_path)?;
    let result_limit = options.result_limit.max(1);
    let input_redactor = InputRedactor::new();
    let mut samples = Vec::new();

    let file_tree_start = Instant::now();
    match api.file_tree_projection(PageRequest::with_request_id(1, 0, result_limit)) {
        Ok(page) => {
            let duration_ms = elapsed_ms(file_tree_start);
            samples.push(sample(
                "file_tree",
                "first_page",
                Some(duration_ms),
                Some(page.items.len()),
                state_name(page.state),
                Vec::new(),
            ));
        }
        Err(error) => samples.push(error_sample(
            "file_tree",
            "first_page",
            read_api_error_note(&error),
        )),
    }

    let sampled_paths = sampled_paths(options, &api, result_limit)?;
    let queries = benchmark_queries(options, &api, result_limit)?;

    for query in queries {
        measure_search_surface(
            &api,
            &mut samples,
            &input_redactor,
            "file_name_search",
            &query,
            result_limit,
            |query, page| api.file_name_search(query, page),
        );
        measure_search_surface(
            &api,
            &mut samples,
            &input_redactor,
            "body_search",
            &query,
            result_limit,
            |query, page| api.body_search(query, page),
        );
    }

    for relative_path in sampled_paths {
        let path_hash = input_redactor.hash(relative_path.as_bytes());

        let start = Instant::now();
        match api.backlinks_for_path(
            &relative_path,
            PageRequest::with_request_id(1, 0, result_limit),
        ) {
            Ok(page) => samples.push(sample_with_hash(
                "backlinks",
                path_hash.clone(),
                Some(elapsed_ms(start)),
                Some(page.items.len()),
                state_name(page.state),
                Vec::new(),
            )),
            Err(error) => samples.push(error_sample_with_hash(
                "backlinks",
                path_hash.clone(),
                read_api_error_note(&error),
            )),
        }

        let start = Instant::now();
        match api.properties_for_path(
            &relative_path,
            PageRequest::with_request_id(1, 0, result_limit),
        ) {
            Ok(page) => samples.push(sample_with_hash(
                "properties",
                path_hash.clone(),
                Some(elapsed_ms(start)),
                Some(page.items.len()),
                state_name(page.state),
                Vec::new(),
            )),
            Err(error) => samples.push(error_sample_with_hash(
                "properties",
                path_hash.clone(),
                read_api_error_note(&error),
            )),
        }

        let start = Instant::now();
        match api.local_graph_for_path(
            &relative_path,
            LocalGraphRequest::with_depth(1, 80, 160, LocalGraphDepth::OneHop),
        ) {
            Ok(graph) => samples.push(sample_with_hash(
                "local_graph",
                path_hash,
                Some(elapsed_ms(start)),
                Some(graph.value.nodes.len() + graph.value.edges.len()),
                state_name(graph.state),
                Vec::new(),
            )),
            Err(error) => samples.push(error_sample_with_hash(
                "local_graph",
                path_hash,
                read_api_error_note(&error),
            )),
        }
    }

    Ok(artifact_from_samples(options, samples))
}

pub fn artifact_from_samples(
    options: &ReadApiBenchmarkOptions,
    samples: Vec<ReadApiBenchmarkSample>,
) -> ReadApiBenchmarkArtifact {
    ReadApiBenchmarkArtifact {
        schema_version: 1,
        tool: "vault-profiler read-api-benchmark".to_string(),
        vault: redacted_vault_identity(),
        metadata_path_hash: redacted_private_value(),
        tantivy_path_hash: redacted_private_value(),
        result_limit: options.result_limit.max(1),
        summaries: summaries_from_samples(&samples),
        samples,
        privacy: ReadApiBenchmarkPrivacy {
            raw_queries_committed: false,
            raw_note_bodies_committed: false,
            absolute_paths_committed: false,
            input_material:
                "Inputs are represented by per-artifact salted hashes only; raw query text and relative paths are not written."
                    .to_string(),
        },
        notes: vec![
            "Search queries may be read from private query files or sampled from indexed file names, but only salted redacted IDs are persisted.".to_string(),
            "Read API timings use the existing SQLite metadata and Tantivy search artifacts without scanning note bodies.".to_string(),
        ],
    }
}

pub fn summaries_from_samples(samples: &[ReadApiBenchmarkSample]) -> Vec<ReadApiSurfaceSummary> {
    let mut grouped: BTreeMap<&str, Vec<&ReadApiBenchmarkSample>> = BTreeMap::new();
    for sample in samples {
        grouped
            .entry(sample.surface.as_str())
            .or_default()
            .push(sample);
    }

    grouped
        .into_iter()
        .map(|(surface, samples)| {
            let mut durations = samples
                .iter()
                .filter_map(|sample| sample.duration_ms)
                .collect::<Vec<_>>();
            durations.sort_by(f64::total_cmp);
            let mut state_counts = BTreeMap::new();
            for sample in &samples {
                *state_counts.entry(sample.state.clone()).or_default() += 1;
            }
            ReadApiSurfaceSummary {
                surface: surface.to_string(),
                sample_count: samples.len(),
                measured_sample_count: durations.len(),
                error_sample_count: samples
                    .iter()
                    .filter(|sample| sample.state == "error")
                    .count(),
                state_counts,
                p50_ms: percentile(&durations, 50),
                p95_ms: percentile(&durations, 95),
                p99_ms: percentile(&durations, 99),
            }
        })
        .collect()
}

fn sampled_paths(
    options: &ReadApiBenchmarkOptions,
    api: &vault_engine::read_api::VaultReadApi,
    result_limit: usize,
) -> Result<Vec<String>, Box<dyn Error>> {
    let mut paths = options.sampled_paths.clone();
    if let Some(path_file) = &options.sampled_paths_file {
        paths.extend(read_lines(path_file)?);
    }
    if paths.is_empty() {
        let page = api.file_tree_projection(PageRequest::with_request_id(2, 0, result_limit))?;
        paths.extend(
            page.items
                .into_iter()
                .map(|item| item.file.relative_path.to_string_lossy().to_string()),
        );
    }
    paths.sort();
    paths.dedup();
    paths.truncate(result_limit);
    Ok(paths)
}

fn benchmark_queries(
    options: &ReadApiBenchmarkOptions,
    api: &vault_engine::read_api::VaultReadApi,
    result_limit: usize,
) -> Result<Vec<String>, Box<dyn Error>> {
    let mut queries = options.queries.clone();
    if let Some(query_file) = &options.query_file {
        queries.extend(read_lines(query_file)?);
    }
    if let Some(runbook_path) = &options.runbook_path {
        let runbook: Vec<PrivateRunbookEntry> =
            serde_json::from_str(&fs::read_to_string(runbook_path)?)?;
        queries.extend(runbook.into_iter().map(|entry| entry.raw_query));
    }
    if queries.is_empty() {
        let page = api.file_tree_projection(PageRequest::with_request_id(3, 0, result_limit))?;
        queries.extend(page.items.into_iter().filter_map(|item| {
            item.file
                .relative_path
                .file_stem()
                .and_then(OsStr::to_str)
                .map(str::to_string)
        }));
    }
    if queries.is_empty() {
        queries.push("__codex_zero_result_read_api_probe__".to_string());
    }
    queries.sort();
    queries.dedup();
    queries.truncate(result_limit);
    Ok(queries)
}

fn read_lines(path: &Path) -> Result<Vec<String>, Box<dyn Error>> {
    Ok(fs::read_to_string(path)?
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect())
}

fn measure_search_surface<F>(
    _api: &vault_engine::read_api::VaultReadApi,
    samples: &mut Vec<ReadApiBenchmarkSample>,
    input_redactor: &InputRedactor,
    surface: &str,
    query: &str,
    result_limit: usize,
    mut read: F,
) where
    F: FnMut(
        &str,
        PageRequest,
    ) -> vault_engine::read_api::ReadApiResult<
        vault_engine::read_api::ReadPage<vault_engine::read_api::SearchHit>,
    >,
{
    let query_hash = input_redactor.hash(query.as_bytes());
    let start = Instant::now();
    match read(query, PageRequest::with_request_id(1, 0, result_limit)) {
        Ok(page) => samples.push(sample_with_hash(
            surface,
            query_hash,
            Some(elapsed_ms(start)),
            Some(page.items.len()),
            state_name(page.state),
            Vec::new(),
        )),
        Err(error) => samples.push(error_sample_with_hash(
            surface,
            query_hash,
            read_api_error_note(&error),
        )),
    }
}

fn sample(
    surface: &str,
    input_label: &str,
    duration_ms: Option<f64>,
    result_count: Option<usize>,
    state: &str,
    notes: Vec<String>,
) -> ReadApiBenchmarkSample {
    sample_with_hash(
        surface,
        salted_private_hash(&public_artifact_salt(), input_label.as_bytes()),
        duration_ms,
        result_count,
        state,
        notes,
    )
}

fn sample_with_hash(
    surface: &str,
    input_hash: String,
    duration_ms: Option<f64>,
    result_count: Option<usize>,
    state: &str,
    notes: Vec<String>,
) -> ReadApiBenchmarkSample {
    ReadApiBenchmarkSample {
        sample_id: format!("{surface}-{input_hash}", input_hash = &input_hash[..12]),
        surface: surface.to_string(),
        input_hash,
        duration_ms: duration_ms.map(|value| rounded_ms(value)),
        result_count,
        state: state.to_string(),
        notes,
    }
}

fn error_sample(surface: &str, input_label: &str, note: String) -> ReadApiBenchmarkSample {
    error_sample_with_hash(
        surface,
        salted_private_hash(&public_artifact_salt(), input_label.as_bytes()),
        note,
    )
}

fn error_sample_with_hash(
    surface: &str,
    input_hash: String,
    note: String,
) -> ReadApiBenchmarkSample {
    sample_with_hash(
        surface,
        input_hash,
        None,
        None,
        "error",
        vec![safe_error_note(&note)],
    )
}

#[derive(Debug, Clone)]
struct InputRedactor {
    salt: String,
}

impl InputRedactor {
    fn new() -> Self {
        Self {
            salt: public_artifact_salt(),
        }
    }

    fn hash(&self, bytes: &[u8]) -> String {
        salted_private_hash(&self.salt, bytes)
    }
}

fn read_api_error_note(error: &ReadApiError) -> String {
    let class = match error {
        ReadApiError::Metadata(_) => "metadata",
        ReadApiError::Search(_) => "search",
        ReadApiError::InvalidInput(_) => "invalid_input",
        ReadApiError::NotFound(_) => "not_found",
    };
    format!("error_class={class}")
}

fn safe_error_note(note: &str) -> String {
    if note.starts_with("error_class=") {
        note.to_string()
    } else {
        "error_class=redacted".to_string()
    }
}

fn state_name(state: ReadState) -> &'static str {
    match state {
        ReadState::Complete => "complete",
        ReadState::Partial => "partial",
        ReadState::Stale => "stale",
        ReadState::Cancelled => "cancelled",
        ReadState::Error => "error",
    }
}

fn elapsed_ms(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1_000.0
}

fn rounded_ms(value: f64) -> f64 {
    (value * 1_000.0).round() / 1_000.0
}

fn percentile(values: &[f64], percentile: usize) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let index = ((values.len() * percentile).div_ceil(100)).saturating_sub(1);
    Some(values[index.min(values.len() - 1)])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options() -> ReadApiBenchmarkOptions {
        ReadApiBenchmarkOptions {
            vault_root: PathBuf::from("/Users/example/Private Vault"),
            metadata_path: PathBuf::from("/Users/example/private/index/metadata.sqlite"),
            tantivy_path: PathBuf::from("/Users/example/private/index/tantivy"),
            queries: Vec::new(),
            query_file: None,
            runbook_path: None,
            sampled_paths: Vec::new(),
            sampled_paths_file: None,
            result_limit: 10,
        }
    }

    #[test]
    fn synthetic_summary_emits_percentiles_and_state_counts() {
        let samples = vec![
            sample("backlinks", "a", Some(1.0), Some(1), "complete", Vec::new()),
            sample("backlinks", "b", Some(2.0), Some(2), "partial", Vec::new()),
            sample("backlinks", "c", Some(3.0), Some(3), "complete", Vec::new()),
        ];

        let summaries = summaries_from_samples(&samples);

        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0].surface, "backlinks");
        assert_eq!(summaries[0].sample_count, 3);
        assert_eq!(summaries[0].p50_ms, Some(2.0));
        assert_eq!(summaries[0].p95_ms, Some(3.0));
        assert_eq!(summaries[0].p99_ms, Some(3.0));
        assert_eq!(summaries[0].state_counts.get("complete"), Some(&2));
        assert_eq!(summaries[0].state_counts.get("partial"), Some(&1));
    }

    #[test]
    fn artifact_json_redacts_private_material() {
        let artifact = artifact_from_samples(
            &options(),
            vec![sample(
                "body_search",
                "Secret Query About Private Project",
                Some(4.2),
                Some(1),
                "complete",
                Vec::new(),
            )],
        );

        let json = serde_json::to_string(&artifact).expect("json");

        assert!(!json.contains("Secret Query"));
        assert!(!json.contains("Private Project"));
        assert!(!json.contains("Private Vault"));
        assert!(!json.contains("/Users/example"));
        assert!(!json.contains("metadata.sqlite"));
        assert!(json.contains("\"body_search\""));
        assert!(json.contains("\"raw_queries_committed\":false"));
        assert!(json.contains("\"root_name\":\"redacted-vault\""));
        assert!(json.contains("\"metadata_path_hash\":\"redacted\""));
        assert!(json.contains("\"tantivy_path_hash\":\"redacted\""));
    }

    #[test]
    fn private_input_hashes_do_not_repeat_across_public_samples() {
        let first = sample(
            "body_search",
            "Secret Query About Private Project",
            Some(1.0),
            Some(1),
            "complete",
            Vec::new(),
        );
        let second = sample(
            "body_search",
            "Secret Query About Private Project",
            Some(1.0),
            Some(1),
            "complete",
            Vec::new(),
        );

        assert_ne!(first.input_hash, second.input_hash);
        assert_ne!(first.sample_id, second.sample_id);
    }

    #[test]
    fn raw_error_notes_are_classified_before_serialization() {
        let artifact = artifact_from_samples(
            &options(),
            vec![error_sample(
                "body_search",
                "Secret Query About Private Project",
                "sqlite failed at /Users/example/Private Vault/Secret.md for Secret Query"
                    .to_string(),
            )],
        );

        let json = serde_json::to_string(&artifact).expect("json");

        assert!(!json.contains("/Users/example"));
        assert!(!json.contains("Secret.md"));
        assert!(!json.contains("Secret Query"));
        assert!(json.contains("error_class=redacted"));
    }
}
