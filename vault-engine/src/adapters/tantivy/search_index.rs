use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use tantivy::collector::TopDocs;
use tantivy::query::{QueryParser, QueryParserError};
use tantivy::schema::{Field, TantivyDocument, Value};
use tantivy::snippet::SnippetGenerator;
use tantivy::{Index, IndexReader, TantivyError, Term, doc};

#[cfg(test)]
use super::first_query_term;
use super::{
    TantivyFields, directory_size, duration_micros_nonzero, percentile_duration,
    safe_tantivy_query, search_schema, search_schema_for_snippet_mode,
};
#[cfg(test)]
use crate::adapters::fs::path_resolver::VaultRoot;
#[cfg(test)]
use crate::core::files::FileIdentity;
use crate::core::paths::PathError;
use crate::core::search::SnippetStorageMode;
use crate::core::search::{SearchDocument, SearchMeasurement, SearchResult};

pub const DEFAULT_TANTIVY_WRITER_MEMORY_BUDGET_BYTES: usize = 50_000_000;

pub struct TantivySearchIndex {
    index: Index,
    reader: IndexReader,
    fields: TantivyFields,
    index_dir: Option<PathBuf>,
    snippet_storage_mode: SnippetStorageMode,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TantivyIndexingStageMetrics {
    pub add_micros: u64,
    pub commit_micros: u64,
    pub reader_reload_micros: u64,
    pub added_document_count: usize,
    pub deleted_document_count: usize,
    pub skipped_document_count: usize,
    pub failed_document_count: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TantivyWriterOptions {
    pub memory_budget_bytes: usize,
    pub writer_thread_count: Option<usize>,
}

impl Default for TantivyWriterOptions {
    fn default() -> Self {
        Self {
            memory_budget_bytes: DEFAULT_TANTIVY_WRITER_MEMORY_BUDGET_BYTES,
            writer_thread_count: None,
        }
    }
}

#[derive(Debug)]
pub enum TantivySearchError {
    Tantivy(TantivyError),
    QueryParser(QueryParserError),
    Io(std::io::Error),
    Path(PathError),
    EmptyQuery,
}

pub type TantivySearchResult<T> = Result<T, TantivySearchError>;

impl TantivySearchIndex {
    pub fn open_in_ram() -> TantivySearchResult<Self> {
        Self::open_in_ram_with_snippet_mode(SnippetStorageMode::StoredBody)
    }

    pub fn open_in_ram_with_snippet_mode(
        snippet_storage_mode: SnippetStorageMode,
    ) -> TantivySearchResult<Self> {
        let (schema, fields) = search_schema_for_snippet_mode(snippet_storage_mode);
        let index = Index::builder().schema(schema).create_in_ram()?;
        Self::from_index(index, fields, None, snippet_storage_mode)
    }

    pub fn open_in_dir(path: impl AsRef<Path>) -> TantivySearchResult<Self> {
        Self::open_in_dir_with_snippet_mode(path, SnippetStorageMode::StoredBody)
    }

    pub fn open_in_dir_with_snippet_mode(
        path: impl AsRef<Path>,
        snippet_storage_mode: SnippetStorageMode,
    ) -> TantivySearchResult<Self> {
        let (schema, fields) = search_schema_for_snippet_mode(snippet_storage_mode);
        fs::create_dir_all(path.as_ref())?;
        let index = Index::create_in_dir(path.as_ref(), schema)?;
        Self::from_index(
            index,
            fields,
            Some(path.as_ref().to_path_buf()),
            snippet_storage_mode,
        )
    }

    pub fn open_existing_dir(path: impl AsRef<Path>) -> TantivySearchResult<Self> {
        let (_, fields) = search_schema();
        let index = Index::open_in_dir(path.as_ref())?;
        Self::from_index(
            index,
            fields,
            Some(path.as_ref().to_path_buf()),
            SnippetStorageMode::StoredBody,
        )
    }

    fn from_index(
        index: Index,
        fields: TantivyFields,
        index_dir: Option<PathBuf>,
        snippet_storage_mode: SnippetStorageMode,
    ) -> TantivySearchResult<Self> {
        let reader = index.reader()?;
        Ok(Self {
            index,
            reader,
            fields,
            index_dir,
            snippet_storage_mode,
        })
    }

    pub fn replace_documents(&mut self, documents: &[SearchDocument]) -> TantivySearchResult<()> {
        self.replace_documents_with_stage_durations(documents)?;
        Ok(())
    }

    pub fn replace_documents_with_stage_durations(
        &mut self,
        documents: &[SearchDocument],
    ) -> TantivySearchResult<TantivyIndexingStageMetrics> {
        self.replace_documents_with_options_and_stage_durations(
            documents,
            TantivyWriterOptions::default(),
        )
    }

    pub fn replace_documents_with_options_and_stage_durations(
        &mut self,
        documents: &[SearchDocument],
        options: TantivyWriterOptions,
    ) -> TantivySearchResult<TantivyIndexingStageMetrics> {
        self.replace_documents_from_result_iter_with_options_and_stage_durations(
            documents
                .iter()
                .cloned()
                .map(Ok::<SearchDocument, TantivySearchError>),
            options,
        )
    }

    pub fn replace_documents_from_result_iter<I, E>(&mut self, documents: I) -> Result<(), E>
    where
        I: IntoIterator<Item = Result<SearchDocument, E>>,
        E: From<TantivySearchError>,
    {
        self.replace_documents_from_result_iter_with_stage_durations(documents)?;
        Ok(())
    }

    pub fn replace_documents_from_result_iter_with_stage_durations<I, E>(
        &mut self,
        documents: I,
    ) -> Result<TantivyIndexingStageMetrics, E>
    where
        I: IntoIterator<Item = Result<SearchDocument, E>>,
        E: From<TantivySearchError>,
    {
        self.replace_documents_from_result_iter_with_options_and_stage_durations(
            documents,
            TantivyWriterOptions::default(),
        )
    }

    pub fn replace_documents_from_result_iter_with_options_and_stage_durations<I, E>(
        &mut self,
        documents: I,
        options: TantivyWriterOptions,
    ) -> Result<TantivyIndexingStageMetrics, E>
    where
        I: IntoIterator<Item = Result<SearchDocument, E>>,
        E: From<TantivySearchError>,
    {
        self.index_documents_from_result_iter(documents, options, true)
    }

    pub fn delete_documents_by_file_ids_with_options_and_stage_durations(
        &mut self,
        file_ids: &[String],
        options: TantivyWriterOptions,
    ) -> TantivySearchResult<TantivyIndexingStageMetrics> {
        if file_ids.is_empty() {
            return Ok(TantivyIndexingStageMetrics::default());
        }

        let mut writer: tantivy::IndexWriter<TantivyDocument> = match options.writer_thread_count {
            Some(thread_count) => self
                .index
                .writer_with_num_threads(thread_count.max(1), options.memory_budget_bytes),
            None => self.index.writer(options.memory_budget_bytes),
        }?;
        let mut delete_micros = 0;
        for file_id in file_ids {
            let delete_start = Instant::now();
            writer.delete_term(Term::from_field_text(self.fields.file_id, file_id));
            delete_micros += duration_micros_nonzero(delete_start.elapsed());
        }
        let commit_start = Instant::now();
        writer.commit()?;
        let commit_micros = duration_micros_nonzero(commit_start.elapsed());
        let reload_start = Instant::now();
        self.reader.reload()?;
        let reader_reload_micros = duration_micros_nonzero(reload_start.elapsed());

        Ok(TantivyIndexingStageMetrics {
            add_micros: delete_micros,
            commit_micros,
            reader_reload_micros,
            added_document_count: 0,
            deleted_document_count: file_ids.len(),
            skipped_document_count: 0,
            failed_document_count: 0,
        })
    }

    /// Add documents into a fresh rebuild index without deleting existing file ids first.
    ///
    /// This is only valid when the target index directory was just created or reset.
    pub fn add_documents_for_rebuild_from_result_iter_with_stage_durations<I, E>(
        &mut self,
        documents: I,
    ) -> Result<TantivyIndexingStageMetrics, E>
    where
        I: IntoIterator<Item = Result<SearchDocument, E>>,
        E: From<TantivySearchError>,
    {
        self.add_documents_for_rebuild_from_result_iter_with_options_and_stage_durations(
            documents,
            TantivyWriterOptions::default(),
        )
    }

    pub fn add_documents_for_rebuild_from_result_iter_with_options_and_stage_durations<I, E>(
        &mut self,
        documents: I,
        options: TantivyWriterOptions,
    ) -> Result<TantivyIndexingStageMetrics, E>
    where
        I: IntoIterator<Item = Result<SearchDocument, E>>,
        E: From<TantivySearchError>,
    {
        self.index_documents_from_result_iter(documents, options, false)
    }

    fn index_documents_from_result_iter<I, E>(
        &mut self,
        documents: I,
        options: TantivyWriterOptions,
        delete_existing: bool,
    ) -> Result<TantivyIndexingStageMetrics, E>
    where
        I: IntoIterator<Item = Result<SearchDocument, E>>,
        E: From<TantivySearchError>,
    {
        let mut writer = match options.writer_thread_count {
            Some(thread_count) => self
                .index
                .writer_with_num_threads(thread_count.max(1), options.memory_budget_bytes),
            None => self.index.writer(options.memory_budget_bytes),
        }
        .map_err(TantivySearchError::from)?;
        let mut add_micros = 0;
        let mut added_document_count = 0;
        let mut deleted_document_count = 0;
        for document in documents {
            let document = document?;
            let add_start = Instant::now();
            if delete_existing {
                writer.delete_term(Term::from_field_text(
                    self.fields.file_id,
                    &document.file_id,
                ));
                deleted_document_count += 1;
            }
            writer
                .add_document(doc!(
                    self.fields.file_id => document.file_id.as_str(),
                    self.fields.path => document.path.as_str(),
                    self.fields.title => document.title.as_str(),
                    self.fields.body => document.body.as_str(),
                ))
                .map_err(TantivySearchError::from)?;
            added_document_count += 1;
            add_micros += duration_micros_nonzero(add_start.elapsed());
        }
        let commit_start = Instant::now();
        writer.commit().map_err(TantivySearchError::from)?;
        let commit_micros = duration_micros_nonzero(commit_start.elapsed());
        let reload_start = Instant::now();
        self.reader.reload().map_err(TantivySearchError::from)?;
        let reader_reload_micros = duration_micros_nonzero(reload_start.elapsed());

        Ok(TantivyIndexingStageMetrics {
            add_micros,
            commit_micros,
            reader_reload_micros,
            added_document_count,
            deleted_document_count,
            skipped_document_count: 0,
            failed_document_count: 0,
        })
    }

    pub fn search(&self, query: &str, limit: usize) -> TantivySearchResult<Vec<SearchResult>> {
        self.search_page(query, 0, limit.clamp(1, 100))
    }

    pub fn search_page(
        &self,
        query: &str,
        offset: usize,
        limit: usize,
    ) -> TantivySearchResult<Vec<SearchResult>> {
        let Some(query_text) = safe_tantivy_query(query) else {
            return Err(TantivySearchError::EmptyQuery);
        };
        let searcher = self.reader.searcher();
        let parser = QueryParser::for_index(
            &self.index,
            vec![self.fields.path, self.fields.title, self.fields.body],
        );
        let query = parser.parse_query(&query_text)?;
        let limit = limit.clamp(1, 1_000);
        let window = offset.saturating_add(limit).clamp(1, 1_000);
        let top_docs = searcher.search(&query, &TopDocs::with_limit(window))?;
        let mut snippet_generator =
            SnippetGenerator::create(&searcher, query.as_ref(), self.fields.body)?;
        snippet_generator.set_max_num_chars(160);

        let mut results = Vec::with_capacity(limit.min(top_docs.len()));
        for (score, address) in top_docs.into_iter().skip(offset).take(limit) {
            let document = searcher.doc::<TantivyDocument>(address)?;
            let snippet = match self.snippet_storage_mode {
                SnippetStorageMode::StoredBody => {
                    snippet_generator.snippet_from_doc(&document).to_html()
                }
                SnippetStorageMode::LazySourceExperiment => String::new(),
            };
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
        Ok(directory_size(path)?)
    }
}

#[cfg(test)]
pub fn generate_lazy_source_snippet(
    root: &VaultRoot,
    relative_path: &str,
    expected_identity: &FileIdentity,
    indexed_generation: u64,
    current_generation: u64,
    query: &str,
    max_chars: usize,
) -> TantivySearchResult<Option<String>> {
    let resolved = root.resolve_existing_relative(relative_path)?;
    if &resolved.file_identity != expected_identity || indexed_generation != current_generation {
        return Ok(None);
    }
    let body = fs::read_to_string(&resolved.absolute_path)?;
    let Some(term) = first_query_term(query) else {
        return Ok(None);
    };
    let body_lower = body.to_lowercase();
    let Some(byte_index) = body_lower.find(&term.to_lowercase()) else {
        return Ok(None);
    };
    Ok(Some(snippet_around(&body, byte_index, max_chars.max(1))))
}

impl fmt::Display for TantivySearchError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Tantivy(error) => write!(formatter, "tantivy search error: {error}"),
            Self::QueryParser(error) => write!(formatter, "tantivy query parse error: {error}"),
            Self::Io(error) => write!(formatter, "tantivy index io error: {error}"),
            Self::Path(error) => write!(formatter, "tantivy path error: {error}"),
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

impl From<PathError> for TantivySearchError {
    fn from(error: PathError) -> Self {
        Self::Path(error)
    }
}

#[cfg(test)]
fn snippet_around(body: &str, byte_index: usize, max_chars: usize) -> String {
    let mut char_positions = body
        .char_indices()
        .map(|(index, _)| index)
        .collect::<Vec<_>>();
    char_positions.push(body.len());
    let center_char = char_positions
        .binary_search(&byte_index)
        .unwrap_or_else(|index| index.saturating_sub(1));
    let half = max_chars / 2;
    let start_char = center_char.saturating_sub(half);
    let end_char = (start_char + max_chars).min(char_positions.len().saturating_sub(1));
    body[char_positions[start_char]..char_positions[end_char]].to_string()
}

fn stored_text(document: &TantivyDocument, field: Field) -> String {
    document
        .get_first(field)
        .and_then(|value| value.as_str())
        .unwrap_or("")
        .to_string()
}
