use crate::adapters::sqlite::{
    IndexingQueue, IndexingQueueItem, IndexingQueueReason, MetadataStore,
};
use crate::adapters::tantivy::TantivySearchIndex;
use crate::indexing_pipeline::{
    IndexingPipelineOptions, IndexingPipelineResult, ProductionIndexingPipelineResult,
    SearchDocumentSource, lease_queue_batch_impl, process_indexing_queue_batch_impl,
};
use crate::paths::VaultRoot;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QueueBatchIndexOptions {
    pub lease_limit: usize,
    pub max_attempts: u32,
}

impl Default for QueueBatchIndexOptions {
    fn default() -> Self {
        Self {
            lease_limit: 32,
            max_attempts: 3,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueueLeaseBatch {
    pub items: Vec<QueuePipelineItem>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueuePipelineItem {
    pub queue_item: IndexingQueueItem,
    pub source: Option<SearchDocumentSource>,
}

pub fn lease_queue_batch(
    queue: &mut IndexingQueue,
    root: &VaultRoot,
    limit: usize,
) -> IndexingPipelineResult<QueueLeaseBatch> {
    lease_queue_batch_impl(queue, root, limit)
}

pub fn process_indexing_queue_batch(
    queue: &mut IndexingQueue,
    metadata_store: &mut MetadataStore,
    tantivy_index: &mut TantivySearchIndex,
    root: &VaultRoot,
    batch_options: QueueBatchIndexOptions,
    pipeline_options: &IndexingPipelineOptions,
) -> IndexingPipelineResult<ProductionIndexingPipelineResult> {
    process_indexing_queue_batch_impl(
        queue,
        metadata_store,
        tantivy_index,
        root,
        batch_options,
        pipeline_options,
    )
}

pub(crate) fn source_for_queue_item(
    root: &VaultRoot,
    queue_item: &IndexingQueueItem,
) -> IndexingPipelineResult<Option<SearchDocumentSource>> {
    if queue_item.reason == IndexingQueueReason::FileDeleted {
        return Ok(None);
    }
    let relative_path = queue_item.relative_path.to_string_lossy();
    let resolved = root.resolve_existing_relative(relative_path.as_ref())?;

    Ok(Some(SearchDocumentSource {
        relative_path: resolved.relative_path,
        absolute_path: resolved.absolute_path,
        file_id: queue_item.file_id.clone(),
        kind: queue_item.kind,
        size_bytes: queue_item.size_bytes,
        modified: queue_item.modified,
        file_identity: resolved.file_identity,
    }))
}
