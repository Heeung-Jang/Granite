use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::adapters::fs::path_resolver::VaultRoot;
use crate::adapters::fs::scanner::{ScanError, scan_vault};
use crate::adapters::sqlite::{FileIndexStatus, FileRecord, MetadataStore, MetadataStoreError};
use crate::core::paths::{PathError, normalize_relative_path};
use crate::core::scan::ScanEntryKind;

use super::read_vault::expected_read_schema_metadata;

const STORED_MARKDOWN_PAGE_SIZE: usize = 1024;

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ReadIndexFreshnessSummary {
    pub stale: bool,
    pub unchanged: u64,
    pub created: u64,
    pub modified: u64,
    pub deleted: u64,
    pub incomplete: u64,
    pub current_markdown_files: u64,
    pub indexed_markdown_files: u64,
    pub current_rows_scanned: u64,
    pub stored_rows_read: u64,
    pub scan_micros: u64,
    pub sqlite_read_micros: u64,
    pub compare_micros: u64,
    pub elapsed_micros: u64,
    pub rebuild_scheduled: bool,
}

#[derive(Debug)]
pub enum ReadIndexFreshnessError {
    InvalidInput(&'static str),
    Path(PathError),
    Scan(ScanError),
    Metadata(MetadataStoreError),
}

pub type ReadIndexFreshnessResult<T> = Result<T, ReadIndexFreshnessError>;

pub fn check_read_index_freshness(
    vault_path: &Path,
    metadata_path: &Path,
) -> ReadIndexFreshnessResult<ReadIndexFreshnessSummary> {
    if vault_path.as_os_str().is_empty() {
        return Err(ReadIndexFreshnessError::InvalidInput("vault_path"));
    }
    if metadata_path.as_os_str().is_empty() {
        return Err(ReadIndexFreshnessError::InvalidInput("metadata_path"));
    }
    if !metadata_path.is_file() {
        return Err(ReadIndexFreshnessError::InvalidInput("metadata_path"));
    }

    let started = Instant::now();
    let root = VaultRoot::open(vault_path).map_err(ReadIndexFreshnessError::Path)?;
    let metadata_canonical = std::fs::canonicalize(metadata_path)
        .map_err(|_| ReadIndexFreshnessError::InvalidInput("metadata_path"))?;
    if metadata_canonical.starts_with(root.canonical_root()) {
        return Err(ReadIndexFreshnessError::InvalidInput("metadata_path"));
    }

    let scan_started = Instant::now();
    let scan = scan_vault(&root).map_err(ReadIndexFreshnessError::Scan)?;
    let scan_micros = duration_micros_nonzero(scan_started.elapsed());

    let mut current_by_id = scan
        .entries
        .iter()
        .filter(|entry| entry.kind == ScanEntryKind::Markdown)
        .map(|entry| {
            let record = FileRecord::from_scan_entry(entry, 0);
            (record.file_id.clone(), record)
        })
        .collect::<HashMap<_, _>>();

    let sqlite_started = Instant::now();
    let expected = expected_read_schema_metadata();
    let (metadata, _) = MetadataStore::open_existing_read_only(&metadata_canonical, &expected)
        .map_err(ReadIndexFreshnessError::Metadata)?;
    let mut after_relative_path: Option<String> = None;
    let mut stored_rows = Vec::new();
    loop {
        let page = metadata
            .list_markdown_files_after(after_relative_path.as_deref(), STORED_MARKDOWN_PAGE_SIZE)
            .map_err(ReadIndexFreshnessError::Metadata)?;
        if page.is_empty() {
            break;
        }
        after_relative_path = page
            .last()
            .map(|record| record.relative_path.to_string_lossy().to_string());
        stored_rows.extend(page);
    }
    let sqlite_read_micros = duration_micros_nonzero(sqlite_started.elapsed());

    let compare_started = Instant::now();
    let mut summary = ReadIndexFreshnessSummary {
        current_markdown_files: scan.markdown_files as u64,
        indexed_markdown_files: stored_rows.len() as u64,
        current_rows_scanned: current_by_id.len() as u64,
        stored_rows_read: stored_rows.len() as u64,
        scan_micros,
        sqlite_read_micros,
        ..Default::default()
    };

    for stored in stored_rows {
        if stored_relative_path_is_unsafe(&stored.relative_path) {
            summary.deleted += 1;
            continue;
        }

        match current_by_id.remove(&stored.file_id) {
            Some(current) if file_metadata_matches(&stored, &current) => {
                if stored.status == FileIndexStatus::SearchIndexed {
                    summary.unchanged += 1;
                } else {
                    summary.incomplete += 1;
                }
            }
            Some(_) => {
                summary.modified += 1;
            }
            None => {
                summary.deleted += 1;
            }
        }
    }

    summary.created = current_by_id.len() as u64;
    summary.compare_micros = duration_micros_nonzero(compare_started.elapsed());
    summary.elapsed_micros = duration_micros_nonzero(started.elapsed());
    summary.stale = summary.created > 0
        || summary.modified > 0
        || summary.deleted > 0
        || summary.incomplete > 0;
    Ok(summary)
}

fn stored_relative_path_is_unsafe(path: &Path) -> bool {
    let value = path.to_string_lossy();
    match normalize_relative_path(&value) {
        Ok(normalized) => normalized != path,
        Err(_) => true,
    }
}

fn file_metadata_matches(stored: &FileRecord, current: &FileRecord) -> bool {
    stored.relative_path == current.relative_path
        && stored.kind == current.kind
        && stored.size_bytes == current.size_bytes
        && system_time_to_unix_ms(stored.modified) == system_time_to_unix_ms(current.modified)
        && stored.file_identity == current.file_identity
}

fn system_time_to_unix_ms(time: Option<SystemTime>) -> Option<u128> {
    time.and_then(|value| {
        value
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|duration| duration.as_millis())
    })
}

fn duration_micros_nonzero(duration: std::time::Duration) -> u64 {
    duration.as_micros().max(1) as u64
}

impl fmt::Display for ReadIndexFreshnessError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput(field) => write!(formatter, "invalid freshness input: {field}"),
            Self::Path(error) => write!(formatter, "freshness path error: {error}"),
            Self::Scan(error) => write!(formatter, "freshness scan failed: {error:?}"),
            Self::Metadata(error) => write!(formatter, "freshness metadata failed: {error}"),
        }
    }
}

impl std::error::Error for ReadIndexFreshnessError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::sqlite::{FileMetadataRecords, MetadataStore};
    use crate::core::metadata::IndexedFileRecords;
    use crate::use_cases::read_vault::expected_read_schema_metadata_for_generation;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::symlink;
    use std::path::PathBuf;
    use tempfile::tempdir;

    #[test]
    fn detects_clean_index() {
        let fixture = Fixture::new(&[("Notes/Home.md", "# Home")]);
        fixture.write_index(|record| record.mark_search_indexed());

        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();

        assert!(!summary.stale);
        assert_eq!(summary.unchanged, 1);
        assert_eq!(summary.current_markdown_files, 1);
        assert_eq!(summary.indexed_markdown_files, 1);
    }

    #[test]
    fn detects_created_markdown() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        fixture.write_index(|record| record.mark_search_indexed());
        fs::write(fixture.vault.path().join("New.md"), "# New").unwrap();

        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();

        assert!(summary.stale);
        assert_eq!(summary.created, 1);
    }

    #[test]
    fn detects_deleted_markdown() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        fixture.write_index(|record| record.mark_search_indexed());
        fs::remove_file(fixture.vault.path().join("Home.md")).unwrap();

        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();

        assert!(summary.stale);
        assert_eq!(summary.deleted, 1);
    }

    #[test]
    fn detects_modified_markdown() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        fixture.write_index(|record| record.mark_search_indexed());
        fs::write(fixture.vault.path().join("Home.md"), "# Home updated").unwrap();

        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();

        assert!(summary.stale);
        assert_eq!(summary.modified, 1);
    }

    #[test]
    fn detects_incomplete_markdown() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        fixture.write_index(|_record| {});

        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();

        assert!(summary.stale);
        assert_eq!(summary.incomplete, 1);
    }

    #[test]
    fn ignores_non_markdown_changes() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        fixture.write_index(|record| record.mark_search_indexed());
        fs::write(fixture.vault.path().join("Image.png"), "not really png").unwrap();

        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();

        assert!(!summary.stale);
        assert_eq!(summary.created, 0);
    }

    #[test]
    fn treats_invalid_stored_path_as_stale_without_touching_vault() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        fixture.write_custom_records(vec![{
            let mut record = fixture.file_record("Home.md");
            record.relative_path = PathBuf::from("../outside.md");
            record.mark_search_indexed();
            record
        }]);

        let before = fs::read_to_string(fixture.vault.path().join("Home.md")).unwrap();
        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();
        let after = fs::read_to_string(fixture.vault.path().join("Home.md")).unwrap();

        assert!(summary.stale);
        assert_eq!(summary.deleted, 1);
        assert_eq!(summary.created, 1);
        assert_eq!(before, after);
    }

    #[cfg(unix)]
    #[test]
    fn does_not_traverse_symlink_directories() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        let outside = tempdir().unwrap();
        fs::write(outside.path().join("Outside.md"), "# Outside").unwrap();
        symlink(outside.path(), fixture.vault.path().join("Linked")).unwrap();
        fixture.write_index(|record| record.mark_search_indexed());

        let summary =
            check_read_index_freshness(fixture.vault.path(), &fixture.metadata_path).unwrap();

        assert!(!summary.stale);
        assert_eq!(summary.current_markdown_files, 1);
    }

    #[test]
    fn rejects_metadata_inside_vault() {
        let fixture = Fixture::new(&[("Home.md", "# Home")]);
        let metadata_path = fixture.vault.path().join("metadata.sqlite");
        fs::write(&metadata_path, "").unwrap();

        let error = check_read_index_freshness(fixture.vault.path(), &metadata_path).unwrap_err();

        assert!(matches!(
            error,
            ReadIndexFreshnessError::InvalidInput("metadata_path")
        ));
    }

    struct Fixture {
        vault: tempfile::TempDir,
        _support: tempfile::TempDir,
        metadata_path: PathBuf,
    }

    impl Fixture {
        fn new(files: &[(&str, &str)]) -> Self {
            let vault = tempdir().unwrap();
            for (relative_path, contents) in files {
                let path = vault.path().join(relative_path);
                if let Some(parent) = path.parent() {
                    fs::create_dir_all(parent).unwrap();
                }
                fs::write(path, contents).unwrap();
            }
            let support = tempdir().unwrap();
            let metadata_path = support.path().join("metadata.sqlite");
            Self {
                vault,
                _support: support,
                metadata_path,
            }
        }

        fn write_index(&self, mutate: impl Fn(&mut FileRecord)) {
            let root = VaultRoot::open(self.vault.path()).unwrap();
            let scan = scan_vault(&root).unwrap();
            let mut records = scan
                .entries
                .iter()
                .filter(|entry| entry.kind == ScanEntryKind::Markdown)
                .map(|entry| {
                    let mut file = FileRecord::from_scan_entry(entry, 1);
                    mutate(&mut file);
                    IndexedFileRecords {
                        file,
                        links: Vec::new(),
                        tags: Vec::new(),
                        properties: Vec::new(),
                        headings: Vec::new(),
                        attachments: Vec::new(),
                    }
                })
                .collect::<Vec<_>>();
            records.sort_by(|left, right| left.file.relative_path.cmp(&right.file.relative_path));
            self.write_records(records);
        }

        fn write_custom_records(&self, files: Vec<FileRecord>) {
            let records = files
                .into_iter()
                .map(|file| IndexedFileRecords {
                    file,
                    links: Vec::new(),
                    tags: Vec::new(),
                    properties: Vec::new(),
                    headings: Vec::new(),
                    attachments: Vec::new(),
                })
                .collect::<Vec<_>>();
            self.write_records(records);
        }

        fn write_records(&self, records: Vec<FileMetadataRecords>) {
            let mut store = MetadataStore::open(
                &self.metadata_path,
                &expected_read_schema_metadata_for_generation(1),
            )
            .unwrap();
            store.replace_file_records_batch(&records).unwrap();
        }

        fn file_record(&self, relative_path: &str) -> FileRecord {
            let root = VaultRoot::open(self.vault.path()).unwrap();
            let scan = scan_vault(&root).unwrap();
            let entry = scan
                .entries
                .iter()
                .find(|entry| entry.relative_path == PathBuf::from(relative_path))
                .unwrap();
            FileRecord::from_scan_entry(entry, 1)
        }
    }
}
