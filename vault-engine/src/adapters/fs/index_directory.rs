use std::fs;
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IndexDirectoryPaths {
    pub(crate) vault_root: PathBuf,
    pub(crate) index_root: PathBuf,
    pub(crate) data_directory: PathBuf,
    pub(crate) rebuild_directory: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct IndexDirectoryCommit {
    pub(crate) data_directory: PathBuf,
    pub(crate) previous_data_removed: bool,
}

#[derive(Debug)]
pub(crate) enum IndexDirectoryError {
    Io(std::io::Error),
    InvalidPath(IndexDirectoryPathError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum IndexDirectoryPathError {
    IndexRootInsideVault,
    DataOutsideIndexRoot,
    RebuildOutsideIndexRoot,
    DataOverlapsVault,
    RebuildOverlapsVault,
    DataEqualsRebuild,
}

pub(crate) type IndexDirectoryResult<T> = Result<T, IndexDirectoryError>;

pub(crate) fn commit_index_rebuild(
    paths: &IndexDirectoryPaths,
) -> IndexDirectoryResult<IndexDirectoryCommit> {
    let paths = validate_paths(paths)?;
    let previous_directory = paths.index_root.join("previous-data");
    ensure_no_vault_overlap(&previous_directory, &paths.vault_root)
        .map_err(IndexDirectoryError::InvalidPath)?;
    ensure_existing_path_does_not_resolve_into_vault(
        &previous_directory,
        &paths.vault_root,
        IndexDirectoryPathError::DataOverlapsVault,
    )?;

    if previous_directory.exists() {
        remove_path(&previous_directory)?;
    }

    let previous_data_removed = if paths.data_directory.exists() {
        fs::rename(&paths.data_directory, &previous_directory)?;
        true
    } else {
        false
    };

    match fs::rename(&paths.rebuild_directory, &paths.data_directory) {
        Ok(()) => {}
        Err(error) => {
            if previous_directory.exists() && !paths.data_directory.exists() {
                let _ = fs::rename(&previous_directory, &paths.data_directory);
            }
            return Err(IndexDirectoryError::Io(error));
        }
    }

    if previous_directory.exists() {
        remove_path(&previous_directory)?;
    }

    Ok(IndexDirectoryCommit {
        data_directory: paths.data_directory,
        previous_data_removed,
    })
}

pub(crate) fn abort_index_rebuild(paths: &IndexDirectoryPaths) -> IndexDirectoryResult<()> {
    let paths = validate_paths(paths)?;
    if paths.rebuild_directory.exists() {
        remove_path(&paths.rebuild_directory)?;
    }
    Ok(())
}

pub(crate) fn reset_rebuild_directory(
    rebuild_directory: &Path,
    generation: u64,
    reason: &str,
) -> IndexDirectoryResult<()> {
    if rebuild_directory.exists() {
        remove_path(rebuild_directory)?;
    }
    fs::create_dir_all(rebuild_directory)?;
    fs::write(
        rebuild_directory.join("rebuild.json"),
        format!("{{\"generation\":{generation},\"reason\":\"{reason}\"}}\n"),
    )?;
    Ok(())
}

pub(crate) fn validate_paths(
    paths: &IndexDirectoryPaths,
) -> IndexDirectoryResult<IndexDirectoryPaths> {
    let vault_root = normalize_path(&paths.vault_root)?;
    let index_root = normalize_path(&paths.index_root)?;
    let data_directory = normalize_path(&paths.data_directory)?;
    let rebuild_directory = normalize_path(&paths.rebuild_directory)?;

    if index_root == vault_root || index_root.starts_with(&vault_root) {
        return Err(IndexDirectoryError::InvalidPath(
            IndexDirectoryPathError::IndexRootInsideVault,
        ));
    }
    if !data_directory.starts_with(&index_root) {
        return Err(IndexDirectoryError::InvalidPath(
            IndexDirectoryPathError::DataOutsideIndexRoot,
        ));
    }
    if !rebuild_directory.starts_with(&index_root) {
        return Err(IndexDirectoryError::InvalidPath(
            IndexDirectoryPathError::RebuildOutsideIndexRoot,
        ));
    }
    if paths_overlap(&data_directory, &vault_root) {
        return Err(IndexDirectoryError::InvalidPath(
            IndexDirectoryPathError::DataOverlapsVault,
        ));
    }
    if paths_overlap(&rebuild_directory, &vault_root) {
        return Err(IndexDirectoryError::InvalidPath(
            IndexDirectoryPathError::RebuildOverlapsVault,
        ));
    }
    ensure_existing_path_does_not_resolve_into_vault(
        &data_directory,
        &vault_root,
        IndexDirectoryPathError::DataOverlapsVault,
    )?;
    ensure_existing_path_does_not_resolve_into_vault(
        &rebuild_directory,
        &vault_root,
        IndexDirectoryPathError::RebuildOverlapsVault,
    )?;
    if data_directory == rebuild_directory {
        return Err(IndexDirectoryError::InvalidPath(
            IndexDirectoryPathError::DataEqualsRebuild,
        ));
    }

    Ok(IndexDirectoryPaths {
        vault_root,
        index_root,
        data_directory,
        rebuild_directory,
    })
}

fn remove_path(path: &Path) -> IndexDirectoryResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn normalize_path(path: &Path) -> IndexDirectoryResult<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(component.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(value) => normalized.push(value),
        }
    }
    Ok(normalized)
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
    left == right || left.starts_with(right) || right.starts_with(left)
}

fn ensure_no_vault_overlap(path: &Path, vault_root: &Path) -> Result<(), IndexDirectoryPathError> {
    if paths_overlap(path, vault_root) {
        return Err(IndexDirectoryPathError::DataOverlapsVault);
    }
    Ok(())
}

fn ensure_existing_path_does_not_resolve_into_vault(
    path: &Path,
    vault_root: &Path,
    error: IndexDirectoryPathError,
) -> IndexDirectoryResult<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(IndexDirectoryError::Io(error)),
    };
    if !metadata.file_type().is_symlink() {
        return Ok(());
    }

    let canonical = fs::canonicalize(path)?;
    let canonical_vault_root = fs::canonicalize(vault_root)?;
    if paths_overlap(&canonical, &canonical_vault_root) {
        return Err(IndexDirectoryError::InvalidPath(error));
    }
    Ok(())
}

impl From<std::io::Error> for IndexDirectoryError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
