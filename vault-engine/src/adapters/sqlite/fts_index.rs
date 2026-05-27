use std::fmt;
use std::path::Path;
#[cfg(test)]
use std::time::{Duration, Instant};

use rusqlite::{Connection, params};

#[cfg(test)]
pub use crate::core::search::SearchMeasurement;
pub use crate::core::search::{SearchDocument, SearchResult};

pub struct SqliteFtsIndex {
    connection: Connection,
}

#[derive(Debug)]
pub enum SqliteFtsError {
    Sqlite(rusqlite::Error),
    EmptyQuery,
}

pub type SqliteFtsResult<T> = Result<T, SqliteFtsError>;

impl SqliteFtsIndex {
    pub fn open(path: impl AsRef<Path>) -> SqliteFtsResult<Self> {
        Self::from_connection(Connection::open(path)?)
    }

    #[cfg(test)]
    pub fn open_in_memory() -> SqliteFtsResult<Self> {
        Self::from_connection(Connection::open_in_memory()?)
    }

    fn from_connection(connection: Connection) -> SqliteFtsResult<Self> {
        connection.execute_batch(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS search_documents (
                rowid INTEGER PRIMARY KEY,
                file_id TEXT NOT NULL UNIQUE,
                path TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS search_documents_fts USING fts5(
                path,
                title,
                body,
                content='search_documents',
                content_rowid='rowid',
                tokenize='unicode61',
                prefix='2 3 4'
            );
            ",
        )?;
        Ok(Self { connection })
    }

    pub fn upsert_document(&mut self, document: &SearchDocument) -> SqliteFtsResult<()> {
        self.connection.execute(
            "INSERT INTO search_documents (file_id, path, title, body)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(file_id) DO UPDATE SET
                path = excluded.path,
                title = excluded.title,
                body = excluded.body",
            params![
                &document.file_id,
                &document.path,
                &document.title,
                &document.body
            ],
        )?;
        Ok(())
    }

    pub fn rebuild(&self) -> SqliteFtsResult<()> {
        self.connection.execute(
            "INSERT INTO search_documents_fts(search_documents_fts) VALUES('rebuild')",
            [],
        )?;
        Ok(())
    }

    pub fn optimize(&self) -> SqliteFtsResult<()> {
        self.connection.execute(
            "INSERT INTO search_documents_fts(search_documents_fts) VALUES('optimize')",
            [],
        )?;
        Ok(())
    }

    pub fn integrity_check(&self) -> SqliteFtsResult<()> {
        self.connection.execute(
            "INSERT INTO search_documents_fts(search_documents_fts) VALUES('integrity-check')",
            [],
        )?;
        Ok(())
    }

    pub fn search(&self, query: &str, limit: usize) -> SqliteFtsResult<Vec<SearchResult>> {
        let Some(match_query) = safe_match_query(query) else {
            return Err(SqliteFtsError::EmptyQuery);
        };
        let limit = limit.clamp(1, 100) as i64;
        let mut statement = self.connection.prepare(
            "SELECT d.file_id,
                    d.path,
                    d.title,
                    bm25(search_documents_fts, 2.0, 5.0, 1.0) AS rank,
                    snippet(search_documents_fts, 2, '[', ']', '...', 12) AS snippet
             FROM search_documents_fts
             JOIN search_documents d ON d.rowid = search_documents_fts.rowid
             WHERE search_documents_fts MATCH ?1
             ORDER BY rank
             LIMIT ?2",
        )?;

        let rows = statement.query_map(params![match_query, limit], |row| {
            Ok(SearchResult {
                file_id: row.get(0)?,
                path: row.get(1)?,
                title: row.get(2)?,
                rank: row.get(3)?,
                snippet: row.get(4)?,
            })
        })?;

        rows.collect::<Result<Vec<_>, _>>().map_err(Into::into)
    }

    #[cfg(test)]
    pub fn measure_queries(
        &self,
        queries: &[String],
        limit: usize,
    ) -> SqliteFtsResult<SearchMeasurement> {
        let mut durations = Vec::with_capacity(queries.len());
        for query in queries {
            let start = Instant::now();
            let _ = self.search(query, limit);
            durations.push(start.elapsed());
        }
        durations.sort();

        Ok(SearchMeasurement {
            sample_count: queries.len(),
            p95: percentile_duration(&durations, 95),
            index_size_bytes: self.estimated_size_bytes()?,
        })
    }

    pub fn estimated_size_bytes(&self) -> SqliteFtsResult<u64> {
        let page_count = self
            .connection
            .pragma_query_value(None, "page_count", |row| row.get::<_, i64>(0))?;
        let page_size = self
            .connection
            .pragma_query_value(None, "page_size", |row| row.get::<_, i64>(0))?;
        Ok((page_count * page_size) as u64)
    }

    #[cfg(test)]
    pub fn document_count(&self) -> SqliteFtsResult<usize> {
        self.connection
            .query_row("SELECT COUNT(*) FROM search_documents", [], |row| {
                row.get::<_, i64>(0)
            })
            .map(|count| count as usize)
            .map_err(Into::into)
    }
}

impl fmt::Display for SqliteFtsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(error) => write!(formatter, "sqlite fts error: {error}"),
            Self::EmptyQuery => write!(formatter, "search query is empty after sanitization"),
        }
    }
}

impl std::error::Error for SqliteFtsError {}

impl From<rusqlite::Error> for SqliteFtsError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

pub fn safe_match_query(input: &str) -> Option<String> {
    let bounded = input.chars().take(128).collect::<String>();
    let terms = bounded
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|term| !term.is_empty())
        .take(8)
        .map(|term| format!("\"{}\"", term.replace('"', "\"\"")))
        .collect::<Vec<_>>();

    (!terms.is_empty()).then(|| terms.join(" AND "))
}

#[cfg(test)]
fn percentile_duration(values: &[Duration], percentile: usize) -> Duration {
    if values.is_empty() {
        return Duration::ZERO;
    }
    let index = ((values.len() * percentile).div_ceil(100)).saturating_sub(1);
    values[index.min(values.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::markdown_parser::parse_markdown;
    use crate::core::paths::lookup_key;
    use std::fs;
    use std::path::PathBuf;

    #[test]
    fn safe_match_query_bounds_and_quotes_user_input() {
        assert_eq!(
            safe_match_query("Home OR title:*"),
            Some("\"Home\" AND \"OR\" AND \"title\"".to_string())
        );
        assert_eq!(safe_match_query("   !!!   "), None);

        let long_query = "a".repeat(256);
        assert_eq!(
            safe_match_query(&long_query),
            Some(format!("\"{}\"", "a".repeat(128)))
        );
    }

    #[test]
    fn indexes_compatibility_fixture_and_searches_filename_and_body() {
        let mut index = SqliteFtsIndex::open_in_memory().expect("index");
        for document in fixture_documents() {
            index.upsert_document(&document).expect("upsert");
        }
        index.rebuild().expect("rebuild");
        index.integrity_check().expect("integrity");
        index.optimize().expect("optimize");

        assert_eq!(index.document_count().expect("count"), 6);

        let file_results = index.search("Guide", 10).expect("file query");
        assert!(
            file_results
                .iter()
                .any(|result| result.path == "Docs/Guide.md")
        );

        let body_results = index
            .search("compatibility fixture", 10)
            .expect("body query");
        assert!(body_results.iter().any(|result| result.path == "Home.md"));
    }

    #[test]
    fn reports_fixture_query_p95_and_index_size() {
        let mut index = SqliteFtsIndex::open_in_memory().expect("index");
        for document in fixture_documents() {
            index.upsert_document(&document).expect("upsert");
        }
        index.rebuild().expect("rebuild");

        let measurement = index
            .measure_queries(
                &[
                    "Home".to_string(),
                    "Target".to_string(),
                    "attachments".to_string(),
                ],
                10,
            )
            .expect("measurement");

        assert_eq!(measurement.sample_count, 3);
        assert!(measurement.index_size_bytes > 0);
    }

    #[test]
    fn file_backed_index_reports_nonzero_size() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("search.sqlite");
        let mut index = SqliteFtsIndex::open(&path).expect("index");
        index
            .upsert_document(&SearchDocument {
                file_id: "note.md".to_string(),
                path: "Note.md".to_string(),
                title: "Note".to_string(),
                body: "Searchable body".to_string(),
            })
            .expect("upsert");
        index.rebuild().expect("rebuild");

        assert!(index.estimated_size_bytes().expect("size") > 0);
        assert!(fs::metadata(path).expect("metadata").len() > 0);
    }

    fn fixture_documents() -> Vec<SearchDocument> {
        let fixture_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault");
        let mut documents = Vec::new();
        visit_markdown_files(&fixture_root, &fixture_root, &mut documents);
        documents.sort_by(|left, right| left.path.cmp(&right.path));
        documents
    }

    fn visit_markdown_files(root: &Path, directory: &Path, documents: &mut Vec<SearchDocument>) {
        for entry in fs::read_dir(directory).expect("read dir") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                if path.file_name().and_then(|value| value.to_str()) == Some(".obsidian") {
                    continue;
                }
                visit_markdown_files(root, &path, documents);
                continue;
            }

            if path.extension().and_then(|value| value.to_str()) != Some("md") {
                continue;
            }

            let relative_path = path.strip_prefix(root).expect("relative");
            let body = fs::read_to_string(&path).expect("markdown");
            let parsed = parse_markdown(&body);
            let title = parsed
                .headings
                .first()
                .map(|heading| heading.text.clone())
                .unwrap_or_else(|| {
                    relative_path
                        .file_stem()
                        .expect("stem")
                        .to_string_lossy()
                        .to_string()
                });

            documents.push(SearchDocument {
                file_id: lookup_key(relative_path),
                path: relative_path.to_string_lossy().to_string(),
                title,
                body,
            });
        }
    }
}
