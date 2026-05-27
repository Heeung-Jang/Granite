use crate::graph_key::unresolved_target_key;

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

pub(crate) struct LocalGraphBuild {
    pub(crate) graph: LocalGraph,
    pub(crate) partial: bool,
}

pub(crate) struct LocalGraphBuilder {
    node_limit: usize,
    edge_limit: usize,
    nodes: Vec<LocalGraphNode>,
    edges: Vec<LocalGraphEdge>,
    partial: bool,
}

impl LocalGraphBuilder {
    pub(crate) fn new(node_limit: usize, edge_limit: usize) -> Self {
        Self {
            node_limit,
            edge_limit,
            nodes: Vec::new(),
            edges: Vec::new(),
            partial: false,
        }
    }

    pub(crate) fn add_node(&mut self, node: LocalGraphNode) -> bool {
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

    pub(crate) fn add_edge(&mut self, node: LocalGraphNode, edge: LocalGraphEdge) {
        if self.edges.len() >= self.edge_limit {
            self.partial = true;
            return;
        }
        if !self.add_node(node) {
            return;
        }
        self.edges.push(edge);
    }

    pub(crate) fn edge_count(&self) -> usize {
        self.edges.len()
    }

    pub(crate) fn edge_limit_reached(&self) -> bool {
        self.edges.len() >= self.edge_limit
    }

    pub(crate) fn is_partial(&self) -> bool {
        self.partial
    }

    pub(crate) fn mark_partial(&mut self) {
        self.partial = true;
    }

    pub(crate) fn finish(self, center_node_id: String) -> LocalGraphBuild {
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

pub(crate) fn graph_file_node_id(file_id: &str) -> String {
    format!("file:{file_id}")
}

pub(crate) fn graph_unresolved_node_id(target_text: &str) -> String {
    format!("unresolved:{}", unresolved_target_key(target_text))
}

pub(crate) fn unresolved_graph_node(target_text: &str) -> LocalGraphNode {
    LocalGraphNode {
        node_id: graph_unresolved_node_id(target_text),
        file_id: None,
        label: target_text.to_string(),
        kind: LocalGraphNodeKind::Unresolved,
    }
}

pub(crate) fn push_frontier_file(frontier: &mut Vec<String>, center_file_id: &str, file_id: &str) {
    if file_id != center_file_id {
        frontier.push(file_id.to_string());
    }
}
