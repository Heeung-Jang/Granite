use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use tantivy::collector::TopDocs;
use tantivy::query::{QueryParser, QueryParserError};
use tantivy::schema::{Field, STORED, STRING, Schema, TEXT, TantivyDocument, Value};
use tantivy::snippet::SnippetGenerator;
use tantivy::{Index, IndexReader, TantivyError, Term, doc};

use crate::sqlite_fts::{SearchDocument, SearchMeasurement, SearchResult};

pub struct TantivySearchIndex {
    index: Index,
    reader: IndexReader,
    fields: TantivyFields,
    index_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Copy)]
struct TantivyFields {
    file_id: Field,
    path: Field,
    title: Field,
    body: Field,
}

#[derive(Debug)]
pub enum TantivySearchError {
    Tantivy(TantivyError),
    QueryParser(QueryParserError),
    Io(std::io::Error),
    EmptyQuery,
}

pub type TantivySearchResult<T> = Result<T, TantivySearchError>;

impl TantivySearchIndex {
    pub fn open_in_ram() -> TantivySearchResult<Self> {
        let (schema, fields) = search_schema();
        let index = Index::builder().schema(schema).create_in_ram()?;
        Self::from_index(index, fields, None)
    }

    pub fn open_in_dir(path: impl AsRef<Path>) -> TantivySearchResult<Self> {
        let (schema, fields) = search_schema();
        fs::create_dir_all(path.as_ref())?;
        let index = Index::create_in_dir(path.as_ref(), schema)?;
        Self::from_index(index, fields, Some(path.as_ref().to_path_buf()))
    }

    fn from_index(
        index: Index,
        fields: TantivyFields,
        index_dir: Option<PathBuf>,
    ) -> TantivySearchResult<Self> {
        let reader = index.reader()?;
        Ok(Self {
            index,
            reader,
            fields,
            index_dir,
        })
    }

    pub fn replace_documents(&mut self, documents: &[SearchDocument]) -> TantivySearchResult<()> {
        let mut writer = self.index.writer(50_000_000)?;
        for document in documents {
            writer.delete_term(Term::from_field_text(
                self.fields.file_id,
                &document.file_id,
            ));
            writer.add_document(doc!(
                self.fields.file_id => document.file_id.as_str(),
                self.fields.path => document.path.as_str(),
                self.fields.title => document.title.as_str(),
                self.fields.body => document.body.as_str(),
            ))?;
        }
        writer.commit()?;
        self.reader.reload()?;
        Ok(())
    }

    pub fn search(&self, query: &str, limit: usize) -> TantivySearchResult<Vec<SearchResult>> {
        let Some(query_text) = safe_tantivy_query(query) else {
            return Err(TantivySearchError::EmptyQuery);
        };
        let searcher = self.reader.searcher();
        let parser = QueryParser::for_index(
            &self.index,
            vec![self.fields.path, self.fields.title, self.fields.body],
        );
        let query = parser.parse_query(&query_text)?;
        let top_docs = searcher.search(&query, &TopDocs::with_limit(limit.clamp(1, 100)))?;
        let mut snippet_generator =
            SnippetGenerator::create(&searcher, query.as_ref(), self.fields.body)?;
        snippet_generator.set_max_num_chars(160);

        let mut results = Vec::with_capacity(top_docs.len());
        for (score, address) in top_docs {
            let document = searcher.doc::<TantivyDocument>(address)?;
            let snippet = snippet_generator.snippet_from_doc(&document).to_html();
            results.push(SearchResult {
                file_id: stored_text(&document, self.fields.file_id),
                path: stored_text(&document, self.fields.path),
                title: stored_text(&document, self.fields.title),
                rank: score as f64,
                snippet,
            });
        }
        Ok(results)
    }

    pub fn measure_queries(
        &self,
        queries: &[String],
        limit: usize,
    ) -> TantivySearchResult<SearchMeasurement> {
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

    pub fn estimated_size_bytes(&self) -> TantivySearchResult<u64> {
        let Some(path) = &self.index_dir else {
            return Ok(0);
        };
        directory_size(path)
    }
}

impl fmt::Display for TantivySearchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Tantivy(error) => write!(formatter, "tantivy search error: {error}"),
            Self::QueryParser(error) => write!(formatter, "tantivy query parse error: {error}"),
            Self::Io(error) => write!(formatter, "tantivy index io error: {error}"),
            Self::EmptyQuery => write!(formatter, "search query is empty after sanitization"),
        }
    }
}

impl std::error::Error for TantivySearchError {}

impl From<TantivyError> for TantivySearchError {
    fn from(error: TantivyError) -> Self {
        Self::Tantivy(error)
    }
}

impl From<QueryParserError> for TantivySearchError {
    fn from(error: QueryParserError) -> Self {
        Self::QueryParser(error)
    }
}

impl From<std::io::Error> for TantivySearchError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

pub fn safe_tantivy_query(input: &str) -> Option<String> {
    let bounded = input.chars().take(128).collect::<String>();
    let terms = bounded
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|term| !term.is_empty())
        .take(8)
        .map(|term| format!("\"{}\"", term.replace('"', "\\\"")))
        .collect::<Vec<_>>();

    (!terms.is_empty()).then(|| terms.join(" "))
}

fn search_schema() -> (Schema, TantivyFields) {
    let mut builder = Schema::builder();
    let file_id = builder.add_text_field("file_id", STRING | STORED);
    let path = builder.add_text_field("path", TEXT | STORED);
    let title = builder.add_text_field("title", TEXT | STORED);
    let body = builder.add_text_field("body", TEXT | STORED);
    (
        builder.build(),
        TantivyFields {
            file_id,
            path,
            title,
            body,
        },
    )
}

fn stored_text(document: &TantivyDocument, field: Field) -> String {
    document
        .get_first(field)
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string()
}

fn percentile_duration(values: &[Duration], percentile: usize) -> Duration {
    if values.is_empty() {
        return Duration::ZERO;
    }
    let index = ((values.len() * percentile).div_ceil(100)).saturating_sub(1);
    values[index.min(values.len() - 1)]
}

fn directory_size(path: &Path) -> TantivySearchResult<u64> {
    let mut size = 0;
    for entry in fs::read_dir(path)? {
        let path = entry?.path();
        let metadata = fs::metadata(&path)?;
        if metadata.is_dir() {
            size += directory_size(&path)?;
        } else {
            size += metadata.len();
        }
    }
    Ok(size)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sqlite_fts::SearchDocument;

    #[test]
    fn safe_tantivy_query_bounds_and_quotes_user_input() {
        assert_eq!(
            safe_tantivy_query("Home OR title:*"),
            Some("\"Home\" \"OR\" \"title\"".to_string())
        );
        assert_eq!(safe_tantivy_query("   !!!   "), None);
    }

    #[test]
    fn indexes_fixture_shape_and_searches_filename_and_body() {
        let mut index = TantivySearchIndex::open_in_ram().expect("index");
        index
            .replace_documents(&fixture_documents())
            .expect("replace docs");

        let file_results = index.search("Guide", 10).expect("file search");
        assert!(
            file_results
                .iter()
                .any(|result| result.path == "Docs/Guide.md")
        );

        let body_results = index
            .search("compatibility fixture", 10)
            .expect("body search");
        assert!(body_results.iter().any(|result| result.path == "Home.md"));
        assert!(body_results.iter().any(|result| !result.snippet.is_empty()));
    }

    #[test]
    fn delete_by_file_id_plus_insert_updates_document() {
        let mut index = TantivySearchIndex::open_in_ram().expect("index");
        index
            .replace_documents(&[SearchDocument {
                file_id: "note.md".to_string(),
                path: "Note.md".to_string(),
                title: "Old".to_string(),
                body: "old body".to_string(),
            }])
            .expect("initial");
        index
            .replace_documents(&[SearchDocument {
                file_id: "note.md".to_string(),
                path: "Note.md".to_string(),
                title: "New".to_string(),
                body: "fresh body".to_string(),
            }])
            .expect("update");

        assert!(index.search("fresh", 10).expect("fresh").len() == 1);
        assert!(index.search("old", 10).expect("old").is_empty());
    }

    #[test]
    fn reports_fixture_query_p95_and_file_backed_index_size() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mut index = TantivySearchIndex::open_in_dir(dir.path()).expect("index");
        index
            .replace_documents(&fixture_documents())
            .expect("replace docs");

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

    fn fixture_documents() -> Vec<SearchDocument> {
        vec![
            SearchDocument {
                file_id: "home.md".to_string(),
                path: "Home.md".to_string(),
                title: "Home".to_string(),
                body: "Welcome to the compatibility fixture vault.".to_string(),
            },
            SearchDocument {
                file_id: "docs/guide.md".to_string(),
                path: "Docs/Guide.md".to_string(),
                title: "Guide".to_string(),
                body: "Guide links back to Home.".to_string(),
            },
            SearchDocument {
                file_id: "folder/target.md".to_string(),
                path: "Folder/Target.md".to_string(),
                title: "Target".to_string(),
                body: "This note is the resolved target for heading links.".to_string(),
            },
            SearchDocument {
                file_id: "attachments.md".to_string(),
                path: "Attachments.md".to_string(),
                title: "Attachments".to_string(),
                body: "Image embed and PDF attachment references.".to_string(),
            },
        ]
    }
}
