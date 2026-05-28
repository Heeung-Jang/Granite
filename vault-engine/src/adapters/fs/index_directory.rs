use std::ffi::OsStr;
use std::fs;
use std::path::{Component, Path, PathBuf};

const ENGINE_OWNED_MARKER_FILE: &str = ".granite-engine-owned";
const ENGINE_OWNED_MARKER_CONTENT: &str = "granite vault-engine owned directory\n";

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
    MissingEngineOwnedMarker,
    UnexpectedIndexDirectoryEntry,
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

    let previous_exists = ensure_safe_replaceable_directory(
        &previous_directory,
        &paths.vault_root,
        IndexDirectoryPathError::DataOverlapsVault,
        ReplaceableDirectoryRole::IndexArtifacts,
    )?;
    let data_exists = ensure_safe_replaceable_directory(
        &paths.data_directory,
        &paths.vault_root,
        IndexDirectoryPathError::DataOverlapsVault,
        ReplaceableDirectoryRole::IndexArtifacts,
    )?;
    let rebuild_exists = ensure_safe_replaceable_directory(
        &paths.rebuild_directory,
        &paths.vault_root,
        IndexDirectoryPathError::RebuildOverlapsVault,
        ReplaceableDirectoryRole::IndexArtifacts,
    )?;
    if !rebuild_exists {
        return Err(IndexDirectoryError::Io(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "index rebuild directory does not exist",
        )));
    }

    if previous_exists {
        remove_path(&previous_directory)?;
    }

    let previous_data_removed = if data_exists {
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

    if ensure_safe_replaceable_directory(
        &previous_directory,
        &paths.vault_root,
        IndexDirectoryPathError::DataOverlapsVault,
        ReplaceableDirectoryRole::IndexArtifacts,
    )? {
        remove_path(&previous_directory)?;
    }

    Ok(IndexDirectoryCommit {
        data_directory: paths.data_directory,
        previous_data_removed,
    })
}

#[cfg(test)]
pub(crate) fn abort_index_rebuild(paths: &IndexDirectoryPaths) -> IndexDirectoryResult<()> {
    let paths = validate_paths(paths)?;
    if ensure_safe_replaceable_directory(
        &paths.rebuild_directory,
        &paths.vault_root,
        IndexDirectoryPathError::RebuildOverlapsVault,
        ReplaceableDirectoryRole::IndexArtifacts,
    )? {
        remove_path(&paths.rebuild_directory)?;
    }
    Ok(())
}

pub(crate) fn reset_pipeline_rebuild_directory(
    paths: &IndexDirectoryPaths,
) -> IndexDirectoryResult<()> {
    let paths = validate_paths(paths)?;
    reset_directory_with_role(
        &paths.rebuild_directory,
        &paths.vault_root,
        IndexDirectoryPathError::RebuildOverlapsVault,
        ReplaceableDirectoryRole::IndexArtifacts,
    )
}

pub(crate) fn reset_tantivy_rebuild_directory(
    paths: &IndexDirectoryPaths,
) -> IndexDirectoryResult<()> {
    let paths = validate_paths(paths)?;
    reset_directory_with_role(
        &paths.rebuild_directory.join("tantivy"),
        &paths.vault_root,
        IndexDirectoryPathError::RebuildOverlapsVault,
        ReplaceableDirectoryRole::TantivySubtree,
    )
}

#[cfg(test)]
pub(crate) fn reset_rebuild_directory(
    paths: &IndexDirectoryPaths,
    generation: u64,
    reason: &str,
) -> IndexDirectoryResult<()> {
    let paths = validate_paths(paths)?;
    reset_directory_with_role(
        &paths.rebuild_directory,
        &paths.vault_root,
        IndexDirectoryPathError::RebuildOverlapsVault,
        ReplaceableDirectoryRole::IndexArtifacts,
    )?;
    fs::write(
        paths.rebuild_directory.join("rebuild.json"),
        format!("{{\"generation\":{generation},\"reason\":\"{reason}\"}}\n"),
    )?;
    Ok(())
}

#[cfg(test)]
pub(crate) fn mark_engine_owned_for_test(path: &Path) -> IndexDirectoryResult<()> {
    fs::create_dir_all(path)?;
    write_engine_owned_marker(path)
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

#[derive(Debug, Clone, Copy)]
enum ReplaceableDirectoryRole {
    IndexArtifacts,
    TantivySubtree,
}

fn reset_directory_with_role(
    path: &Path,
    vault_root: &Path,
    overlap_error: IndexDirectoryPathError,
    role: ReplaceableDirectoryRole,
) -> IndexDirectoryResult<()> {
    if ensure_safe_replaceable_directory(path, vault_root, overlap_error, role)? {
        remove_path(path)?;
    }
    fs::create_dir_all(path)?;
    write_engine_owned_marker(path)?;
    Ok(())
}

fn ensure_safe_replaceable_directory(
    path: &Path,
    vault_root: &Path,
    overlap_error: IndexDirectoryPathError,
    role: ReplaceableDirectoryRole,
) -> IndexDirectoryResult<bool> {
    ensure_existing_path_does_not_resolve_into_vault(path, vault_root, overlap_error)?;
    ensure_replaceable_directory(path, role)
}

fn ensure_replaceable_directory(
    path: &Path,
    role: ReplaceableDirectoryRole,
) -> IndexDirectoryResult<bool> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if !metadata.is_dir() {
                return Err(IndexDirectoryError::InvalidPath(
                    IndexDirectoryPathError::MissingEngineOwnedMarker,
                ));
            }
            if matches!(role, ReplaceableDirectoryRole::IndexArtifacts)
                && !is_replaceable_index_artifact_directory(path)?
            {
                return Err(IndexDirectoryError::InvalidPath(
                    IndexDirectoryPathError::UnexpectedIndexDirectoryEntry,
                ));
            }
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(IndexDirectoryError::Io(error)),
    }
}

fn is_replaceable_index_artifact_directory(path: &Path) -> IndexDirectoryResult<bool> {
    if has_engine_owned_marker(path)? {
        return Ok(true);
    }
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        if !is_known_index_artifact_entry(&entry)? {
            return Ok(false);
        }
    }
    Ok(true)
}

fn has_engine_owned_marker(path: &Path) -> IndexDirectoryResult<bool> {
    match fs::symlink_metadata(path.join(ENGINE_OWNED_MARKER_FILE)) {
        Ok(metadata) => {
            if metadata.is_file() {
                Ok(true)
            } else {
                Err(IndexDirectoryError::InvalidPath(
                    IndexDirectoryPathError::MissingEngineOwnedMarker,
                ))
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(IndexDirectoryError::Io(error)),
    }
}

fn is_known_index_artifact_entry(entry: &fs::DirEntry) -> IndexDirectoryResult<bool> {
    let name = entry.file_name();
    let file_type = entry.file_type()?;
    let is_known_file = name == OsStr::new(ENGINE_OWNED_MARKER_FILE)
        || name == OsStr::new("metadata.sqlite")
        || name == OsStr::new("metadata.sqlite-wal")
        || name == OsStr::new("metadata.sqlite-shm")
        || name == OsStr::new("indexing-queue.sqlite")
        || name == OsStr::new("indexing-queue.sqlite-wal")
        || name == OsStr::new("indexing-queue.sqlite-shm")
        || name == OsStr::new("rebuild.json");
    if is_known_file {
        return Ok(file_type.is_file());
    }
    if name == OsStr::new("tantivy") {
        return Ok(file_type.is_dir());
    }
    Ok(false)
}

fn write_engine_owned_marker(path: &Path) -> IndexDirectoryResult<()> {
    fs::write(
        path.join(ENGINE_OWNED_MARKER_FILE),
        ENGINE_OWNED_MARKER_CONTENT,
    )?;
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
    let Some(existing_path) = nearest_existing_path(path)? else {
        return Ok(());
    };
    let canonical = fs::canonicalize(existing_path)?;
    let canonical_vault_root = fs::canonicalize(vault_root)?;
    if path_inside_or_equal(&canonical, &canonical_vault_root) {
        return Err(IndexDirectoryError::InvalidPath(error));
    }
    Ok(())
}

fn nearest_existing_path(path: &Path) -> IndexDirectoryResult<Option<PathBuf>> {
    let mut current = Some(path);
    while let Some(candidate) = current {
        match fs::symlink_metadata(candidate) {
            Ok(_) => return Ok(Some(candidate.to_path_buf())),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                current = candidate.parent();
            }
            Err(error) => return Err(IndexDirectoryError::Io(error)),
        }
    }
    Ok(None)
}

fn path_inside_or_equal(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

impl From<std::io::Error> for IndexDirectoryError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}
