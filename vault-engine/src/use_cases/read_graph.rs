use std::{collections::HashSet, path::Path};

use crate::adapters::sqlite::{
    GraphFileRecord, GraphResolvedEdgeRecord, GraphUnresolvedEdgeRecord,
};

const MAX_GRAPH_NODES: usize = 250;
const MAX_GRAPH_EDGES: usize = 500;

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

    pub(crate) fn node_limit(self) -> usize {
        self.max_nodes.clamp(1, MAX_GRAPH_NODES)
    }

    pub(crate) fn edge_limit(self) -> usize {
        self.max_edges.clamp(1, MAX_GRAPH_EDGES)
    }
}

pub(crate) fn graph_candidate_files(
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
