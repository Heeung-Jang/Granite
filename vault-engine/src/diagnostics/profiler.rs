pub use crate::adapters::sqlite::{
    AttachmentRecord, FileRecord, HeadingRecord, IndexedFileRecords, LinkEdgeRecord, MetadataStore,
    PropertyRecord, TagRecord, TagSource, slugify_heading,
};
pub use crate::adapters::tantivy::{TantivySearchError, TantivySearchIndex};
pub use crate::core::attachments::{
    AttachmentReferenceSource, AttachmentRejectReason, AttachmentResolutionState,
};
pub use crate::core::search::{SearchDocument, SnippetStorageMode};
pub use crate::diagnostics::benchmarks::{
    VaultBackendBenchmarkOptions, WholeVaultGraphBenchmarkOptions,
    run_shared_backend_benchmark_from_vault, run_whole_vault_graph_snapshot_benchmark,
};
pub use crate::parser::{MarkdownLink, ParsedMarkdown, WikiLink, parse_markdown};
pub use crate::paths::{VaultRoot, lookup_key, normalize_relative_path};
pub use crate::scanner::{ScanEntry, ScanEntryKind, ScanSummary, classify_file, scan_vault};
pub use crate::use_cases::read_graph::{LocalGraphDepth, LocalGraphRequest};
pub use crate::use_cases::read_types::{
    PageRequest, ReadApiError, ReadApiResult, ReadPage, ReadState, SearchHit,
};
pub use crate::use_cases::read_vault::{
    VaultReadApi, expected_read_schema_metadata, open_vault_read_api,
};
