pub use crate::adapters::fs::path_resolver::VaultRoot;
pub use crate::adapters::fs::scanner::scan_vault;
pub use crate::adapters::sqlite::{
    AttachmentRecord, FileRecord, HeadingRecord, IndexedFileRecords, LinkEdgeRecord, MetadataStore,
    PropertyRecord, TagRecord, TagSource, slugify_heading,
};
pub use crate::adapters::tantivy::{TantivySearchError, TantivySearchIndex};
pub use crate::core::attachments::{
    AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
};
pub use crate::core::document::{MarkdownLink, ParsedMarkdown, WikiLink};
pub use crate::core::markdown_parser::parse_markdown;
pub use crate::core::paths::{lookup_key, normalize_relative_path};
pub use crate::core::scan::{ScanEntry, ScanEntryKind, ScanSummary, classify_file};
pub use crate::core::search::{SearchDocument, SnippetStorageMode};
pub use crate::diagnostics::benchmarks::{
    VaultBackendBenchmarkOptions, WholeVaultGraphBenchmarkOptions,
    run_shared_backend_benchmark_from_vault, run_whole_vault_graph_snapshot_benchmark,
};
pub use crate::use_cases::read_graph::{LocalGraphDepth, LocalGraphRequest};
pub use crate::use_cases::read_types::{
    PageRequest, ReadApiError, ReadApiResult, ReadPage, ReadState, SearchHit,
};
pub use crate::use_cases::read_vault::{
    VaultReadApi, expected_read_schema_metadata, open_vault_read_api,
};
