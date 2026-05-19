use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::path::PathBuf;
use std::process;
use vault_profiler::{ProfileOptions, is_output_inside_vault, profile_vault};

fn main() {
    if let Err(err) = run() {
        eprintln!("vault-profiler: {err}");
        process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let cli = Cli::parse(env::args_os().skip(1))?;
    let profile = profile_vault(&ProfileOptions {
        vault_root: cli.vault_root.clone(),
        largest_limit: cli.largest_limit,
        include_paths: cli.include_paths,
    })?;

    let json = if cli.pretty {
        serde_json::to_string_pretty(&profile)?
    } else {
        serde_json::to_string(&profile)?
    };

    if let Some(output_path) = cli.output_path {
        if is_output_inside_vault(&cli.vault_root, &output_path)? {
            return Err("refusing to write profiler output inside the vault".into());
        }
        fs::write(output_path, json)?;
    } else {
        println!("{json}");
    }

    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct Cli {
    vault_root: PathBuf,
    output_path: Option<PathBuf>,
    largest_limit: usize,
    include_paths: bool,
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

        if command != "profile" {
            return Err(usage().into());
        }

        let mut vault_root = None;
        let mut output_path = None;
        let mut largest_limit = 20;
        let mut include_paths = false;
        let mut pretty = false;

        while let Some(arg) = args.next() {
            match arg.to_string_lossy().as_ref() {
                "--vault" => vault_root = Some(required_path_arg(&mut args, "--vault")?),
                "--output" => output_path = Some(required_path_arg(&mut args, "--output")?),
                "--largest" => {
                    let value = required_string_arg(&mut args, "--largest")?;
                    largest_limit = value.parse()?;
                }
                "--include-paths" => include_paths = true,
                "--pretty" => pretty = true,
                _ => return Err(usage().into()),
            }
        }

        let Some(vault_root) = vault_root else {
            return Err("missing required --vault argument".into());
        };

        Ok(Self {
            vault_root,
            output_path,
            largest_limit,
            include_paths,
            pretty,
        })
    }
}

fn required_path_arg<I>(args: &mut I, name: &str) -> Result<PathBuf, Box<dyn Error>>
where
    I: Iterator<Item = OsString>,
{
    Ok(PathBuf::from(required_string_arg(args, name)?))
}

fn required_string_arg<I>(args: &mut I, name: &str) -> Result<String, Box<dyn Error>>
where
    I: Iterator<Item = OsString>,
{
    let Some(value) = args.next() else {
        return Err(format!("missing value for {name}").into());
    };
    Ok(value.to_string_lossy().to_string())
}

fn usage() -> &'static str {
    "usage: vault-profiler profile --vault <path> [--output <path>] [--largest <n>] [--include-paths] [--pretty]"
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
                vault_root: PathBuf::from("/tmp/vault"),
                output_path: Some(PathBuf::from("/tmp/profile.json")),
                largest_limit: 5,
                include_paths: true,
                pretty: true,
            }
        );
    }

    #[test]
    fn rejects_missing_vault_arg() {
        assert!(Cli::parse([OsString::from("profile")].into_iter()).is_err());
    }
}
