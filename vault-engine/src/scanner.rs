pub use crate::adapters::fs::scanner::{
    ScanEntry, ScanEntryKind, ScanError, ScanSummary, classify_file, scan_vault,
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::VaultRoot;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};
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
