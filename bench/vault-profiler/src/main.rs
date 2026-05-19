use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use vault_engine::benchmarks::{
    VaultBackendBenchmarkOptions, run_shared_backend_benchmark_from_vault,
};
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
                })?;
            write_json(
                &command.vault_root,
                command.output_path,
                &artifact,
                command.pretty,
            )
        }
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
    pretty: bool,
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
            pretty: parser.pretty,
        })
    }
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
    "usage: vault-profiler <profile|query-corpus|synthetic-vault|backend-benchmark> --vault <path> [--output <path>] [--pretty]"
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
                    pretty: true,
                }),
            }
        );
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
