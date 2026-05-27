use std::path::Path;

use crate::adapters::sqlite::{
    AttachmentProjection, AttachmentRecord, FileLookupProjection, FileRecord, FileTreeProjection,
    HeadingRecord, IndexSchemaMetadata, LinkEdgeRecord, LinkProjection, MetadataStore,
    PropertyProjection, PropertyRecord, TagRecord,
};
use crate::adapters::tantivy::{TantivySearchError, TantivySearchIndex};
use crate::read_api::{
    ENGINE_READ_SEARCH_MODE_BODY, ENGINE_READ_SEARCH_MODE_FILE_NAME, FileOpenMetadata,
    READ_BACKEND_NAME, READ_BACKEND_VERSION, READ_TOKENIZER_CONFIG, ReadApiError, ReadApiResult,
    SearchHit,
};

use super::read_graph::{
    LocalGraph, LocalGraphBuild, LocalGraphBuilder, LocalGraphDepth, LocalGraphEdge,
    LocalGraphEdgeDirection, LocalGraphNode, LocalGraphNodeKind, LocalGraphRequest,
    graph_file_node_id, graph_unresolved_node_id, push_frontier_file, unresolved_graph_node,
};
use super::read_types::{
    MAX_FILE_TREE_PAGE_LIMIT, MAX_PAGE_LIMIT, PageRequest, ReadOpenError, ReadOpenResult, ReadPage,
    ReadState, ReadValue,
};

pub struct VaultReadApi {
    pub(crate) metadata: MetadataStore,
    pub(crate) search: TantivySearchIndex,
    pub(crate) generation: u64,
}

impl VaultReadApi {
    pub fn new(metadata: MetadataStore, search: TantivySearchIndex) -> Self {
        Self::with_generation(metadata, search, 0)
    }

    pub fn with_generation(
        metadata: MetadataStore,
        search: TantivySearchIndex,
        generation: u64,
    ) -> Self {
        Self {
            metadata,
            search,
            generation,
        }
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn file_tree(&self, page: PageRequest) -> ReadApiResult<ReadPage<FileRecord>> {
        Ok(self.page_from_overfetch_with_limit(
            self.metadata
                .list_markdown_files(page.offset, page.file_tree_fetch_limit())?,
            page,
            MAX_FILE_TREE_PAGE_LIMIT,
        ))
    }

    pub fn file_tree_projection(
        &self,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<FileTreeProjection>> {
        Ok(self.page_from_overfetch_with_limit(
            self.metadata
                .file_tree_projection(page.offset, page.file_tree_fetch_limit())?,
            page,
            MAX_FILE_TREE_PAGE_LIMIT,
        ))
    }

    pub fn file_open_metadata(
        &self,
        file_id: &str,
    ) -> ReadApiResult<ReadValue<Option<FileOpenMetadata>>> {
        self.file_open_metadata_with_request(0, file_id)
    }

    pub fn file_open_metadata_with_request(
        &self,
        request_id: u64,
        file_id: &str,
    ) -> ReadApiResult<ReadValue<Option<FileOpenMetadata>>> {
        Ok(ReadValue {
            request_id,
            generation: self.generation,
            value: self
                .metadata
                .get_file(file_id)?
                .map(|file| FileOpenMetadata { file }),
            state: ReadState::Complete,
        })
    }

    pub fn file_name_search(
        &self,
        query: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<SearchHit>> {
        self.search(query, page)
    }

    pub fn body_search(
        &self,
        query: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<SearchHit>> {
        self.search(query, page)
    }

    pub fn search_with_mode(
        &self,
        mode: u32,
        query: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<SearchHit>> {
        match mode {
            ENGINE_READ_SEARCH_MODE_FILE_NAME => self.file_name_search(query, page),
            ENGINE_READ_SEARCH_MODE_BODY => self.body_search(query, page),
            _ => Err(ReadApiError::InvalidInput("search_mode")),
        }
    }

    pub fn backlinks_for_path(
        &self,
        relative_path: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<LinkProjection>> {
        let file = self.require_file(relative_path)?;
        Ok(self.page_from_overfetch(
            self.metadata
                .backlink_projections(&file.file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn outgoing_links_for_path(
        &self,
        relative_path: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<LinkProjection>> {
        let file = self.require_file(relative_path)?;
        Ok(self.page_from_overfetch(
            self.metadata.outgoing_link_projections(
                &file.file_id,
                page.offset,
                page.fetch_limit(),
            )?,
            page,
        ))
    }

    pub fn backlinks(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<LinkEdgeRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .backlinks(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn outgoing_links(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<LinkEdgeRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .outgoing_links(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn tags_for_path(
        &self,
        relative_path: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<TagRecord>> {
        let file = self.require_file(relative_path)?;
        self.tags(&file.file_id, page)
    }

    pub fn properties_for_path(
        &self,
        relative_path: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<PropertyProjection>> {
        let file = self.require_file(relative_path)?;
        Ok(self.page_from_overfetch(
            self.metadata
                .property_projections(&file.file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn tags(&self, file_id: &str, page: PageRequest) -> ReadApiResult<ReadPage<TagRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .tags(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn properties(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<PropertyRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .properties(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn attachments_for_path(
        &self,
        relative_path: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<AttachmentProjection>> {
        let file = self.require_file(relative_path)?;
        Ok(self.page_from_overfetch(
            self.metadata
                .attachment_projections(&file.file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn headings(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<HeadingRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .headings(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn attachments(
        &self,
        file_id: &str,
        page: PageRequest,
    ) -> ReadApiResult<ReadPage<AttachmentRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata
                .attachments(file_id, page.offset, page.fetch_limit())?,
            page,
        ))
    }

    pub fn local_graph(
        &self,
        file_id: &str,
        request: LocalGraphRequest,
    ) -> ReadApiResult<ReadValue<LocalGraph>> {
        let graph = self.build_one_hop_graph(file_id, request)?;
        Ok(ReadValue {
            request_id: request.request_id,
            generation: self.generation,
            state: if graph.partial {
                ReadState::Partial
            } else {
                ReadState::Complete
            },
            value: graph.graph,
        })
    }

    pub fn local_graph_for_path(
        &self,
        relative_path: &str,
        request: LocalGraphRequest,
    ) -> ReadApiResult<ReadValue<LocalGraph>> {
        let file = self.require_file(relative_path)?;
        self.local_graph(&file.file_id, request)
    }

    fn search(&self, query: &str, page: PageRequest) -> ReadApiResult<ReadPage<SearchHit>> {
        let results = match self
            .search
            .search_page(query, page.offset, page.fetch_limit())
        {
            Ok(results) => results,
            Err(TantivySearchError::EmptyQuery) => {
                return Ok(ReadPage {
                    request_id: page.request_id,
                    generation: self.generation,
                    items: Vec::new(),
                    next_offset: None,
                    state: ReadState::Error,
                });
            }
            Err(error) => return Err(error.into()),
        };
        Ok(self.page_from_overfetch(results.into_iter().map(SearchHit::from).collect(), page))
    }

    pub(crate) fn require_file(&self, relative_path: &str) -> ReadApiResult<FileLookupProjection> {
        if relative_path.trim().is_empty() {
            return Err(ReadApiError::InvalidInput("relative_path"));
        }
        self.metadata
            .lookup_file(relative_path)?
            .ok_or(ReadApiError::NotFound("relative_path"))
    }

    fn build_one_hop_graph(
        &self,
        file_id: &str,
        request: LocalGraphRequest,
    ) -> ReadApiResult<LocalGraphBuild> {
        let node_limit = request.node_limit();
        let edge_limit = request.edge_limit();
        let center_node_id = graph_file_node_id(file_id);
        let center_label = self
            .metadata
            .get_file(file_id)?
            .map(|file| file.relative_path.display().to_string())
            .unwrap_or_else(|| file_id.to_string());

        let mut builder = LocalGraphBuilder::new(node_limit, edge_limit);
        builder.add_node(LocalGraphNode {
            node_id: center_node_id.clone(),
            file_id: Some(file_id.to_string()),
            label: center_label,
            kind: LocalGraphNodeKind::Center,
        });

        let mut frontier_file_ids = Vec::new();
        let outgoing = self
            .metadata
            .outgoing_links(file_id, 0, edge_limit.saturating_add(1))?;
        for (index, link) in outgoing.into_iter().enumerate() {
            if index >= edge_limit {
                builder.mark_partial();
                break;
            }
            if let Some(target_file_id) = link.resolved_target_file_id.as_deref() {
                push_frontier_file(&mut frontier_file_ids, file_id, target_file_id);
            }
            let target_node = match link.resolved_target_file_id.as_deref() {
                Some(target_file_id) => self.resolved_graph_node(target_file_id)?,
                None => unresolved_graph_node(&link.target_text),
            };
            builder.add_edge(
                target_node,
                LocalGraphEdge {
                    source_node_id: center_node_id.clone(),
                    target_node_id: link
                        .resolved_target_file_id
                        .as_deref()
                        .map(graph_file_node_id)
                        .unwrap_or_else(|| graph_unresolved_node_id(&link.target_text)),
                    target_text: link.target_text,
                    direction: LocalGraphEdgeDirection::Outgoing,
                    is_embed: link.is_embed,
                    hop: 1,
                },
            );
        }

        if builder.edge_limit_reached() {
            if !builder.is_partial() && !self.metadata.backlinks(file_id, 0, 1)?.is_empty() {
                builder.mark_partial();
            }
        } else {
            let remaining = edge_limit.saturating_sub(builder.edge_count());
            let backlinks = self
                .metadata
                .backlinks(file_id, 0, remaining.saturating_add(1))?;
            for (index, link) in backlinks.into_iter().enumerate() {
                if index >= remaining {
                    builder.mark_partial();
                    break;
                }
                push_frontier_file(&mut frontier_file_ids, file_id, &link.source_file_id);
                let source_node = self.resolved_graph_node(&link.source_file_id)?;
                builder.add_edge(
                    source_node,
                    LocalGraphEdge {
                        source_node_id: graph_file_node_id(&link.source_file_id),
                        target_node_id: center_node_id.clone(),
                        target_text: link.target_text,
                        direction: LocalGraphEdgeDirection::Backlink,
                        is_embed: link.is_embed,
                        hop: 1,
                    },
                );
            }
        }

        if request.depth == LocalGraphDepth::TwoHop && !builder.edge_limit_reached() {
            frontier_file_ids.sort();
            frontier_file_ids.dedup();
            let frontier_count = frontier_file_ids.len();
            for (source_index, source_file_id) in frontier_file_ids.into_iter().enumerate() {
                if builder.edge_limit_reached() {
                    if source_index < frontier_count {
                        builder.mark_partial();
                    }
                    break;
                }
                let remaining = edge_limit.saturating_sub(builder.edge_count());
                let outgoing = self.metadata.outgoing_links(
                    &source_file_id,
                    0,
                    remaining.saturating_add(1),
                )?;
                for (index, link) in outgoing.into_iter().enumerate() {
                    if index >= remaining {
                        builder.mark_partial();
                        break;
                    }
                    let target_node = match link.resolved_target_file_id.as_deref() {
                        Some(target_file_id) => self.resolved_graph_node(target_file_id)?,
                        None => unresolved_graph_node(&link.target_text),
                    };
                    builder.add_edge(
                        target_node,
                        LocalGraphEdge {
                            source_node_id: graph_file_node_id(&source_file_id),
                            target_node_id: link
                                .resolved_target_file_id
                                .as_deref()
                                .map(graph_file_node_id)
                                .unwrap_or_else(|| graph_unresolved_node_id(&link.target_text)),
                            target_text: link.target_text,
                            direction: LocalGraphEdgeDirection::Outgoing,
                            is_embed: link.is_embed,
                            hop: 2,
                        },
                    );
                }
            }
        }

        Ok(builder.finish(center_node_id))
    }

    fn resolved_graph_node(&self, file_id: &str) -> ReadApiResult<LocalGraphNode> {
        let label = self
            .metadata
            .get_file(file_id)?
            .map(|file| file.relative_path.display().to_string())
            .unwrap_or_else(|| file_id.to_string());
        Ok(LocalGraphNode {
            node_id: graph_file_node_id(file_id),
            file_id: Some(file_id.to_string()),
            label,
            kind: LocalGraphNodeKind::Resolved,
        })
    }

    pub(crate) fn page_from_overfetch<T>(&self, items: Vec<T>, page: PageRequest) -> ReadPage<T> {
        self.page_from_overfetch_with_limit(items, page, MAX_PAGE_LIMIT)
    }

    pub(crate) fn page_from_overfetch_with_limit<T>(
        &self,
        mut items: Vec<T>,
        page: PageRequest,
        max_limit: usize,
    ) -> ReadPage<T> {
        let visible_limit = page.visible_limit_capped(max_limit);
        let has_next = items.len() > visible_limit;
        if has_next {
            items.truncate(visible_limit);
        }
        ReadPage {
            request_id: page.request_id,
            generation: self.generation,
            items,
            next_offset: has_next.then_some(page.offset + visible_limit),
            state: if has_next {
                ReadState::Partial
            } else {
                ReadState::Complete
            },
        }
    }
}

pub fn expected_read_schema_metadata() -> IndexSchemaMetadata {
    IndexSchemaMetadata::new(
        READ_BACKEND_NAME,
        READ_BACKEND_VERSION,
        READ_TOKENIZER_CONFIG,
        0,
    )
}

pub fn open_metadata_store_for_read(
    metadata_path: impl AsRef<Path>,
) -> ReadOpenResult<(MetadataStore, u64)> {
    let metadata_path = metadata_path.as_ref();
    if metadata_path.as_os_str().is_empty() {
        return Err(ReadOpenError::InvalidInput("metadata_path"));
    }
    if !metadata_path.is_file() {
        return Err(ReadOpenError::MissingMetadata);
    }

    let expected = expected_read_schema_metadata();
    let (metadata, stored) = MetadataStore::open_existing_read_only(metadata_path, &expected)
        .map_err(ReadOpenError::from_metadata_open)?;
    Ok((metadata, stored.generation))
}

pub fn open_tantivy_index_for_read(
    tantivy_path: impl AsRef<Path>,
) -> ReadOpenResult<TantivySearchIndex> {
    let tantivy_path = tantivy_path.as_ref();
    if tantivy_path.as_os_str().is_empty() {
        return Err(ReadOpenError::InvalidInput("tantivy_path"));
    }
    if !tantivy_path.is_dir() {
        return Err(ReadOpenError::MissingTantivyIndex);
    }
    TantivySearchIndex::open_existing_dir(tantivy_path)
        .map_err(|_| ReadOpenError::MissingTantivyIndex)
}

pub fn open_vault_read_api(
    metadata_path: impl AsRef<Path>,
    tantivy_path: impl AsRef<Path>,
) -> ReadOpenResult<VaultReadApi> {
    let (metadata, generation) = open_metadata_store_for_read(metadata_path)?;
    let search = open_tantivy_index_for_read(tantivy_path)?;
    Ok(VaultReadApi::with_generation(metadata, search, generation))
}
