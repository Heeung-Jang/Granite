use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use vault_profiler::corpus::{QueryCorpusOptions, generate_query_corpus};
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
            let corpus = generate_query_corpus(&QueryCorpusOptions {
                vault_root: command.vault_root.clone(),
                samples_per_class: command.samples_per_class,
                seed: command.seed,
            })?;
            write_json(
                &command.vault_root,
                command.output_path,
                &corpus,
                command.pretty,
            )
        }
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
    samples_per_class: usize,
    seed: u64,
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
                _ => parser.parse_common_arg(arg)?,
            }
        }

        let vault_root = parser.required_vault()?;
        Ok(Self {
            vault_root,
            output_path: parser.output_path,
            samples_per_class,
            seed,
            pretty: parser.pretty,
        })
    }
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
    "usage: vault-profiler <profile|query-corpus> --vault <path> [--output <path>] [--pretty]"
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
}
