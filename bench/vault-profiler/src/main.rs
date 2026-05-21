use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use std::time::Instant;
use vault_engine::benchmarks::{
    SnippetStorageMode, VaultBackendBenchmarkOptions, run_shared_backend_benchmark_from_vault,
};
use vault_engine::tantivy_search::{TantivySearchError, TantivySearchIndex};
use vault_profiler::corpus::{QueryCorpusOptions, generate_query_corpus_bundle};
use vault_profiler::synthetic::{
    SyntheticProfile, SyntheticVaultOptions, generate_synthetic_vault,
};
use vault_profiler::{ProfileOptions, is_output_inside_vault, profile_vault};

fn main() {
    if let Err(err) = run() {
        eprintln!("vault-profiler: {err}");
        process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse(env::args_os().skip(1))?;
    match cli.command {
        Command::Profile(command) => {
            let profile = profile_vault(&ProfileOptions {
                vault_root: command.vault_root.clone(),
                largest_limit: command.largest_limit,
                include_paths: command.include_paths,
            })?;
            write_json(
                &command.vault_root,
                command.output_path,
                &profile,
                command.pretty,
            )
        }
        Command::QueryCorpus(command) => {
            let options = QueryCorpusOptions {
                vault_root: command.vault_root.clone(),
                samples_per_class: command.samples_per_class,
                seed: command.seed,
            };
            let bundle = generate_query_corpus_bundle(&options)?;
            if let Some(private_query_output) = &command.private_query_output {
                if is_output_inside_vault(&command.vault_root, private_query_output)? {
                    return Err("refusing to write private query output inside the vault".into());
                }
                fs::write(private_query_output, bundle.private_query_lines.join("\n"))?;
            }
            write_json(
                &command.vault_root,
                command.output_path,
                &bundle.corpus,
                command.pretty,
            )
        }
        Command::SyntheticVault(command) => {
            let manifest = generate_synthetic_vault(&SyntheticVaultOptions {
                output_root: command.output_root,
                profile: command.profile,
                seed: command.seed,
                target_markdown_count: command.target_markdown_count,
            })?;
            if command.pretty {
                println!("{}", serde_json::to_string_pretty(&manifest)?);
            } else {
                println!("{}", serde_json::to_string(&manifest)?);
            }
            Ok(())
        }
        Command::BackendBenchmark(command) => {
            if is_output_inside_vault(&command.vault_root, &command.work_dir)? {
                return Err("refusing to write benchmark indexes inside the vault".into());
            }
            let mut queries = command.queries;
            if let Some(query_file) = command.query_file {
                queries.extend(read_query_file(&query_file)?);
            }
            if queries.is_empty() {
                return Err("missing at least one --query or --query-file entry".into());
            }

            let artifact =
                run_shared_backend_benchmark_from_vault(&VaultBackendBenchmarkOptions {
                    corpus_id: command.corpus_id,
                    vault_root: command.vault_root.clone(),
                    queries,
                    result_limit: command.result_limit,
                    work_dir: command.work_dir,
                    time_to_usable_sample_count: command.time_to_usable_samples,
                    snippet_storage_mode: command.snippet_storage_mode,
                    include_sqlite_fts: command.include_sqlite_fts,
                })?;
            write_json(
                &command.vault_root,
                command.output_path,
                &artifact,
                command.pretty,
            )
        }
        Command::ObsidianRunbook(command) => write_obsidian_runbook(&command),
        Command::TantivyQueryBenchmark(command) => run_tantivy_query_benchmark(&command),
    }
}

fn read_query_file(path: &Path) -> Result<Vec<String>, Box<dyn Error>> {
    let text = fs::read_to_string(path)?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect())
}

fn parse_snippet_storage_mode(value: &str) -> Result<SnippetStorageMode, Box<dyn Error>> {
    match value {
        "stored-body" => Ok(SnippetStorageMode::StoredBody),
        "lazy-source-experiment" => Ok(SnippetStorageMode::LazySourceExperiment),
        _ => Err(format!("unknown snippet storage mode: {value}").into()),
    }
}

fn write_json<T: serde::Serialize>(
    vault_root: &Path,
    output_path: Option<PathBuf>,
    value: &T,
    pretty: bool,
) -> Result<(), Box<dyn Error>> {
    let json = if pretty {
        serde_json::to_string_pretty(value)?
    } else {
        serde_json::to_string(value)?
    };

    if let Some(output_path) = output_path {
        if is_output_inside_vault(vault_root, &output_path)? {
            return Err("refusing to write output inside the vault".into());
        }
        fs::write(output_path, json)?;
    } else {
        println!("{json}");
    }

    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct Cli {
    command: Command,
}

#[derive(Debug, PartialEq, Eq)]
enum Command {
    Profile(ProfileCommand),
    QueryCorpus(QueryCorpusCommand),
    SyntheticVault(SyntheticVaultCommand),
    BackendBenchmark(BackendBenchmarkCommand),
    ObsidianRunbook(ObsidianRunbookCommand),
    TantivyQueryBenchmark(TantivyQueryBenchmarkCommand),
}

#[derive(Debug, PartialEq, Eq)]
struct ProfileCommand {
    vault_root: PathBuf,
    output_path: Option<PathBuf>,
    largest_limit: usize,
    include_paths: bool,
    pretty: bool,
}

#[derive(Debug, PartialEq, Eq)]
struct QueryCorpusCommand {
    vault_root: PathBuf,
    output_path: Option<PathBuf>,
    private_query_output: Option<PathBuf>,
    samples_per_class: usize,
    seed: u64,
    pretty: bool,
}

#[derive(Debug, PartialEq, Eq)]
struct SyntheticVaultCommand {
    output_root: PathBuf,
    profile: SyntheticProfile,
    seed: u64,
    target_markdown_count: u64,
    pretty: bool,
}

#[derive(Debug, PartialEq, Eq)]
struct BackendBenchmarkCommand {
    vault_root: PathBuf,
    output_path: Option<PathBuf>,
    work_dir: PathBuf,
    queries: Vec<String>,
    query_file: Option<PathBuf>,
    corpus_id: String,
    result_limit: usize,
    time_to_usable_samples: usize,
    snippet_storage_mode: SnippetStorageMode,
    include_sqlite_fts: bool,
    pretty: bool,
}

#[derive(Debug, PartialEq, Eq)]
struct ObsidianRunbookCommand {
    corpus_path: PathBuf,
    private_query_file: PathBuf,
    output_path: PathBuf,
    pretty: bool,
}

#[derive(Debug, PartialEq, Eq)]
struct TantivyQueryBenchmarkCommand {
    index_dir: PathBuf,
    runbook_path: PathBuf,
    output_path: PathBuf,
    result_limit: usize,
    pretty: bool,
}

#[derive(Debug, Deserialize)]
struct RunbookCorpus {
    samples: Vec<RunbookSample>,
}

#[derive(Debug, Deserialize)]
struct RunbookSample {
    id: String,
    query_class: String,
    query_hash: String,
    redacted_display: String,
    expected_result_shape: String,
}

#[derive(Debug, Deserialize, Serialize, PartialEq)]
struct ObsidianRunbookEntry {
    sample_id: String,
    query_class: String,
    query_hash: String,
    redacted_display: String,
    expected_result_shape: String,
    obsidian_surface: String,
    timing_stop_condition: String,
    raw_query: String,
    duration_ms: Option<f64>,
    excluded: bool,
    notes: Vec<String>,
}

#[derive(Debug, Serialize)]
struct TantivyQueryBenchmarkArtifact {
    schema_version: u32,
    tool: String,
    runbook_source: String,
    index_source: String,
    result_limit: usize,
    sample_count: usize,
    measured_sample_count: usize,
    summaries: Vec<TantivyQueryClassSummary>,
    samples: Vec<TantivyQuerySample>,
    notes: Vec<String>,
}

#[derive(Debug, Serialize)]
struct TantivyQueryClassSummary {
    query_class: String,
    sample_count: usize,
    measured_sample_count: usize,
    skipped_sample_count: usize,
    error_sample_count: usize,
    median_ms: Option<f64>,
    p90_ms: Option<f64>,
    p95_ms: Option<f64>,
    p99_ms: Option<f64>,
}

#[derive(Debug, Serialize)]
struct TantivyQuerySample {
    sample_id: String,
    query_class: String,
    query_hash: String,
    redacted_display: String,
    expected_result_shape: String,
    duration_ms: Option<f64>,
    result_count: Option<usize>,
    state: String,
    notes: Vec<String>,
}

impl Cli {
    fn parse<I>(mut args: I) -> Result<Self, Box<dyn Error>>
    where
        I: Iterator<Item = OsString>,
    {
        let Some(command) = args.next() else {
            return Err(usage().into());
        };

        let command = match command.to_string_lossy().as_ref() {
            "profile" => Command::Profile(ProfileCommand::parse(args)?),
            "query-corpus" => Command::QueryCorpus(QueryCorpusCommand::parse(args)?),
            "synthetic-vault" => Command::SyntheticVault(SyntheticVaultCommand::parse(args)?),
            "backend-benchmark" => Command::BackendBenchmark(BackendBenchmarkCommand::parse(args)?),
            "obsidian-runbook" => Command::ObsidianRunbook(ObsidianRunbookCommand::parse(args)?),
            "tantivy-query-benchmark" => {
                Command::TantivyQueryBenchmark(TantivyQueryBenchmarkCommand::parse(args)?)
            }
            _ => return Err(usage().into()),
        };

        Ok(Self { command })
    }
}

impl ProfileCommand {
    fn parse<I>(args: I) -> Result<Self, Box<dyn Error>>
    where
        I: Iterator<Item = OsString>,
    {
        let mut parser = CommonParser::new(args);
        let mut largest_limit = 20;
        let mut include_paths = false;

        while let Some(arg) = parser.next_arg() {
            match arg.as_str() {
                "--largest" => {
                    let value = parser.required_string_arg("--largest")?;
                    largest_limit = value.parse()?;
                }
                "--include-paths" => include_paths = true,
                _ => parser.parse_common_arg(arg)?,
            }
        }

        let vault_root = parser.required_vault()?;
        Ok(Self {
            vault_root,
            output_path: parser.output_path,
            largest_limit,
            include_paths,
            pretty: parser.pretty,
        })
    }
}

impl QueryCorpusCommand {
    fn parse<I>(args: I) -> Result<Self, Box<dyn Error>>
    where
        I: Iterator<Item = OsString>,
    {
        let mut parser = CommonParser::new(args);
        let mut samples_per_class = 100;
        let mut seed = 20260519;
        let mut private_query_output = None;

        while let Some(arg) = parser.next_arg() {
            match arg.as_str() {
                "--samples-per-class" => {
                    let value = parser.required_string_arg("--samples-per-class")?;
                    samples_per_class = value.parse()?;
                }
                "--seed" => {
                    let value = parser.required_string_arg("--seed")?;
                    seed = value.parse()?;
                }
                "--private-query-output" => {
                    private_query_output =
                        Some(parser.required_path_arg("--private-query-output")?);
                }
                _ => parser.parse_common_arg(arg)?,
            }
        }

        let vault_root = parser.required_vault()?;
        Ok(Self {
            vault_root,
            output_path: parser.output_path,
            private_query_output,
            samples_per_class,
            seed,
            pretty: parser.pretty,
        })
    }
}

impl SyntheticVaultCommand {
    fn parse<I>(mut args: I) -> Result<Self, Box<dyn Error>>
    where
        I: Iterator<Item = OsString>,
    {
        let mut output_root = None;
        let mut profile = SyntheticProfile::Small;
        let mut seed = 20260519;
        let mut target_markdown_count = 64_306;
        let mut pretty = false;

        while let Some(arg) = args.next() {
            match arg.to_string_lossy().as_ref() {
                "--output" => {
                    output_root = Some(PathBuf::from(required_string(&mut args, "--output")?));
                }
                "--profile" => {
                    let value = required_string(&mut args, "--profile")?;
                    profile = SyntheticProfile::parse(&value)
                        .ok_or_else(|| format!("unknown synthetic profile: {value}"))?;
                }
                "--seed" => {
                    let value = required_string(&mut args, "--seed")?;
                    seed = value.parse()?;
                }
                "--target-markdown-count" => {
                    let value = required_string(&mut args, "--target-markdown-count")?;
                    target_markdown_count = value.parse()?;
                }
                "--pretty" => pretty = true,
                _ => return Err(usage().into()),
            }
        }

        let Some(output_root) = output_root else {
            return Err("missing required --output argument".into());
        };

        Ok(Self {
            output_root,
            profile,
            seed,
            target_markdown_count,
            pretty,
        })
    }
}

impl BackendBenchmarkCommand {
    fn parse<I>(args: I) -> Result<Self, Box<dyn Error>>
    where
        I: Iterator<Item = OsString>,
    {
        let mut parser = CommonParser::new(args);
        let mut work_dir = None;
        let mut queries = Vec::new();
        let mut query_file = None;
        let mut corpus_id = "manual".to_string();
        let mut result_limit = 10;
        let mut time_to_usable_samples = 1;
        let mut snippet_storage_mode = SnippetStorageMode::StoredBody;
        let mut include_sqlite_fts = true;

        while let Some(arg) = parser.next_arg() {
            match arg.as_str() {
                "--work-dir" => work_dir = Some(parser.required_path_arg("--work-dir")?),
                "--query" => queries.push(parser.required_string_arg("--query")?),
                "--query-file" => {
                    query_file = Some(parser.required_path_arg("--query-file")?);
                }
                "--corpus-id" => corpus_id = parser.required_string_arg("--corpus-id")?,
                "--limit" => {
                    let value = parser.required_string_arg("--limit")?;
                    result_limit = value.parse()?;
                }
                "--time-to-usable-samples" => {
                    let value = parser.required_string_arg("--time-to-usable-samples")?;
                    time_to_usable_samples = value.parse::<usize>()?.max(1);
                }
                "--snippet-storage-mode" => {
                    let value = parser.required_string_arg("--snippet-storage-mode")?;
                    snippet_storage_mode = parse_snippet_storage_mode(&value)?;
                }
                "--skip-sqlite-fts" => include_sqlite_fts = false,
                _ => parser.parse_common_arg(arg)?,
            }
        }

        let vault_root = parser.required_vault()?;
        let Some(work_dir) = work_dir else {
            return Err("missing required --work-dir argument".into());
        };

        Ok(Self {
            vault_root,
            output_path: parser.output_path,
            work_dir,
            queries,
            query_file,
            corpus_id,
            result_limit,
            time_to_usable_samples,
            snippet_storage_mode,
            include_sqlite_fts,
            pretty: parser.pretty,
        })
    }
}

impl ObsidianRunbookCommand {
    fn parse<I>(mut args: I) -> Result<Self, Box<dyn Error>>
    where
        I: Iterator<Item = OsString>,
    {
        let mut corpus_path = None;
        let mut private_query_file = None;
        let mut output_path = None;
        let mut pretty = false;

        while let Some(arg) = args.next() {
            match arg.to_string_lossy().as_ref() {
                "--corpus" => {
                    corpus_path = Some(PathBuf::from(required_string(&mut args, "--corpus")?))
                }
                "--private-query-file" => {
                    private_query_file = Some(PathBuf::from(required_string(
                        &mut args,
                        "--private-query-file",
                    )?));
                }
                "--output" => {
                    output_path = Some(PathBuf::from(required_string(&mut args, "--output")?))
                }
                "--pretty" => pretty = true,
                _ => return Err(usage().into()),
            }
        }

        let Some(corpus_path) = corpus_path else {
            return Err("missing required --corpus argument".into());
        };
        let Some(private_query_file) = private_query_file else {
            return Err("missing required --private-query-file argument".into());
        };
        let Some(output_path) = output_path else {
            return Err("missing required --output argument".into());
        };

        Ok(Self {
            corpus_path,
            private_query_file,
            output_path,
            pretty,
        })
    }
}

impl TantivyQueryBenchmarkCommand {
    fn parse<I>(mut args: I) -> Result<Self, Box<dyn Error>>
    where
        I: Iterator<Item = OsString>,
    {
        let mut index_dir = None;
        let mut runbook_path = None;
        let mut output_path = None;
        let mut result_limit = 10;
        let mut pretty = false;

        while let Some(arg) = args.next() {
            match arg.to_string_lossy().as_ref() {
                "--index-dir" => {
                    index_dir = Some(PathBuf::from(required_string(&mut args, "--index-dir")?))
                }
                "--runbook" => {
                    runbook_path = Some(PathBuf::from(required_string(&mut args, "--runbook")?))
                }
                "--output" => {
                    output_path = Some(PathBuf::from(required_string(&mut args, "--output")?))
                }
                "--limit" => {
                    let value = required_string(&mut args, "--limit")?;
                    result_limit = value.parse()?;
                }
                "--pretty" => pretty = true,
                _ => return Err(usage().into()),
            }
        }

        let Some(index_dir) = index_dir else {
            return Err("missing required --index-dir argument".into());
        };
        let Some(runbook_path) = runbook_path else {
            return Err("missing required --runbook argument".into());
        };
        let Some(output_path) = output_path else {
            return Err("missing required --output argument".into());
        };

        Ok(Self {
            index_dir,
            runbook_path,
            output_path,
            result_limit,
            pretty,
        })
    }
}

fn write_obsidian_runbook(command: &ObsidianRunbookCommand) -> Result<(), Box<dyn Error>> {
    if !has_private_path_component(&command.output_path) {
        return Err("raw Obsidian runbook output must be written under a private directory".into());
    }

    let entries = obsidian_runbook_entries(&command.corpus_path, &command.private_query_file)?;
    let json = if command.pretty {
        serde_json::to_string_pretty(&entries)?
    } else {
        serde_json::to_string(&entries)?
    };
    if let Some(parent) = command.output_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&command.output_path, json)?;
    Ok(())
}

fn run_tantivy_query_benchmark(
    command: &TantivyQueryBenchmarkCommand,
) -> Result<(), Box<dyn Error>> {
    let runbook: Vec<ObsidianRunbookEntry> =
        serde_json::from_str(&fs::read_to_string(&command.runbook_path)?)?;
    let index = TantivySearchIndex::open_existing_dir(&command.index_dir)?;
    let mut samples = Vec::with_capacity(runbook.len());

    for entry in &runbook {
        let start = Instant::now();
        let sample = match index.search(&entry.raw_query, command.result_limit) {
            Ok(results) => TantivyQuerySample {
                sample_id: entry.sample_id.clone(),
                query_class: entry.query_class.clone(),
                query_hash: entry.query_hash.clone(),
                redacted_display: entry.redacted_display.clone(),
                expected_result_shape: entry.expected_result_shape.clone(),
                duration_ms: Some(start.elapsed().as_secs_f64() * 1_000.0),
                result_count: Some(results.len()),
                state: "measured".to_string(),
                notes: Vec::new(),
            },
            Err(TantivySearchError::EmptyQuery) => TantivyQuerySample {
                sample_id: entry.sample_id.clone(),
                query_class: entry.query_class.clone(),
                query_hash: entry.query_hash.clone(),
                redacted_display: entry.redacted_display.clone(),
                expected_result_shape: entry.expected_result_shape.clone(),
                duration_ms: None,
                result_count: None,
                state: "skipped".to_string(),
                notes: vec!["query is empty after Tantivy sanitization".to_string()],
            },
            Err(error) => TantivyQuerySample {
                sample_id: entry.sample_id.clone(),
                query_class: entry.query_class.clone(),
                query_hash: entry.query_hash.clone(),
                redacted_display: entry.redacted_display.clone(),
                expected_result_shape: entry.expected_result_shape.clone(),
                duration_ms: None,
                result_count: None,
                state: "error".to_string(),
                notes: vec![error.to_string()],
            },
        };
        samples.push(sample);
    }

    let summaries = tantivy_query_summaries(&samples);
    let measured_sample_count = samples
        .iter()
        .filter(|sample| sample.state == "measured")
        .count();
    let artifact = TantivyQueryBenchmarkArtifact {
        schema_version: 1,
        tool: "vault-profiler tantivy-query-benchmark".to_string(),
        runbook_source: command.runbook_path.display().to_string(),
        index_source: command.index_dir.display().to_string(),
        result_limit: command.result_limit,
        sample_count: samples.len(),
        measured_sample_count,
        summaries,
        samples,
        notes: vec![
            "Raw query text was read from the ignored private runbook and is not included in this artifact.".to_string(),
            "This measures the selected Tantivy native search backend against the same query classes used for the Obsidian baseline.".to_string(),
        ],
    };

    let json = if command.pretty {
        serde_json::to_string_pretty(&artifact)?
    } else {
        serde_json::to_string(&artifact)?
    };
    if let Some(parent) = command.output_path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&command.output_path, json)?;
    Ok(())
}

fn tantivy_query_summaries(samples: &[TantivyQuerySample]) -> Vec<TantivyQueryClassSummary> {
    let mut grouped: BTreeMap<&str, Vec<&TantivyQuerySample>> = BTreeMap::new();
    for sample in samples {
        grouped
            .entry(sample.query_class.as_str())
            .or_default()
            .push(sample);
    }

    grouped
        .into_iter()
        .map(|(query_class, samples)| {
            let mut durations = samples
                .iter()
                .filter_map(|sample| sample.duration_ms)
                .collect::<Vec<_>>();
            durations.sort_by(f64::total_cmp);
            TantivyQueryClassSummary {
                query_class: query_class.to_string(),
                sample_count: samples.len(),
                measured_sample_count: durations.len(),
                skipped_sample_count: samples
                    .iter()
                    .filter(|sample| sample.state == "skipped")
                    .count(),
                error_sample_count: samples
                    .iter()
                    .filter(|sample| sample.state == "error")
                    .count(),
                median_ms: percentile_f64(&durations, 50),
                p90_ms: percentile_f64(&durations, 90),
                p95_ms: percentile_f64(&durations, 95),
                p99_ms: percentile_f64(&durations, 99),
            }
        })
        .collect()
}

fn percentile_f64(values: &[f64], percentile: usize) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let index = ((values.len() * percentile).div_ceil(100)).saturating_sub(1);
    Some(values[index.min(values.len() - 1)])
}

fn obsidian_runbook_entries(
    corpus_path: &Path,
    private_query_file: &Path,
) -> Result<Vec<ObsidianRunbookEntry>, Box<dyn Error>> {
    let corpus: RunbookCorpus = serde_json::from_str(&fs::read_to_string(corpus_path)?)?;
    let raw_queries = fs::read_to_string(private_query_file)?
        .lines()
        .map(str::to_string)
        .collect::<Vec<_>>();

    if corpus.samples.len() != raw_queries.len() {
        return Err(format!(
            "sample count mismatch: corpus has {}, private query file has {}",
            corpus.samples.len(),
            raw_queries.len()
        )
        .into());
    }

    Ok(corpus
        .samples
        .into_iter()
        .zip(raw_queries)
        .map(|(sample, raw_query)| ObsidianRunbookEntry {
            obsidian_surface: obsidian_surface(&sample.query_class).to_string(),
            timing_stop_condition: timing_stop_condition(&sample.query_class).to_string(),
            sample_id: sample.id,
            query_class: sample.query_class,
            query_hash: sample.query_hash,
            redacted_display: sample.redacted_display,
            expected_result_shape: sample.expected_result_shape,
            raw_query,
            duration_ms: None,
            excluded: false,
            notes: Vec::new(),
        })
        .collect())
}

fn obsidian_surface(query_class: &str) -> &'static str {
    match query_class {
        "file_name" => "Quick Switcher",
        "body" => "Search panel",
        "backlink" => "Backlinks pane",
        "tag" => "Tags pane or tag search",
        "property" => "Search panel property query",
        _ => "Manual Obsidian surface",
    }
}

fn timing_stop_condition(query_class: &str) -> &'static str {
    match query_class {
        "file_name" => "Result list is visually stable for 500ms",
        "body" => "Search results and count are visually stable for 500ms",
        "backlink" => "Backlinks pane is visually stable for 500ms",
        "tag" => "Tag result list is visually stable for 500ms",
        "property" => "Property query result list is visually stable for 500ms",
        _ => "Relevant result surface is visually stable for 500ms",
    }
}

fn has_private_path_component(path: &Path) -> bool {
    path.components()
        .any(|component| component.as_os_str() == "private")
}

fn required_string<I>(args: &mut I, name: &str) -> Result<String, Box<dyn Error>>
where
    I: Iterator<Item = OsString>,
{
    let Some(value) = args.next() else {
        return Err(format!("missing value for {name}").into());
    };
    Ok(value.to_string_lossy().to_string())
}

struct CommonParser<I>
where
    I: Iterator<Item = OsString>,
{
    args: I,
    vault_root: Option<PathBuf>,
    output_path: Option<PathBuf>,
    pretty: bool,
}

impl<I> CommonParser<I>
where
    I: Iterator<Item = OsString>,
{
    fn new(args: I) -> Self {
        Self {
            args,
            vault_root: None,
            output_path: None,
            pretty: false,
        }
    }

    fn next_arg(&mut self) -> Option<String> {
        self.args
            .next()
            .map(|arg| arg.to_string_lossy().to_string())
    }

    fn parse_common_arg(&mut self, arg: String) -> Result<(), Box<dyn Error>> {
        match arg.as_str() {
            "--vault" => self.vault_root = Some(self.required_path_arg("--vault")?),
            "--output" => self.output_path = Some(self.required_path_arg("--output")?),
            "--pretty" => self.pretty = true,
            _ => return Err(usage().into()),
        }
        Ok(())
    }

    fn required_vault(&mut self) -> Result<PathBuf, Box<dyn Error>> {
        self.vault_root
            .take()
            .ok_or_else(|| "missing required --vault argument".into())
    }

    fn required_path_arg(&mut self, name: &str) -> Result<PathBuf, Box<dyn Error>> {
        Ok(PathBuf::from(self.required_string_arg(name)?))
    }

    fn required_string_arg(&mut self, name: &str) -> Result<String, Box<dyn Error>> {
        let Some(value) = self.args.next() else {
            return Err(format!("missing value for {name}").into());
        };
        Ok(value.to_string_lossy().to_string())
    }
}

fn usage() -> &'static str {
    "usage: vault-profiler <profile|query-corpus|synthetic-vault|backend-benchmark|obsidian-runbook|tantivy-query-benchmark> [options]"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_required_profile_args() {
        let cli = Cli::parse(
            [
                "profile",
                "--vault",
                "/tmp/vault",
                "--output",
                "/tmp/profile.json",
                "--largest",
                "5",
                "--include-paths",
                "--pretty",
            ]
            .into_iter()
            .map(OsString::from),
        )
        .expect("cli");

        assert_eq!(
            cli,
            Cli {
                command: Command::Profile(ProfileCommand {
                    vault_root: PathBuf::from("/tmp/vault"),
                    output_path: Some(PathBuf::from("/tmp/profile.json")),
                    largest_limit: 5,
                    include_paths: true,
                    pretty: true,
                }),
            }
        );
    }

    #[test]
    fn parses_query_corpus_args() {
        let cli = Cli::parse(
            [
                "query-corpus",
                "--vault",
                "/tmp/vault",
                "--output",
                "/tmp/query-corpus.json",
                "--samples-per-class",
                "25",
                "--seed",
                "99",
                "--private-query-output",
                "/tmp/private-queries.txt",
                "--pretty",
            ]
            .into_iter()
            .map(OsString::from),
        )
        .expect("cli");

        assert_eq!(
            cli,
            Cli {
                command: Command::QueryCorpus(QueryCorpusCommand {
                    vault_root: PathBuf::from("/tmp/vault"),
                    output_path: Some(PathBuf::from("/tmp/query-corpus.json")),
                    private_query_output: Some(PathBuf::from("/tmp/private-queries.txt")),
                    samples_per_class: 25,
                    seed: 99,
                    pretty: true,
                }),
            }
        );
    }

    #[test]
    fn rejects_missing_vault_arg() {
        assert!(Cli::parse([OsString::from("profile")].into_iter()).is_err());
    }

    #[test]
    fn parses_synthetic_vault_args() {
        let cli = Cli::parse(
            [
                "synthetic-vault",
                "--output",
                "/tmp/synthetic",
                "--profile",
                "2x",
                "--target-markdown-count",
                "10",
                "--seed",
                "123",
                "--pretty",
            ]
            .into_iter()
            .map(OsString::from),
        )
        .expect("cli");

        assert_eq!(
            cli,
            Cli {
                command: Command::SyntheticVault(SyntheticVaultCommand {
                    output_root: PathBuf::from("/tmp/synthetic"),
                    profile: SyntheticProfile::Double,
                    seed: 123,
                    target_markdown_count: 10,
                    pretty: true,
                }),
            }
        );
    }

    #[test]
    fn parses_backend_benchmark_args() {
        let cli = Cli::parse(
            [
                "backend-benchmark",
                "--vault",
                "/tmp/vault",
                "--output",
                "/tmp/backend.json",
                "--work-dir",
                "/tmp/indexes",
                "--query",
                "Home",
                "--query-file",
                "/tmp/queries.txt",
                "--corpus-id",
                "fixture",
                "--limit",
                "5",
                "--time-to-usable-samples",
                "3",
                "--snippet-storage-mode",
                "lazy-source-experiment",
                "--skip-sqlite-fts",
                "--pretty",
            ]
            .into_iter()
            .map(OsString::from),
        )
        .expect("cli");

        assert_eq!(
            cli,
            Cli {
                command: Command::BackendBenchmark(BackendBenchmarkCommand {
                    vault_root: PathBuf::from("/tmp/vault"),
                    output_path: Some(PathBuf::from("/tmp/backend.json")),
                    work_dir: PathBuf::from("/tmp/indexes"),
                    queries: vec!["Home".to_string()],
                    query_file: Some(PathBuf::from("/tmp/queries.txt")),
                    corpus_id: "fixture".to_string(),
                    result_limit: 5,
                    time_to_usable_samples: 3,
                    snippet_storage_mode: SnippetStorageMode::LazySourceExperiment,
                    include_sqlite_fts: false,
                    pretty: true,
                }),
            }
        );
    }

    #[test]
    fn parses_obsidian_runbook_args() {
        let cli = Cli::parse(
            [
                "obsidian-runbook",
                "--corpus",
                "/tmp/query-corpus.json",
                "--private-query-file",
                "/tmp/private/queries.txt",
                "--output",
                "/tmp/private/runbook.json",
                "--pretty",
            ]
            .into_iter()
            .map(OsString::from),
        )
        .expect("cli");

        assert_eq!(
            cli,
            Cli {
                command: Command::ObsidianRunbook(ObsidianRunbookCommand {
                    corpus_path: PathBuf::from("/tmp/query-corpus.json"),
                    private_query_file: PathBuf::from("/tmp/private/queries.txt"),
                    output_path: PathBuf::from("/tmp/private/runbook.json"),
                    pretty: true,
                }),
            }
        );
    }

    #[test]
    fn parses_tantivy_query_benchmark_args() {
        let cli = Cli::parse(
            [
                "tantivy-query-benchmark",
                "--index-dir",
                "/tmp/tantivy",
                "--runbook",
                "/tmp/private/runbook.json",
                "--output",
                "/tmp/native.json",
                "--limit",
                "25",
                "--pretty",
            ]
            .into_iter()
            .map(OsString::from),
        )
        .expect("cli");

        assert_eq!(
            cli,
            Cli {
                command: Command::TantivyQueryBenchmark(TantivyQueryBenchmarkCommand {
                    index_dir: PathBuf::from("/tmp/tantivy"),
                    runbook_path: PathBuf::from("/tmp/private/runbook.json"),
                    output_path: PathBuf::from("/tmp/native.json"),
                    result_limit: 25,
                    pretty: true,
                }),
            }
        );
    }

    #[test]
    fn obsidian_runbook_pairs_redacted_samples_with_private_queries() {
        let dir = tempfile::tempdir().expect("tempdir");
        let corpus = dir.path().join("corpus.json");
        let private_dir = dir.path().join("private");
        let queries = private_dir.join("queries.txt");
        let output = private_dir.join("runbook.json");
        fs::create_dir_all(&private_dir).expect("private dir");
        fs::write(
            &corpus,
            r#"{
              "samples": [
                {
                  "id": "file_name-0001",
                  "query_class": "file_name",
                  "query_hash": "hash-a",
                  "redacted_display": "<hash-a:english:single>",
                  "expected_result_shape": "single"
                },
                {
                  "id": "body-0001",
                  "query_class": "body",
                  "query_hash": "hash-b",
                  "redacted_display": "<hash-b:english:many>",
                  "expected_result_shape": "many"
                }
              ]
            }"#,
        )
        .expect("corpus");
        fs::write(&queries, "Secret Note\nprivate body phrase\n").expect("queries");

        let command = ObsidianRunbookCommand {
            corpus_path: corpus,
            private_query_file: queries,
            output_path: output.clone(),
            pretty: true,
        };
        write_obsidian_runbook(&command).expect("runbook");

        let runbook = fs::read_to_string(output).expect("runbook json");
        assert!(runbook.contains("\"sample_id\": \"file_name-0001\""));
        assert!(runbook.contains("\"obsidian_surface\": \"Quick Switcher\""));
        assert!(runbook.contains("\"raw_query\": \"Secret Note\""));
        assert!(runbook.contains("\"duration_ms\": null"));
    }

    #[test]
    fn obsidian_runbook_rejects_non_private_output() {
        let dir = tempfile::tempdir().expect("tempdir");
        let corpus = dir.path().join("corpus.json");
        let queries = dir.path().join("queries.txt");
        fs::write(
            &corpus,
            r#"{"samples":[{"id":"file_name-0001","query_class":"file_name","query_hash":"hash","redacted_display":"<hash>","expected_result_shape":"single"}]}"#,
        )
        .expect("corpus");
        fs::write(&queries, "Secret Note\n").expect("queries");

        let command = ObsidianRunbookCommand {
            corpus_path: corpus,
            private_query_file: queries,
            output_path: dir.path().join("runbook.json"),
            pretty: false,
        };

        assert!(write_obsidian_runbook(&command).is_err());
    }

    #[test]
    fn tantivy_query_benchmark_writes_redacted_class_summaries() {
        let dir = tempfile::tempdir().expect("tempdir");
        let index_dir = dir.path().join("tantivy");
        let runbook_path = dir.path().join("runbook.json");
        let output_path = dir.path().join("native.json");
        let mut index = TantivySearchIndex::open_in_dir(&index_dir).expect("index");
        index
            .replace_documents(&[
                vault_engine::sqlite_fts::SearchDocument {
                    file_id: "alpha".to_string(),
                    path: "Alpha.md".to_string(),
                    title: "Alpha".to_string(),
                    body: "body token".to_string(),
                },
                vault_engine::sqlite_fts::SearchDocument {
                    file_id: "beta".to_string(),
                    path: "Beta.md".to_string(),
                    title: "Beta".to_string(),
                    body: "tagged note".to_string(),
                },
            ])
            .expect("documents");
        fs::write(
            &runbook_path,
            r#"[
              {
                "sample_id": "file_name-0001",
                "query_class": "file_name",
                "query_hash": "hash-a",
                "redacted_display": "<hash-a:english:single>",
                "expected_result_shape": "single",
                "obsidian_surface": "Quick Switcher",
                "timing_stop_condition": "stable",
                "raw_query": "Alpha",
                "duration_ms": null,
                "excluded": false,
                "notes": []
              },
              {
                "sample_id": "body-0001",
                "query_class": "body",
                "query_hash": "hash-b",
                "redacted_display": "<hash-b:english:single>",
                "expected_result_shape": "single",
                "obsidian_surface": "Search panel",
                "timing_stop_condition": "stable",
                "raw_query": "body",
                "duration_ms": null,
                "excluded": false,
                "notes": []
              }
            ]"#,
        )
        .expect("runbook");

        let command = TantivyQueryBenchmarkCommand {
            index_dir,
            runbook_path,
            output_path: output_path.clone(),
            result_limit: 10,
            pretty: true,
        };
        run_tantivy_query_benchmark(&command).expect("benchmark");

        let artifact = fs::read_to_string(output_path).expect("artifact");
        assert!(artifact.contains("\"query_class\": \"file_name\""));
        assert!(artifact.contains("\"measured_sample_count\": 1"));
        assert!(!artifact.contains("\"raw_query\""));
        assert!(!artifact.contains("\"Alpha\""));
    }

    #[test]
    fn query_file_preserves_hash_tag_queries() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("queries.txt");
        fs::write(&path, "\n#Obsidian\nHome\n#보안_검증\n").expect("queries");

        assert_eq!(
            read_query_file(&path).expect("read queries"),
            vec![
                "#Obsidian".to_string(),
                "Home".to_string(),
                "#보안_검증".to_string()
            ]
        );
    }
}
