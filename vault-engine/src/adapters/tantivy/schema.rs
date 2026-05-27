use tantivy::schema::{Field, STORED, STRING, Schema, TEXT};

use crate::indexing_pipeline::SnippetStorageMode;

#[derive(Debug, Clone, Copy)]
pub(crate) struct TantivyFields {
    pub(crate) file_id: Field,
    pub(crate) path: Field,
    pub(crate) title: Field,
    pub(crate) body: Field,
}

pub(crate) fn search_schema() -> (Schema, TantivyFields) {
    search_schema_for_snippet_mode(SnippetStorageMode::StoredBody)
}

pub(crate) fn search_schema_for_snippet_mode(
    snippet_storage_mode: SnippetStorageMode,
) -> (Schema, TantivyFields) {
    let mut builder = Schema::builder();
    let file_id = builder.add_text_field("file_id", STRING | STORED);
    let path = builder.add_text_field("path", TEXT | STORED);
    let title = builder.add_text_field("title", TEXT | STORED);
    let body_options = match snippet_storage_mode {
        SnippetStorageMode::StoredBody => TEXT | STORED,
        SnippetStorageMode::LazySourceExperiment => TEXT,
    };
    let body = builder.add_text_field("body", body_options);
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
