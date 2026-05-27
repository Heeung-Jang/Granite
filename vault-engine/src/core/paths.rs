use std::fmt;
use std::path::{Component, Path, PathBuf};

use super::files::FileIdentity;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SymlinkPolicy {
    RejectEscapes,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedVaultPath {
    pub relative_path: PathBuf,
    pub absolute_path: PathBuf,
    pub canonical_path: PathBuf,
    pub file_identity: FileIdentity,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathError {
    RootNotDirectory(PathBuf),
    MissingRoot(PathBuf),
    MissingPath(PathBuf),
    ContainsNul,
    UrlScheme(String),
    TildePrefix,
    AbsolutePath(PathBuf),
    OutsideVault(PathBuf),
    SymlinkEscape { input: PathBuf, canonical: PathBuf },
}

impl fmt::Display for PathError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RootNotDirectory(path) => {
                write!(
                    formatter,
                    "vault root is not a directory: {}",
                    path.display()
                )
            }
            Self::MissingRoot(path) => {
                write!(formatter, "vault root does not exist: {}", path.display())
            }
            Self::MissingPath(path) => write!(formatter, "path does not exist: {}", path.display()),
            Self::ContainsNul => write!(formatter, "path contains a NUL byte"),
            Self::UrlScheme(scheme) => {
                write!(formatter, "path uses unsupported URL scheme: {scheme}")
            }
            Self::TildePrefix => write!(formatter, "tilde expansion is not allowed"),
            Self::AbsolutePath(path) => write!(
                formatter,
                "absolute paths are not allowed: {}",
                path.display()
            ),
            Self::OutsideVault(path) => {
                write!(formatter, "path escapes the vault: {}", path.display())
            }
            Self::SymlinkEscape { input, canonical } => write!(
                formatter,
                "symlink escapes the vault: {} -> {}",
                input.display(),
                canonical.display()
            ),
        }
    }
}

impl std::error::Error for PathError {}

pub fn normalize_relative_path(input: &str) -> Result<PathBuf, PathError> {
    if input.contains('\0') {
        return Err(PathError::ContainsNul);
    }

    let trimmed = input.trim();
    if let Some(scheme) = url_scheme(trimmed) {
        return Err(PathError::UrlScheme(scheme.to_string()));
    }

    if trimmed == "~" || trimmed.starts_with("~/") {
        return Err(PathError::TildePrefix);
    }

    let path = Path::new(trimmed);
    if path.is_absolute() {
        return Err(PathError::AbsolutePath(path.to_path_buf()));
    }

    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::Normal(value) => normalized.push(value),
            Component::ParentDir => {
                if !normalized.pop() {
                    return Err(PathError::OutsideVault(path.to_path_buf()));
                }
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(PathError::AbsolutePath(path.to_path_buf()));
            }
        }
    }

    if normalized.as_os_str().is_empty() {
        return Err(PathError::OutsideVault(path.to_path_buf()));
    }

    Ok(normalized)
}

pub fn lookup_key(input: impl AsRef<Path>) -> String {
    input
        .as_ref()
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => Some(value.to_string_lossy().to_lowercase()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("/")
}

fn url_scheme(input: &str) -> Option<&str> {
    let colon = input.find(':')?;
    let slash = input.find('/').unwrap_or(usize::MAX);
    if colon > slash {
        return None;
    }

    let scheme = &input[..colon];
    let lower = scheme.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "file" | "http" | "https" | "javascript" | "data" | "obsidian"
    )
    .then_some(scheme)
}
