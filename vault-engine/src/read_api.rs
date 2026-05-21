use std::collections::HashSet;
use std::fmt;

use crate::graph::{
    WholeVaultGraphInputs, WholeVaultGraphRequest, WholeVaultGraphSnapshot,
    build_whole_vault_graph_snapshot, whole_vault_graph_needs_tags,
};
use crate::graph_key::unresolved_target_key;
use crate::index::{
    AttachmentRecord, FileRecord, GraphFileRecord, GraphResolvedEdgeRecord,
    GraphUnresolvedEdgeRecord, HeadingRecord, LinkEdgeRecord, MetadataStore, MetadataStoreError,
    PropertyRecord, TagRecord,
};
use crate::sqlite_fts::SearchResult;
use crate::tantivy_search::{TantivySearchError, TantivySearchIndex};

const MAX_PAGE_LIMIT: usize = 100;
const MAX_GRAPH_NODES: usize = 250;
const MAX_GRAPH_EDGES: usize = 500;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageRequest {
    pub request_id: u64,
    pub offset: usize,
    pub limit: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadPage<T> {
    pub request_id: u64,
    pub generation: u64,
    pub items: Vec<T>,
    pub next_offset: Option<usize>,
    pub state: ReadState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadValue<T> {
    pub request_id: u64,
    pub generation: u64,
    pub value: T,
    pub state: ReadState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadState {
    Complete,
    Partial,
    Stale,
    Cancelled,
    Error,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub file_id: String,
    pub path: String,
    pub title: String,
    pub rank: f64,
    pub snippet: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileOpenMetadata {
    pub file: FileRecord,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LocalGraphRequest {
    pub request_id: u64,
    pub max_nodes: usize,
    pub max_edges: usize,
    pub depth: LocalGraphDepth,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalGraphDepth {
    OneHop,
    TwoHop,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalGraph {
    pub center_node_id: String,
    pub nodes: Vec<LocalGraphNode>,
    pub edges: Vec<LocalGraphEdge>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalGraphNode {
    pub node_id: String,
    pub file_id: Option<String>,
    pub label: String,
    pub kind: LocalGraphNodeKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalGraphNodeKind {
    Center,
    Resolved,
    Unresolved,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalGraphEdge {
    pub source_node_id: String,
    pub target_node_id: String,
    pub target_text: String,
    pub direction: LocalGraphEdgeDirection,
    pub is_embed: bool,
    pub hop: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalGraphEdgeDirection {
    Outgoing,
    Backlink,
}

pub struct VaultReadApi {
    metadata: MetadataStore,
    search: TantivySearchIndex,
    generation: u64,
}

#[derive(Debug)]
pub enum ReadApiError {
    Metadata(MetadataStoreError),
    Search(TantivySearchError),
}

pub type ReadApiResult<T> = Result<T, ReadApiError>;

impl PageRequest {
    pub fn new(offset: usize, limit: usize) -> Self {
        Self::with_request_id(0, offset, limit)
    }

    pub fn with_request_id(request_id: u64, offset: usize, limit: usize) -> Self {
        Self {
            request_id,
            offset,
            limit,
        }
    }

    fn visible_limit(self) -> usize {
        self.limit.clamp(1, MAX_PAGE_LIMIT)
    }

    fn fetch_limit(self) -> usize {
        self.visible_limit() + 1
    }
}

impl LocalGraphRequest {
    pub fn new(max_nodes: usize, max_edges: usize) -> Self {
        Self::with_request_id(0, max_nodes, max_edges)
    }

    pub fn with_request_id(request_id: u64, max_nodes: usize, max_edges: usize) -> Self {
        Self::with_depth(request_id, max_nodes, max_edges, LocalGraphDepth::OneHop)
    }

    pub fn with_depth(
        request_id: u64,
        max_nodes: usize,
        max_edges: usize,
        depth: LocalGraphDepth,
    ) -> Self {
        Self {
            request_id,
            max_nodes,
            max_edges,
            depth,
        }
    }

    fn node_limit(self) -> usize {
        self.max_nodes.clamp(1, MAX_GRAPH_NODES)
    }

    fn edge_limit(self) -> usize {
        self.max_edges.clamp(1, MAX_GRAPH_EDGES)
    }
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

    pub fn file_tree(&self, page: PageRequest) -> ReadApiResult<ReadPage<FileRecord>> {
        Ok(self.page_from_overfetch(
            self.metadata.list_files(page.offset, page.fetch_limit())?,
            page,
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

    pub fn whole_vault_graph(
        &self,
        request: WholeVaultGraphRequest,
    ) -> ReadApiResult<ReadValue<WholeVaultGraphSnapshot>> {
        let edge_fetch_limit = request.edge_limit().saturating_add(1);
        let node_fetch_limit = request.node_limit().saturating_add(1);
        let all_files = self
            .metadata
            .graph_files(self.generation, node_fetch_limit)?;
        let has_all_files = all_files.len() < node_fetch_limit;
        let resolved_edges = if has_all_files {
            self.metadata
                .graph_resolved_edges_compact(self.generation, edge_fetch_limit)?
        } else {
            self.metadata
                .graph_resolved_edges(self.generation, edge_fetch_limit)?
        };
        let unresolved_edges = if request.include_unresolved {
            self.metadata
                .graph_unresolved_edges(self.generation, edge_fetch_limit)?
        } else {
            Vec::new()
        };
        let orphan_files = if request.include_orphans {
            self.metadata.graph_orphan_files(
                self.generation,
                request.include_unresolved,
                node_fetch_limit,
            )?
        } else {
            Vec::new()
        };
        let files = if has_all_files {
            all_files
        } else {
            graph_candidate_files(
                &resolved_edges,
                &unresolved_edges,
                &orphan_files,
                node_fetch_limit,
            )
        };
        let tags = if whole_vault_graph_needs_tags(request) {
            let file_ids = files
                .iter()
                .map(|file| file.file_id.clone())
                .collect::<Vec<_>>();
            self.metadata
                .graph_tags_for_files(&file_ids, request.tag_limit().saturating_add(1))?
        } else {
            Vec::new()
        };
        let node_count_total = self.metadata.graph_visible_node_count(
            self.generation,
            request.include_unresolved,
            request.include_orphans,
        )?;
        let edge_count_total = self
            .metadata
            .graph_visible_edge_count(self.generation, request.include_unresolved)?;
        let inputs = WholeVaultGraphInputs {
            node_count_total,
            edge_count_total,
            files,
            resolved_edges,
            unresolved_edges,
            orphan_files,
            tags,
        };
        let graph = build_whole_vault_graph_snapshot(request, self.generation, inputs);
        Ok(ReadValue {
            request_id: request.request_id,
            generation: self.generation,
            state: if graph.partial {
                ReadState::Partial
            } else {
                ReadState::Complete
            },
            value: graph.snapshot,
        })
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

    fn page_from_overfetch<T>(&self, mut items: Vec<T>, page: PageRequest) -> ReadPage<T> {
        let visible_limit = page.visible_limit();
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
            let remaining = edge_limit.saturating_sub(builder.edges.len());
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
                let remaining = edge_limit.saturating_sub(builder.edges.len());
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
}

struct LocalGraphBuild {
    graph: LocalGraph,
    partial: bool,
}

struct LocalGraphBuilder {
    node_limit: usize,
    edge_limit: usize,
    nodes: Vec<LocalGraphNode>,
    edges: Vec<LocalGraphEdge>,
    partial: bool,
}

impl LocalGraphBuilder {
    fn new(node_limit: usize, edge_limit: usize) -> Self {
        Self {
            node_limit,
            edge_limit,
            nodes: Vec::new(),
            edges: Vec::new(),
            partial: false,
        }
    }

    fn add_node(&mut self, node: LocalGraphNode) -> bool {
        if self
            .nodes
            .iter()
            .any(|existing| existing.node_id == node.node_id)
        {
            return true;
        }
        if self.nodes.len() >= self.node_limit {
            self.partial = true;
            return false;
        }
        self.nodes.push(node);
        true
    }

    fn add_edge(&mut self, node: LocalGraphNode, edge: LocalGraphEdge) {
        if self.edges.len() >= self.edge_limit {
            self.partial = true;
            return;
        }
        if !self.add_node(node) {
            return;
        }
        self.edges.push(edge);
    }

    fn edge_limit_reached(&self) -> bool {
        self.edges.len() >= self.edge_limit
    }

    fn is_partial(&self) -> bool {
        self.partial
    }

    fn mark_partial(&mut self) {
        self.partial = true;
    }

    fn finish(self, center_node_id: String) -> LocalGraphBuild {
        LocalGraphBuild {
            graph: LocalGraph {
                center_node_id,
                nodes: self.nodes,
                edges: self.edges,
            },
            partial: self.partial,
        }
    }
}

fn graph_file_node_id(file_id: &str) -> String {
    format!("file:{file_id}")
}

fn graph_unresolved_node_id(target_text: &str) -> String {
    format!("unresolved:{}", unresolved_target_key(target_text))
}

fn unresolved_graph_node(target_text: &str) -> LocalGraphNode {
    LocalGraphNode {
        node_id: graph_unresolved_node_id(target_text),
        file_id: None,
        label: target_text.to_string(),
        kind: LocalGraphNodeKind::Unresolved,
    }
}

fn push_frontier_file(frontier: &mut Vec<String>, center_file_id: &str, file_id: &str) {
    if file_id != center_file_id {
        frontier.push(file_id.to_string());
    }
}

fn graph_candidate_files(
    resolved_edges: &[GraphResolvedEdgeRecord],
    unresolved_edges: &[GraphUnresolvedEdgeRecord],
    orphan_files: &[GraphFileRecord],
    limit: usize,
) -> Vec<GraphFileRecord> {
    let mut seen = HashSet::new();
    let mut files = Vec::new();

    for edge in resolved_edges {
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &edge.source_file_id,
            &edge.source_relative_path,
        );
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &edge.target_file_id,
            &edge.target_relative_path,
        );
    }
    for edge in unresolved_edges {
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &edge.source_file_id,
            &edge.source_relative_path,
        );
    }
    for file in orphan_files {
        push_graph_candidate_file(
            &mut files,
            &mut seen,
            limit,
            &file.file_id,
            &file.relative_path,
        );
    }

    files
}

fn push_graph_candidate_file(
    files: &mut Vec<GraphFileRecord>,
    seen: &mut HashSet<String>,
    limit: usize,
    file_id: &str,
    relative_path: &std::path::Path,
) {
    if files.len() >= limit || !seen.insert(file_id.to_string()) {
        return;
    }
    files.push(GraphFileRecord {
        file_id: file_id.to_string(),
        relative_path: relative_path.to_path_buf(),
    });
}

impl fmt::Display for ReadApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Metadata(error) => write!(formatter, "read api metadata error: {error}"),
            Self::Search(error) => write!(formatter, "read api search error: {error}"),
        }
    }
}

impl std::error::Error for ReadApiError {}

impl From<MetadataStoreError> for ReadApiError {
    fn from(error: MetadataStoreError) -> Self {
        Self::Metadata(error)
    }
}

impl From<TantivySearchError> for ReadApiError {
    fn from(error: TantivySearchError) -> Self {
        Self::Search(error)
    }
}

impl From<SearchResult> for SearchHit {
    fn from(result: SearchResult) -> Self {
        Self {
            file_id: result.file_id,
            path: result.path,
            title: result.title,
            rank: result.rank,
            snippet: result.snippet,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
    use crate::index::{
        HeadingRecord, IndexSchemaMetadata, MetadataStore, PropertyRecord, TagRecord, TagSource,
        slugify_heading,
    };
    use crate::parser::PropertyValue;
    use crate::paths::{VaultRoot, lookup_key};
    use crate::scanner::{ScanEntry, scan_vault};
    use crate::sqlite_fts::SearchDocument;
    use crate::tantivy_search::TantivySearchIndex;

    #[test]
    fn read_api_returns_paginated_metadata_and_search_states() {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut search = TantivySearchIndex::open_in_ram().expect("search");

        let mut home = crate::index::FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target =
            crate::index::FileRecord::from_scan_entry(&fixture_entry("Folder/Target.md"), 1);
        target.mark_search_indexed();
        let mut guide =
            crate::index::FileRecord::from_scan_entry(&fixture_entry("Docs/Guide.md"), 1);
        guide.mark_search_indexed();

        let link = crate::index::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: Some("Details".to_string()),
            alias: None,
            is_embed: false,
        };
        let unresolved_link = crate::index::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Missing Note".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: None,
            is_embed: false,
        };
        let backlink = crate::index::LinkEdgeRecord {
            source_file_id: target.file_id.clone(),
            target_text: "Home".to_string(),
            resolved_target_file_id: Some(home.file_id.clone()),
            heading: None,
            alias: Some("Home alias".to_string()),
            is_embed: true,
        };
        let deep_link = crate::index::LinkEdgeRecord {
            source_file_id: target.file_id.clone(),
            target_text: "Docs/Guide".to_string(),
            resolved_target_file_id: Some(guide.file_id.clone()),
            heading: None,
            alias: None,
            is_embed: false,
        };
        let tag = TagRecord {
            file_id: home.file_id.clone(),
            tag: "project/native".to_string(),
            source: TagSource::Inline,
        };
        let property = PropertyRecord::from_property_value(
            home.file_id.clone(),
            "status",
            &PropertyValue::String("active".to_string()),
        );
        let heading = HeadingRecord {
            file_id: home.file_id.clone(),
            slug: slugify_heading("Home"),
            title: "Home".to_string(),
            level: 1,
            byte_offset: Some(0),
        };
        let attachment = AttachmentRecord {
            source_file_id: home.file_id.clone(),
            source: AttachmentReferenceSource::WikiEmbed,
            raw_target: "attachments/diagram.svg".to_string(),
            state: AttachmentResolutionState::Resolved {
                relative_path: PathBuf::from("attachments/diagram.svg"),
            },
        };

        store
            .replace_file_records(
                &home,
                &[link.clone(), unresolved_link.clone()],
                std::slice::from_ref(&tag),
                std::slice::from_ref(&property),
                std::slice::from_ref(&heading),
                std::slice::from_ref(&attachment),
            )
            .expect("home records");
        store
            .replace_file_records(
                &target,
                &[deep_link.clone(), backlink.clone()],
                &[],
                &[],
                &[],
                &[],
            )
            .expect("target records");
        store
            .replace_file_records(&guide, &[], &[], &[], &[], &[])
            .expect("guide records");
        search
            .replace_documents(&[
                SearchDocument {
                    file_id: home.file_id.clone(),
                    path: "Home.md".to_string(),
                    title: "Home".to_string(),
                    body: "Home body mentions compatibility and native search.".to_string(),
                },
                SearchDocument {
                    file_id: target.file_id.clone(),
                    path: "Folder/Target.md".to_string(),
                    title: "Target".to_string(),
                    body: "Target body receives backlinks.".to_string(),
                },
                SearchDocument {
                    file_id: guide.file_id.clone(),
                    path: "Docs/Guide.md".to_string(),
                    title: "Guide".to_string(),
                    body: "Guide body is a second hop target.".to_string(),
                },
            ])
            .expect("index");

        let api = VaultReadApi::with_generation(store, search, 1);
        let first_file = api
            .file_tree(PageRequest::with_request_id(42, 0, 1))
            .expect("first file page");
        assert_eq!(first_file.request_id, 42);
        assert_eq!(first_file.generation, 1);
        assert_eq!(first_file.state, ReadState::Partial);
        assert_eq!(first_file.next_offset, Some(1));
        let open = api
            .file_open_metadata_with_request(43, &home.file_id)
            .expect("open metadata");
        assert_eq!(open.request_id, 43);
        assert_eq!(open.generation, 1);
        assert_eq!(open.state, ReadState::Complete);
        assert_eq!(
            open.value.expect("file").file.file_id,
            lookup_key("Home.md")
        );

        assert_eq!(
            api.file_name_search("Home", PageRequest::with_request_id(44, 0, 10))
                .expect("file name search")
                .state,
            ReadState::Complete
        );
        assert!(
            api.body_search("compatibility", PageRequest::new(0, 10))
                .expect("body search")
                .items
                .iter()
                .any(|hit| hit.file_id == home.file_id)
        );
        assert_eq!(
            api.body_search("!!!", PageRequest::new(0, 10))
                .expect("empty query")
                .state,
            ReadState::Error
        );
        assert_eq!(
            api.outgoing_links(&home.file_id, PageRequest::new(0, 10))
                .expect("outgoing")
                .items,
            vec![link.clone(), unresolved_link.clone()]
        );
        assert_eq!(
            api.backlinks(&target.file_id, PageRequest::new(0, 10))
                .expect("backlinks")
                .items,
            vec![link]
        );
        assert_eq!(
            api.backlinks(&home.file_id, PageRequest::new(0, 10))
                .expect("home backlinks")
                .items,
            vec![backlink.clone()]
        );
        assert_eq!(
            api.tags(&home.file_id, PageRequest::new(0, 10))
                .expect("tags")
                .items,
            vec![tag]
        );
        assert_eq!(
            api.properties(&home.file_id, PageRequest::new(0, 10))
                .expect("properties")
                .items,
            vec![property]
        );
        assert_eq!(
            api.headings(&home.file_id, PageRequest::new(0, 10))
                .expect("headings")
                .items,
            vec![heading]
        );
        assert_eq!(
            api.attachments(&home.file_id, PageRequest::new(0, 10))
                .expect("attachments")
                .items,
            vec![attachment]
        );

        let graph = api
            .local_graph(
                &home.file_id,
                LocalGraphRequest::with_request_id(60, 10, 10),
            )
            .expect("local graph");
        assert_eq!(graph.request_id, 60);
        assert_eq!(graph.generation, 1);
        assert_eq!(graph.state, ReadState::Complete);
        assert_eq!(
            graph.value.center_node_id,
            graph_file_node_id(&home.file_id)
        );
        assert!(graph.value.nodes.iter().any(|node| {
            node.node_id == graph_file_node_id(&home.file_id)
                && node.kind == LocalGraphNodeKind::Center
        }));
        assert!(graph.value.nodes.iter().any(|node| {
            node.node_id == graph_file_node_id(&target.file_id)
                && node.kind == LocalGraphNodeKind::Resolved
                && node.label == "Folder/Target.md"
        }));
        assert!(graph.value.nodes.iter().any(|node| {
            node.node_id == graph_unresolved_node_id("Missing Note")
                && node.kind == LocalGraphNodeKind::Unresolved
        }));
        assert_eq!(graph.value.nodes.len(), 3);
        assert_eq!(graph.value.edges.len(), 3);
        assert!(graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Outgoing
                && edge.source_node_id == graph_file_node_id(&home.file_id)
                && edge.target_node_id == graph_file_node_id(&target.file_id)
                && edge.hop == 1
        }));
        assert!(graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Outgoing
                && edge.target_node_id == graph_unresolved_node_id("Missing Note")
                && edge.hop == 1
        }));
        assert!(graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Backlink
                && edge.source_node_id == graph_file_node_id(&target.file_id)
                && edge.target_node_id == graph_file_node_id(&home.file_id)
                && edge.is_embed
                && edge.hop == 1
        }));

        let two_hop_graph = api
            .local_graph(
                &home.file_id,
                LocalGraphRequest::with_depth(61, 10, 10, LocalGraphDepth::TwoHop),
            )
            .expect("two hop graph");
        assert_eq!(two_hop_graph.request_id, 61);
        assert_eq!(two_hop_graph.state, ReadState::Complete);
        assert!(two_hop_graph.value.nodes.iter().any(|node| {
            node.node_id == graph_file_node_id(&guide.file_id)
                && node.kind == LocalGraphNodeKind::Resolved
                && node.label == "Docs/Guide.md"
        }));
        assert!(two_hop_graph.value.edges.iter().any(|edge| {
            edge.direction == LocalGraphEdgeDirection::Outgoing
                && edge.source_node_id == graph_file_node_id(&target.file_id)
                && edge.target_node_id == graph_file_node_id(&guide.file_id)
                && edge.hop == 2
        }));

        let node_capped = api
            .local_graph(&home.file_id, LocalGraphRequest::new(2, 10))
            .expect("node capped graph");
        assert_eq!(node_capped.state, ReadState::Partial);
        assert_eq!(node_capped.value.nodes.len(), 2);

        let edge_capped = api
            .local_graph(&home.file_id, LocalGraphRequest::new(10, 1))
            .expect("edge capped graph");
        assert_eq!(edge_capped.state, ReadState::Partial);
        assert_eq!(edge_capped.value.edges.len(), 1);

        let whole_graph = api
            .whole_vault_graph(WholeVaultGraphRequest::with_request_id(62, 10, 10))
            .expect("whole vault graph");
        assert_eq!(whole_graph.request_id, 62);
        assert_eq!(whole_graph.generation, 1);
        assert_eq!(whole_graph.state, ReadState::Complete);
        assert_eq!(whole_graph.value.nodes.len(), 3);
        assert_eq!(whole_graph.value.edges.len(), 3);
        assert!(whole_graph.value.nodes.iter().any(|node| {
            node.file_id.is_none()
                && node.relative_path.as_deref() == Some("Home.md")
                && node.label == "Home"
                && node.tags.is_empty()
        }));
        assert!(whole_graph.value.nodes.iter().any(|node| {
            node.file_id.is_none()
                && node.relative_path.as_deref() == Some("Docs/Guide.md")
                && node.label == "Guide"
        }));
        assert!(whole_graph.value.edges.iter().any(|edge| edge.weight == 1));

        let whole_graph_with_group_metadata = api
            .whole_vault_graph(
                WholeVaultGraphRequest::with_request_id(64, 10, 10)
                    .with_group_limits(1, 100, 10, 100),
            )
            .expect("whole vault graph with group metadata");
        assert!(
            whole_graph_with_group_metadata
                .value
                .nodes
                .iter()
                .any(|node| {
                    node.relative_path.as_deref() == Some("Home.md")
                        && node.tags == vec!["project/native"]
                })
        );

        let whole_with_unresolved = api
            .whole_vault_graph(
                WholeVaultGraphRequest::with_request_id(63, 10, 10).including_unresolved(true),
            )
            .expect("whole vault graph with unresolved");
        assert_eq!(whole_with_unresolved.state, ReadState::Complete);
        assert!(
            whole_with_unresolved
                .value
                .nodes
                .iter()
                .any(|node| node.file_id.is_none())
        );
    }

    fn fixture_entry(relative_path: &str) -> ScanEntry {
        let root_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("fixtures")
            .join("compatibility-vault");
        let root = VaultRoot::open(root_path).expect("root");
        let scan = scan_vault(&root).expect("scan");
        scan.entries
            .into_iter()
            .find(|entry| entry.relative_path == PathBuf::from(relative_path))
            .expect("fixture entry")
    }
}
