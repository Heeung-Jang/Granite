use std::fs;
use std::path::{Component, Path, PathBuf};

use crate::index_rebuild::{
    IndexRebuildCommit, IndexRebuildError, IndexRebuildPathError, IndexRebuildPaths,
    IndexRebuildReason, IndexRebuildResult,
};

pub(crate) fn commit_index_rebuild(
    paths: &IndexRebuildPaths,
) -> IndexRebuildResult<IndexRebuildCommit> {
    let paths = validate_paths(paths)?;
    let previous_directory = paths.index_root.join("previous-data");
    ensure_no_vault_overlap(&previous_directory, &paths.vault_root)
        .map_err(IndexRebuildError::InvalidPath)?;
    ensure_existing_path_does_not_resolve_into_vault(
        &previous_directory,
        &paths.vault_root,
        IndexRebuildPathError::DataOverlapsVault,
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
            return Err(IndexRebuildError::Io(error));
        }
    }

    if previous_directory.exists() {
        remove_path(&previous_directory)?;
    }

    Ok(IndexRebuildCommit {
        data_directory: paths.data_directory,
        previous_data_removed,
    })
}

pub(crate) fn abort_index_rebuild(paths: &IndexRebuildPaths) -> IndexRebuildResult<()> {
    let paths = validate_paths(paths)?;
    if paths.rebuild_directory.exists() {
        remove_path(&paths.rebuild_directory)?;
    }
    Ok(())
}

pub(crate) fn reset_rebuild_directory(
    rebuild_directory: &Path,
    generation: u64,
    reason: IndexRebuildReason,
) -> IndexRebuildResult<()> {
    if rebuild_directory.exists() {
        remove_path(rebuild_directory)?;
    }
    fs::create_dir_all(rebuild_directory)?;
    fs::write(
        rebuild_directory.join("rebuild.json"),
        format!(
            "{{\"generation\":{generation},\"reason\":\"{}\"}}\n",
            reason.as_str()
        ),
    )?;
    Ok(())
}

pub(crate) fn validate_paths(paths: &IndexRebuildPaths) -> IndexRebuildResult<IndexRebuildPaths> {
    let vault_root = normalize_path(&paths.vault_root)?;
    let index_root = normalize_path(&paths.index_root)?;
    let data_directory = normalize_path(&paths.data_directory)?;
    let rebuild_directory = normalize_path(&paths.rebuild_directory)?;

    if index_root == vault_root || index_root.starts_with(&vault_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::IndexRootInsideVault,
        ));
    }
    if !data_directory.starts_with(&index_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::DataOutsideIndexRoot,
        ));
    }
    if !rebuild_directory.starts_with(&index_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::RebuildOutsideIndexRoot,
        ));
    }
    if paths_overlap(&data_directory, &vault_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::DataOverlapsVault,
        ));
    }
    if paths_overlap(&rebuild_directory, &vault_root) {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::RebuildOverlapsVault,
        ));
    }
    ensure_existing_path_does_not_resolve_into_vault(
        &data_directory,
        &vault_root,
        IndexRebuildPathError::DataOverlapsVault,
    )?;
    ensure_existing_path_does_not_resolve_into_vault(
        &rebuild_directory,
        &vault_root,
        IndexRebuildPathError::RebuildOverlapsVault,
    )?;
    if data_directory == rebuild_directory {
        return Err(IndexRebuildError::InvalidPath(
            IndexRebuildPathError::DataEqualsRebuild,
        ));
    }

    Ok(IndexRebuildPaths {
        vault_root,
        index_root,
        data_directory,
        rebuild_directory,
    })
}

fn remove_path(path: &Path) -> IndexRebuildResult<()> {
    let metadata = fs::symlink_metadata(path)?;
    if metadata.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(())
}

fn normalize_path(path: &Path) -> IndexRebuildResult<PathBuf> {
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

fn ensure_no_vault_overlap(path: &Path, vault_root: &Path) -> Result<(), IndexRebuildPathError> {
    if paths_overlap(path, vault_root) {
        return Err(IndexRebuildPathError::DataOverlapsVault);
    }
    Ok(())
}

fn ensure_existing_path_does_not_resolve_into_vault(
    path: &Path,
    vault_root: &Path,
    error: IndexRebuildPathError,
) -> IndexRebuildResult<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(IndexRebuildError::Io(error)),
    };
    if !metadata.file_type().is_symlink() {
        return Ok(());
    }

    let canonical = fs::canonicalize(path)?;
    let canonical_vault_root = fs::canonicalize(vault_root)?;
    if paths_overlap(&canonical, &canonical_vault_root) {
        return Err(IndexRebuildError::InvalidPath(error));
    }
    Ok(())
}
