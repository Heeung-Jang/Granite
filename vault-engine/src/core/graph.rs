use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WholeVaultGraphRequest {
    pub request_id: u64,
    pub include_unresolved: bool,
    pub include_orphans: bool,
    pub max_nodes: usize,
    pub max_edges: usize,
    pub max_label_bytes: usize,
    pub max_tags_per_node: usize,
    pub max_groups: usize,
    pub max_rule_length: usize,
    pub group_rule_count: usize,
    pub longest_group_rule_length: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WholeVaultGraphSnapshot {
    pub request_id: u64,
    pub generation: u64,
    pub partial_reasons: Vec<WholeVaultGraphPartialReason>,
    pub node_count_total: usize,
    pub edge_count_total: usize,
    pub nodes: Vec<WholeVaultGraphNode>,
    pub edges: Vec<WholeVaultGraphEdge>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WholeVaultGraphNode {
    pub node_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relative_path: Option<String>,
    pub label: String,
    pub kind: WholeVaultGraphNodeKind,
    pub degree: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum WholeVaultGraphNodeKind {
    Resolved,
    Unresolved,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WholeVaultGraphEdge {
    pub source_node_id: String,
    pub target_node_id: String,
    pub kind: WholeVaultGraphEdgeKind,
    pub weight: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum WholeVaultGraphEdgeKind {
    Resolved,
    Unresolved,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum WholeVaultGraphPartialReason {
    MaxNodes,
    MaxEdges,
    MaxLabelBytes,
    MaxTagsPerNode,
    MaxGroups,
    MaxRuleLength,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WholeVaultGraphBuild {
    pub snapshot: WholeVaultGraphSnapshot,
    pub partial: bool,
}
