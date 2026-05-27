use std::ffi::OsStr;
use std::fs;
use std::path::{Path, PathBuf};

pub use crate::core::scan::{ScanEntry, ScanEntryKind, ScanSummary, classify_file};
use crate::paths::{FileIdentity, VaultRoot};

#[derive(Debug)]
pub enum ScanError {
    ReadDir {
        path: PathBuf,
        kind: std::io::ErrorKind,
    },
    Metadata {
        path: PathBuf,
        kind: std::io::ErrorKind,
    },
    OutsideVault(PathBuf),
}

pub fn scan_vault(root: &VaultRoot) -> Result<ScanSummary, ScanError> {
    let mut scanner = Scanner {
        root: root.canonical_root().to_path_buf(),
        summary: ScanSummary {
            entries: Vec::new(),
            markdown_files: 0,
            attachment_files: 0,
            other_files: 0,
            skipped_directories: 0,
            skipped_symlinks: 0,
        },
    };
    scanner.scan_directory(root.canonical_root())?;
    scanner.summary.entries.sort_by(|left, right| {
        left.relative_path
            .to_string_lossy()
            .cmp(&right.relative_path.to_string_lossy())
    });
    Ok(scanner.summary)
}

struct Scanner {
    root: PathBuf,
    summary: ScanSummary,
}

impl Scanner {
    fn scan_directory(&mut self, directory: &Path) -> Result<(), ScanError> {
        let entries = fs::read_dir(directory).map_err(|error| ScanError::ReadDir {
            path: directory.to_path_buf(),
            kind: error.kind(),
        })?;

        for entry in entries {
            let entry = entry.map_err(|error| ScanError::ReadDir {
                path: directory.to_path_buf(),
                kind: error.kind(),
            })?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path).map_err(|error| ScanError::Metadata {
                path: path.clone(),
                kind: error.kind(),
            })?;
            let file_type = metadata.file_type();

            if file_type.is_symlink() {
                self.summary.skipped_symlinks += 1;
                continue;
            }

            if file_type.is_dir() {
                if is_ignored_directory(&path) {
                    self.summary.skipped_directories += 1;
                    continue;
                }
                self.scan_directory(&path)?;
                continue;
            }

            if !file_type.is_file() {
                continue;
            }

            self.push_file(path, metadata)?;
        }

        Ok(())
    }

    fn push_file(&mut self, path: PathBuf, metadata: fs::Metadata) -> Result<(), ScanError> {
        let relative_path = path
            .strip_prefix(&self.root)
            .map_err(|_| ScanError::OutsideVault(path.clone()))?
            .to_path_buf();
        let kind = classify_file(&path);

        match kind {
            ScanEntryKind::Markdown => self.summary.markdown_files += 1,
            ScanEntryKind::Attachment => self.summary.attachment_files += 1,
            ScanEntryKind::Other => self.summary.other_files += 1,
        }

        self.summary.entries.push(ScanEntry {
            relative_path,
            kind,
            size_bytes: metadata.len(),
            modified: metadata.modified().ok(),
            file_identity: FileIdentity::from_metadata(&metadata),
        });

        Ok(())
    }
}

fn is_ignored_directory(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(OsStr::to_str),
        Some(".obsidian" | ".git" | ".worktrees" | ".native-markdown-index")
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use tempfile::tempdir;

    #[test]
    fn classifies_markdown_attachments_and_other_files() {
        assert_eq!(classify_file(Path::new("note.md")), ScanEntryKind::Markdown);
        assert_eq!(
            classify_file(Path::new("note.MARKDOWN")),
            ScanEntryKind::Markdown
        );
        assert_eq!(
            classify_file(Path::new("image.svg")),
            ScanEntryKind::Attachment
        );
        assert_eq!(classify_file(Path::new("data.json")), ScanEntryKind::Other);
    }

    #[test]
    fn scans_without_following_ignored_directories_or_symlinks() {
        let dir = tempdir().expect("tempdir");
        fs::create_dir_all(dir.path().join(".obsidian")).expect("obsidian");
        fs::create_dir_all(dir.path().join("notes")).expect("notes");
        fs::write(dir.path().join(".obsidian").join("ignored.md"), "# ignored").expect("ignored");
        fs::write(dir.path().join("notes").join("note.md"), "# Note").expect("note");
        fs::write(dir.path().join("notes").join("diagram.svg"), "<svg/>").expect("svg");
        fs::write(dir.path().join("notes").join("data.json"), "{}").expect("json");
        #[cfg(unix)]
        symlink(".", dir.path().join("loop")).expect("symlink loop");

        let root = VaultRoot::open(dir.path()).expect("root");
        let summary = scan_vault(&root).expect("scan");

        assert_eq!(summary.markdown_files, 1);
        assert_eq!(summary.attachment_files, 1);
        assert_eq!(summary.other_files, 1);
        assert_eq!(summary.skipped_directories, 1);
        #[cfg(unix)]
        assert_eq!(summary.skipped_symlinks, 1);
        assert!(
            summary
                .entries
                .iter()
                .all(|entry| !entry.relative_path.starts_with(".obsidian"))
        );
    }

    #[test]
    fn scans_compatibility_fixture_vault() {
        let root_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault");
        let root = VaultRoot::open(root_path).expect("root");
        let summary = scan_vault(&root).expect("scan");

        assert_eq!(summary.markdown_files, 6);
        assert_eq!(summary.attachment_files, 2);
        assert_eq!(summary.skipped_directories, 1);
    }

    #[test]
    fn adversarial_fixture_excludes_obsidian_plugin_payloads() {
        let root_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("adversarial-vault");
        let root = VaultRoot::open(root_path).expect("root");
        let summary = scan_vault(&root).expect("scan");
        let scanned_paths = summary
            .entries
            .iter()
            .map(|entry| entry.relative_path.to_string_lossy().to_string())
            .collect::<Vec<_>>();

        assert!(summary.skipped_directories >= 1);
        assert!(
            !scanned_paths
                .iter()
                .any(|path| path.starts_with(".obsidian"))
        );
        assert!(
            !scanned_paths
                .iter()
                .any(|path| path.contains("fake-plugin") || path.contains("unsafe.css"))
        );
    }

    #[ignore]
    #[test]
    fn scans_real_benchmark_vault_metadata_only() {
        let root = VaultRoot::open("/Users/heeung/Documents/Codex Vault").expect("root");
        let summary = scan_vault(&root).expect("scan");

        assert_eq!(summary.markdown_files, 64_306);
    }
}
