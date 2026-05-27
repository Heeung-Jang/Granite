pub(crate) mod build_graph;
pub(crate) mod index_rebuild;
pub(crate) mod indexing_pipeline;
pub(crate) mod live_preview_metadata;
pub(crate) mod process_indexing_queue;
pub(crate) mod read_graph;
pub(crate) mod read_parse_documents;
pub(crate) mod read_types;
pub(crate) mod read_vault;
pub(crate) mod rebuild_tantivy;
#[cfg(test)]
pub(crate) mod reconcile_startup;
pub(crate) mod save_note;
#[cfg(test)]
pub(crate) mod watcher_burst;
