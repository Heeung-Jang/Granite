use std::fs;
use std::path::{Path, PathBuf};

pub use crate::core::files::FileIdentity;
pub use crate::core::paths::{
    PathError, ResolvedVaultPath, SymlinkPolicy, lookup_key, normalize_relative_path,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VaultRoot {
    canonical_root: PathBuf,
    symlink_policy: SymlinkPolicy,
}

impl VaultRoot {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, PathError> {
        let path = path.as_ref();
        let metadata =
            fs::metadata(path).map_err(|_| PathError::MissingRoot(path.to_path_buf()))?;
        if !metadata.is_dir() {
            return Err(PathError::RootNotDirectory(path.to_path_buf()));
        }

        let canonical_root =
            fs::canonicalize(path).map_err(|_| PathError::MissingRoot(path.to_path_buf()))?;
        Ok(Self {
            canonical_root,
            symlink_policy: SymlinkPolicy::RejectEscapes,
        })
    }

    pub fn canonical_root(&self) -> &Path {
        &self.canonical_root
    }

    pub fn symlink_policy(&self) -> SymlinkPolicy {
        self.symlink_policy
    }

    pub fn resolve_existing_relative(
        &self,
        input: impl AsRef<str>,
    ) -> Result<ResolvedVaultPath, PathError> {
        let relative_path = normalize_relative_path(input.as_ref())?;
        let absolute_path = self.canonical_root.join(&relative_path);
        let canonical_path = fs::canonicalize(&absolute_path)
            .map_err(|_| PathError::MissingPath(relative_path.clone()))?;

        if !canonical_path.starts_with(&self.canonical_root) {
            return Err(PathError::SymlinkEscape {
                input: relative_path,
                canonical: canonical_path,
            });
        }

        let metadata = fs::metadata(&canonical_path)
            .map_err(|_| PathError::MissingPath(canonical_path.clone()))?;

        Ok(ResolvedVaultPath {
            relative_path,
            absolute_path,
            canonical_path,
            file_identity: FileIdentity::from_metadata(&metadata),
        })
    }
}

impl FileIdentity {
    #[cfg(unix)]
    pub fn from_metadata(metadata: &fs::Metadata) -> Self {
        use std::os::unix::fs::MetadataExt;

        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
        }
    }

    #[cfg(not(unix))]
    pub fn from_metadata(_metadata: &fs::Metadata) -> Self {
        Self {
            device: 0,
            inode: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use tempfile::tempdir;

    #[test]
    fn opens_canonical_vault_root() {
        let dir = tempdir().expect("tempdir");
        let root = VaultRoot::open(dir.path()).expect("root");

        assert!(root.canonical_root().is_absolute());
        assert_eq!(root.symlink_policy(), SymlinkPolicy::RejectEscapes);
    }

    #[test]
    fn normalizes_safe_relative_paths() {
        assert_eq!(
            normalize_relative_path("./Folder/../Home.md").expect("normalized"),
            PathBuf::from("Home.md")
        );
        assert_eq!(
            normalize_relative_path("Folder/Target.md").expect("normalized"),
            PathBuf::from("Folder/Target.md")
        );
    }

    #[test]
    fn rejects_parent_escape() {
        assert_eq!(
            normalize_relative_path("../outside.md").expect_err("escape"),
            PathError::OutsideVault(PathBuf::from("../outside.md"))
        );
    }

    #[test]
    fn rejects_tilde_absolute_nul_and_url_schemes() {
        assert_eq!(
            normalize_relative_path("~/vault.md").expect_err("tilde"),
            PathError::TildePrefix
        );
        assert!(matches!(
            normalize_relative_path("/etc/passwd").expect_err("absolute"),
            PathError::AbsolutePath(_)
        ));
        assert_eq!(
            normalize_relative_path("bad\0path.md").expect_err("nul"),
            PathError::ContainsNul
        );
        assert_eq!(
            normalize_relative_path("javascript:alert(1)").expect_err("url"),
            PathError::UrlScheme("javascript".to_string())
        );
        assert_eq!(
            normalize_relative_path("file:///etc/passwd").expect_err("url"),
            PathError::UrlScheme("file".to_string())
        );
    }

    #[test]
    fn lookup_key_catches_case_and_unicode_collisions() {
        assert_eq!(lookup_key("Folder/NOTE.md"), lookup_key("folder/note.md"));
        assert_eq!(lookup_key("Résumé/INDEX.md"), lookup_key("résumé/index.md"));
    }

    #[test]
    fn resolves_existing_path_and_file_identity() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir(dir.path().join("Folder")).expect("folder");
        fs::write(dir.path().join("Folder").join("Note.md"), "# Note").expect("note");
        let root = VaultRoot::open(dir.path()).expect("root");

        let resolved = root
            .resolve_existing_relative("Folder/Note.md")
            .expect("resolved");

        assert_eq!(resolved.relative_path, PathBuf::from("Folder/Note.md"));
        assert!(resolved.canonical_path.starts_with(root.canonical_root()));
        assert!(resolved.file_identity.inode > 0);
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlink_escape_attempts() {
        let vault = tempdir().expect("vault tempdir");
        let outside = tempdir().expect("outside tempdir");
        fs::write(outside.path().join("secret.md"), "# Secret").expect("secret");
        symlink(
            outside.path().join("secret.md"),
            vault.path().join("secret-link.md"),
        )
        .expect("symlink");
        let root = VaultRoot::open(vault.path()).expect("root");

        let error = root
            .resolve_existing_relative("secret-link.md")
            .expect_err("symlink escape");

        assert!(matches!(error, PathError::SymlinkEscape { .. }));
    }
}
