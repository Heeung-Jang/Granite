use std::{collections::HashSet, fmt, path::Path};

use crate::adapters::sqlite::{
    AttachmentProjection, AttachmentRecord, FileLookupProjection, FileRecord, GraphFileRecord,
    GraphResolvedEdgeRecord, GraphUnresolvedEdgeRecord, HeadingRecord, LinkEdgeRecord,
    LinkProjection, MetadataStoreError, PropertyProjection, PropertyRecord, TagRecord,
};
use crate::adapters::tantivy::TantivySearchError;
use crate::graph::{
    WholeVaultGraphInputs, WholeVaultGraphRequest, WholeVaultGraphSnapshot,
    build_whole_vault_graph_snapshot, whole_vault_graph_needs_tags,
};
use crate::graph_key::unresolved_target_key;
use crate::parser::{MarkdownLink, PropertyValue, WikiLink, parse_markdown};
use crate::scanner::{ScanEntryKind, classify_file};
use crate::sqlite_fts::SearchResult;
use crate::use_cases::read_types::MAX_PAGE_LIMIT;
pub use crate::use_cases::read_types::{
    ENGINE_READ_STATE_CANCELLED, ENGINE_READ_STATE_COMPLETE, ENGINE_READ_STATE_ERROR,
    ENGINE_READ_STATE_INDEX_UNAVAILABLE, ENGINE_READ_STATE_PARTIAL, ENGINE_READ_STATE_STALE,
    PageRequest, ReadOpenError, ReadOpenResult, ReadPage, ReadState, ReadValue,
};
pub use crate::use_cases::read_vault::{
    VaultReadApi, expected_read_schema_metadata, open_metadata_store_for_read,
    open_tantivy_index_for_read, open_vault_read_api,
};

const MAX_GRAPH_NODES: usize = 250;
const MAX_GRAPH_EDGES: usize = 500;
pub const READ_BACKEND_NAME: &str = "sqlite+tantivy";
pub const READ_BACKEND_VERSION: &str = "metadata-v2";
pub const READ_TOKENIZER_CONFIG: &str = "tantivy";
pub const ENGINE_READ_SEARCH_MODE_FILE_NAME: u32 = 1;
pub const ENGINE_READ_SEARCH_MODE_BODY: u32 = 2;
pub const ENGINE_READ_INSPECTOR_PANEL_BACKLINKS: u32 = 1;
pub const ENGINE_READ_INSPECTOR_PANEL_OUTGOING: u32 = 2;
pub const ENGINE_READ_INSPECTOR_PANEL_TAGS: u32 = 3;
pub const ENGINE_READ_INSPECTOR_PANEL_PROPERTIES: u32 = 4;
pub const ENGINE_READ_INSPECTOR_PANEL_ATTACHMENTS: u32 = 5;
pub const ENGINE_READ_LOCAL_GRAPH_DEPTH_ONE_HOP: u32 = 1;
pub const ENGINE_READ_LOCAL_GRAPH_DEPTH_TWO_HOP: u32 = 2;

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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LivePreviewMetadataItem {
    pub kind: LivePreviewMetadataItemKind,
    pub key: String,
    pub value: String,
    pub resolved_file_id: Option<String>,
    pub resolved_relative_path: Option<String>,
    pub heading: Option<String>,
    pub alias: Option<String>,
    pub state: LivePreviewMetadataState,
    pub source: LivePreviewMetadataSource,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivePreviewMetadataItemKind {
    Property,
    Tag,
    Link,
    Attachment,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivePreviewMetadataState {
    None,
    Resolved,
    Missing,
    Remote,
    Rejected,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LivePreviewMetadataSource {
    None,
    Inline,
    WikiLink,
    MarkdownLink,
    WikiEmbed,
    MarkdownImage,
}

#[derive(Debug)]
pub enum ReadApiError {
    Metadata(MetadataStoreError),
    Search(TantivySearchError),
    InvalidInput(&'static str),
    NotFound(&'static str),
}

pub type ReadApiResult<T> = Result<T, ReadApiError>;

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

    pub fn local_graph_for_path(
        &self,
        relative_path: &str,
        request: LocalGraphRequest,
    ) -> ReadApiResult<ReadValue<LocalGraph>> {
        let file = self.require_file(relative_path)?;
        self.local_graph(&file.file_id, request)
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

    pub fn live_preview_metadata(
        &self,
        request_id: u64,
        relative_path: &str,
        contents: &str,
    ) -> ReadApiResult<ReadPage<LivePreviewMetadataItem>> {
        if relative_path.trim().is_empty() {
            return Err(ReadApiError::InvalidInput("relative_path"));
        }

        let parsed = parse_markdown(contents);
        let mut items = Vec::new();

        for (key, value) in &parsed.properties {
            items.push(LivePreviewMetadataItem {
                kind: LivePreviewMetadataItemKind::Property,
                key: key.clone(),
                value: display_property_value(value),
                resolved_file_id: None,
                resolved_relative_path: None,
                heading: None,
                alias: None,
                state: LivePreviewMetadataState::None,
                source: LivePreviewMetadataSource::None,
            });
        }

        for tag in &parsed.tags {
            items.push(LivePreviewMetadataItem {
                kind: LivePreviewMetadataItemKind::Tag,
                key: "tag".to_string(),
                value: tag.clone(),
                resolved_file_id: None,
                resolved_relative_path: None,
                heading: None,
                alias: None,
                state: LivePreviewMetadataState::None,
                source: LivePreviewMetadataSource::Inline,
            });
        }

        for link in &parsed.wikilinks {
            items.push(self.live_wiki_link_item(link)?);
        }

        for embed in &parsed.embeds {
            items.push(self.live_wiki_embed_item(embed)?);
        }

        for link in &parsed.markdown_links {
            items.push(self.live_markdown_link_item(relative_path, link)?);
        }

        let has_next = items.len() > MAX_PAGE_LIMIT;
        if has_next {
            items.truncate(MAX_PAGE_LIMIT);
        }

        Ok(ReadPage {
            request_id,
            generation: self.generation,
            items,
            next_offset: has_next.then_some(MAX_PAGE_LIMIT),
            state: if has_next {
                ReadState::Partial
            } else {
                ReadState::Complete
            },
        })
    }

    fn require_file(&self, relative_path: &str) -> ReadApiResult<FileLookupProjection> {
        if relative_path.trim().is_empty() {
            return Err(ReadApiError::InvalidInput("relative_path"));
        }
        self.metadata
            .lookup_file(relative_path)?
            .ok_or(ReadApiError::NotFound("relative_path"))
    }

    fn live_wiki_link_item(&self, link: &WikiLink) -> ReadApiResult<LivePreviewMetadataItem> {
        let resolved = self.resolve_wiki_target(&link.target)?;
        Ok(link_metadata_item(
            LivePreviewMetadataItemKind::Link,
            "wikilink",
            &link.target,
            resolved,
            link.heading.clone(),
            link.alias.clone(),
            LivePreviewMetadataSource::WikiLink,
        ))
    }

    fn live_wiki_embed_item(&self, embed: &WikiLink) -> ReadApiResult<LivePreviewMetadataItem> {
        let resolved = self.resolve_wiki_target(&embed.target)?;
        Ok(link_metadata_item(
            LivePreviewMetadataItemKind::Attachment,
            "embed",
            &embed.target,
            resolved,
            embed.heading.clone(),
            embed.alias.clone(),
            LivePreviewMetadataSource::WikiEmbed,
        ))
    }

    fn live_markdown_link_item(
        &self,
        relative_path: &str,
        link: &MarkdownLink,
    ) -> ReadApiResult<LivePreviewMetadataItem> {
        let target = link.target.split('#').next().unwrap_or(&link.target);
        let is_attachment =
            link.image || classify_file(Path::new(target)) == ScanEntryKind::Attachment;
        let resolved = self.resolve_markdown_target(relative_path, target)?;
        Ok(link_metadata_item(
            if is_attachment {
                LivePreviewMetadataItemKind::Attachment
            } else {
                LivePreviewMetadataItemKind::Link
            },
            if link.image { "image" } else { "markdown_link" },
            &link.target,
            resolved,
            None,
            Some(link.text.clone()),
            if link.image {
                LivePreviewMetadataSource::MarkdownImage
            } else {
                LivePreviewMetadataSource::MarkdownLink
            },
        ))
    }

    fn resolve_wiki_target(&self, target: &str) -> ReadApiResult<LivePreviewTargetResolution> {
        if is_remote_target(target) {
            return Ok(LivePreviewTargetResolution::remote());
        }
        if is_rejected_target(target) {
            return Ok(LivePreviewTargetResolution::rejected());
        }
        self.resolve_target_candidates(link_target_candidates(target))
    }

    fn resolve_markdown_target(
        &self,
        relative_path: &str,
        target: &str,
    ) -> ReadApiResult<LivePreviewTargetResolution> {
        if is_remote_target(target) {
            return Ok(LivePreviewTargetResolution::remote());
        }
        if is_rejected_target(target) {
            return Ok(LivePreviewTargetResolution::rejected());
        }

        let target_path = Path::new(relative_path)
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .join(target);
        self.resolve_target_candidates(path_target_candidates(&target_path))
    }

    fn resolve_target_candidates(
        &self,
        candidates: Vec<String>,
    ) -> ReadApiResult<LivePreviewTargetResolution> {
        if candidates.is_empty() {
            return Ok(LivePreviewTargetResolution::missing());
        }
        for candidate in candidates {
            if let Some(file) = self.metadata.lookup_file(&candidate)? {
                return Ok(LivePreviewTargetResolution::resolved(file));
            }
        }
        Ok(LivePreviewTargetResolution::missing())
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

struct LivePreviewTargetResolution {
    file: Option<FileLookupProjection>,
    state: LivePreviewMetadataState,
}

impl LivePreviewTargetResolution {
    fn resolved(file: FileLookupProjection) -> Self {
        Self {
            file: Some(file),
            state: LivePreviewMetadataState::Resolved,
        }
    }

    fn missing() -> Self {
        Self {
            file: None,
            state: LivePreviewMetadataState::Missing,
        }
    }

    fn remote() -> Self {
        Self {
            file: None,
            state: LivePreviewMetadataState::Remote,
        }
    }

    fn rejected() -> Self {
        Self {
            file: None,
            state: LivePreviewMetadataState::Rejected,
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
    relative_path: &Path,
) {
    if files.len() >= limit || !seen.insert(file_id.to_string()) {
        return;
    }
    files.push(GraphFileRecord {
        file_id: file_id.to_string(),
        relative_path: relative_path.to_path_buf(),
    });
}

fn display_property_value(value: &PropertyValue) -> String {
    match value {
        PropertyValue::String(value) => value.clone(),
        PropertyValue::Bool(value) => value.to_string(),
        PropertyValue::List(values) => values.join(", "),
    }
}

fn link_metadata_item(
    kind: LivePreviewMetadataItemKind,
    key: &str,
    value: &str,
    resolved: LivePreviewTargetResolution,
    heading: Option<String>,
    alias: Option<String>,
    source: LivePreviewMetadataSource,
) -> LivePreviewMetadataItem {
    LivePreviewMetadataItem {
        kind,
        key: key.to_string(),
        value: value.to_string(),
        resolved_file_id: resolved.file.as_ref().map(|file| file.file_id.clone()),
        resolved_relative_path: resolved.file.map(|file| file.display_path),
        heading,
        alias,
        state: resolved.state,
        source,
    }
}

fn link_target_candidates(target: &str) -> Vec<String> {
    let target = target.trim();
    if target.is_empty() {
        return Vec::new();
    }
    path_target_candidates(Path::new(target))
}

fn path_target_candidates(path: &Path) -> Vec<String> {
    let mut candidates = Vec::new();
    let value = path.to_string_lossy().trim().to_string();
    if value.is_empty() {
        return candidates;
    }
    candidates.push(value.clone());
    if path.extension().is_none() {
        candidates.push(format!("{value}.md"));
    }
    candidates
}

fn is_remote_target(target: &str) -> bool {
    target_scheme(target).is_some_and(|scheme| {
        scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https")
    })
}

fn is_rejected_target(target: &str) -> bool {
    target_scheme(target).is_some() && !is_remote_target(target)
}

fn target_scheme(target: &str) -> Option<&str> {
    let colon = target.find(':')?;
    let slash = target.find('/').unwrap_or(usize::MAX);
    (colon < slash).then(|| &target[..colon])
}

impl fmt::Display for ReadApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Metadata(error) => write!(formatter, "read api metadata error: {error}"),
            Self::Search(error) => write!(formatter, "read api search error: {error}"),
            Self::InvalidInput(field) => write!(formatter, "invalid read api input: {field}"),
            Self::NotFound(field) => write!(formatter, "read api target not found: {field}"),
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
    use std::{fs, path::PathBuf};

    use crate::adapters::sqlite::{
        FileRecord, HeadingRecord, IndexSchemaMetadata, MetadataStore, PropertyRecord, TagRecord,
        TagSource, slugify_heading,
    };
    use crate::adapters::tantivy::TantivySearchIndex;
    use crate::attachments::{AttachmentReferenceSource, AttachmentResolutionState};
    use crate::parser::PropertyValue;
    use crate::paths::{VaultRoot, lookup_key};
    use crate::scanner::{ScanEntry, ScanEntryKind, scan_vault};
    use crate::sqlite_fts::SearchDocument;
    use tempfile::tempdir;

    #[test]
    fn read_open_error_codes_are_stable() {
        let errors = [
            (ReadOpenError::MissingMetadata, "missing_metadata", 1),
            (ReadOpenError::CorruptMetadata, "corrupt_metadata", 2),
            (
                ReadOpenError::SchemaMismatch {
                    stored: 0,
                    expected: 1,
                },
                "schema_mismatch",
                3,
            ),
            (
                ReadOpenError::BackendMismatch {
                    stored_name: "sqlite-fts".to_string(),
                    stored_version: "metadata-v1".to_string(),
                    expected_name: READ_BACKEND_NAME.to_string(),
                    expected_version: READ_BACKEND_VERSION.to_string(),
                },
                "backend_mismatch",
                4,
            ),
            (
                ReadOpenError::TokenizerMismatch {
                    stored: "unicode61".to_string(),
                    expected: READ_TOKENIZER_CONFIG.to_string(),
                },
                "tokenizer_mismatch",
                5,
            ),
            (
                ReadOpenError::MissingTantivyIndex,
                "missing_tantivy_index",
                6,
            ),
            (
                ReadOpenError::InvalidInput("metadata_path"),
                "invalid_input",
                7,
            ),
            (ReadOpenError::Panic, "panic", 8),
        ];

        for (error, code, numeric_code) in errors {
            assert_eq!(error.abi_code(), code);
            assert_eq!(error.abi_numeric_code(), numeric_code);
        }
    }

    #[test]
    fn read_state_abi_constants_are_stable() {
        assert_eq!(ENGINE_READ_STATE_COMPLETE, 0);
        assert_eq!(ENGINE_READ_STATE_PARTIAL, 1);
        assert_eq!(ENGINE_READ_STATE_STALE, 2);
        assert_eq!(ENGINE_READ_STATE_CANCELLED, 3);
        assert_eq!(ENGINE_READ_STATE_ERROR, 4);
        assert_eq!(ENGINE_READ_STATE_INDEX_UNAVAILABLE, 5);
    }

    #[test]
    fn metadata_read_open_preserves_stored_generation() {
        let dir = tempdir().expect("tempdir");
        let metadata_path = dir.path().join("metadata.sqlite");
        let metadata = IndexSchemaMetadata::new(
            READ_BACKEND_NAME,
            READ_BACKEND_VERSION,
            READ_TOKENIZER_CONFIG,
            7,
        );
        let store = MetadataStore::open(&metadata_path, &metadata).expect("store");
        drop(store);

        let (_store, generation) =
            open_metadata_store_for_read(&metadata_path).expect("open metadata");

        assert_eq!(generation, 7);
    }

    #[test]
    fn metadata_read_open_reports_missing_corrupt_and_schema_mismatch() {
        let dir = tempdir().expect("tempdir");
        let missing_path = dir.path().join("missing.sqlite");
        assert_eq!(
            open_metadata_store_for_read(&missing_path)
                .err()
                .expect("missing"),
            ReadOpenError::MissingMetadata
        );

        let corrupt_path = dir.path().join("corrupt.sqlite");
        fs::write(&corrupt_path, b"not sqlite").expect("corrupt");
        assert_eq!(
            open_metadata_store_for_read(&corrupt_path)
                .err()
                .expect("corrupt"),
            ReadOpenError::CorruptMetadata
        );

        let schema_path = dir.path().join("schema.sqlite");
        let metadata = IndexSchemaMetadata::new(
            READ_BACKEND_NAME,
            READ_BACKEND_VERSION,
            READ_TOKENIZER_CONFIG,
            3,
        );
        let store = MetadataStore::open(&schema_path, &metadata).expect("store");
        drop(store);
        let connection = rusqlite::Connection::open(&schema_path).expect("connection");
        connection
            .execute(
                "UPDATE index_metadata SET value = '1' WHERE key = 'schema_version'",
                [],
            )
            .expect("schema version update");
        drop(connection);

        assert_eq!(
            open_metadata_store_for_read(&schema_path)
                .err()
                .expect("schema"),
            ReadOpenError::SchemaMismatch {
                stored: 1,
                expected: 2
            }
        );
    }

    #[test]
    fn tantivy_read_open_reports_missing_and_opens_existing_index() {
        let dir = tempdir().expect("tempdir");
        let missing_path = dir.path().join("missing-tantivy");
        assert_eq!(
            open_tantivy_index_for_read(&missing_path)
                .err()
                .expect("missing"),
            ReadOpenError::MissingTantivyIndex
        );

        let index_path = dir.path().join("tantivy");
        let mut index = TantivySearchIndex::open_in_dir(&index_path).expect("create index");
        index
            .replace_documents(&[SearchDocument {
                file_id: "home".to_string(),
                path: "Home.md".to_string(),
                title: "Home".to_string(),
                body: "searchable body".to_string(),
            }])
            .expect("write index");
        drop(index);

        let index = open_tantivy_index_for_read(&index_path).expect("open index");

        assert_eq!(index.search("searchable", 10).expect("search").len(), 1);
    }

    #[test]
    fn file_tree_allows_large_markdown_pages_without_attachment_rows() {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        for index in 0..150 {
            let mut file = FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
            file.relative_path = PathBuf::from(format!("Bulk/{index:03}.md"));
            file.file_id = lookup_key(&file.relative_path);
            file.file_identity.inode = index as u64 + 1;
            store
                .replace_file_records(&file, &[], &[], &[], &[], &[])
                .expect("markdown file");
        }
        let attachment = FileRecord::from_scan_entry(&fixture_entry("attachments/diagram.svg"), 1);
        store
            .replace_file_records(&attachment, &[], &[], &[], &[], &[])
            .expect("attachment file");
        let search = TantivySearchIndex::open_in_ram().expect("search");
        let api = VaultReadApi::with_generation(store, search, 1);

        let page = api
            .file_tree_projection(PageRequest::with_request_id(90, 0, 150))
            .expect("file tree");

        assert_eq!(page.request_id, 90);
        assert_eq!(page.state, ReadState::Complete);
        assert_eq!(page.items.len(), 150);
        assert!(page.next_offset.is_none());
        assert!(
            page.items
                .iter()
                .all(|item| item.file.kind == ScanEntryKind::Markdown)
        );
    }

    #[test]
    fn read_api_returns_paginated_metadata_and_search_states() {
        let metadata = IndexSchemaMetadata::new("sqlite+tantivy", "metadata-v1", "tantivy", 1);
        let mut store = MetadataStore::open_in_memory(&metadata).expect("store");
        let mut search = TantivySearchIndex::open_in_ram().expect("search");

        let mut home =
            crate::adapters::sqlite::FileRecord::from_scan_entry(&fixture_entry("Home.md"), 1);
        home.mark_search_indexed();
        let mut target = crate::adapters::sqlite::FileRecord::from_scan_entry(
            &fixture_entry("Folder/Target.md"),
            1,
        );
        target.mark_search_indexed();
        let mut guide = crate::adapters::sqlite::FileRecord::from_scan_entry(
            &fixture_entry("Docs/Guide.md"),
            1,
        );
        guide.mark_search_indexed();

        let link = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Folder/Target".to_string(),
            resolved_target_file_id: Some(target.file_id.clone()),
            heading: Some("Details".to_string()),
            alias: None,
            is_embed: false,
        };
        let unresolved_link = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: home.file_id.clone(),
            target_text: "Missing Note".to_string(),
            resolved_target_file_id: None,
            heading: None,
            alias: None,
            is_embed: false,
        };
        let backlink = crate::adapters::sqlite::LinkEdgeRecord {
            source_file_id: target.file_id.clone(),
            target_text: "Home".to_string(),
            resolved_target_file_id: Some(home.file_id.clone()),
            heading: None,
            alias: Some("Home alias".to_string()),
            is_embed: true,
        };
        let deep_link = crate::adapters::sqlite::LinkEdgeRecord {
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
