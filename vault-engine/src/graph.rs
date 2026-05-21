use std::collections::{HashMap, HashSet};

use crate::graph_key::unresolved_target_key;
use crate::index::{
    GraphFileRecord, GraphResolvedEdgeRecord, GraphTagRecord, GraphUnresolvedEdgeRecord,
};
use serde::Serialize;

pub const MAX_WHOLE_VAULT_GRAPH_NODES: usize = 100_000;
pub const MAX_WHOLE_VAULT_GRAPH_EDGES: usize = 250_000;
pub const MAX_WHOLE_VAULT_GRAPH_LABEL_BYTES: usize = 512;
pub const MAX_WHOLE_VAULT_GRAPH_TAGS_PER_NODE: usize = 32;
pub const MAX_WHOLE_VAULT_GRAPH_GROUPS: usize = 32;
pub const MAX_WHOLE_VAULT_GRAPH_RULE_LENGTH: usize = 512;

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
    pub file_id: Option<String>,
    pub label: String,
    pub kind: WholeVaultGraphNodeKind,
    pub degree: usize,
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
pub struct WholeVaultGraphInputs {
    pub node_count_total: usize,
    pub edge_count_total: usize,
    pub files: Vec<GraphFileRecord>,
    pub resolved_edges: Vec<GraphResolvedEdgeRecord>,
    pub unresolved_edges: Vec<GraphUnresolvedEdgeRecord>,
    pub orphan_files: Vec<GraphFileRecord>,
    pub tags: Vec<GraphTagRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WholeVaultGraphBuild {
    pub snapshot: WholeVaultGraphSnapshot,
    pub partial: bool,
}

impl WholeVaultGraphRequest {
    pub fn new(max_nodes: usize, max_edges: usize) -> Self {
        Self::with_request_id(0, max_nodes, max_edges)
    }

    pub fn with_request_id(request_id: u64, max_nodes: usize, max_edges: usize) -> Self {
        Self {
            request_id,
            include_unresolved: false,
            include_orphans: false,
            max_nodes,
            max_edges,
            max_label_bytes: MAX_WHOLE_VAULT_GRAPH_LABEL_BYTES,
            max_tags_per_node: MAX_WHOLE_VAULT_GRAPH_TAGS_PER_NODE,
            max_groups: MAX_WHOLE_VAULT_GRAPH_GROUPS,
            max_rule_length: MAX_WHOLE_VAULT_GRAPH_RULE_LENGTH,
            group_rule_count: 0,
            longest_group_rule_length: 0,
        }
    }

    pub fn including_unresolved(mut self, include_unresolved: bool) -> Self {
        self.include_unresolved = include_unresolved;
        self
    }

    pub fn including_orphans(mut self, include_orphans: bool) -> Self {
        self.include_orphans = include_orphans;
        self
    }

    pub fn with_label_limit(mut self, max_label_bytes: usize) -> Self {
        self.max_label_bytes = max_label_bytes;
        self
    }

    pub fn with_tag_limit(mut self, max_tags_per_node: usize) -> Self {
        self.max_tags_per_node = max_tags_per_node;
        self
    }

    pub fn with_group_limits(
        mut self,
        max_groups: usize,
        group_rule_count: usize,
        max_rule_length: usize,
        longest_group_rule_length: usize,
    ) -> Self {
        self.max_groups = max_groups;
        self.group_rule_count = group_rule_count;
        self.max_rule_length = max_rule_length;
        self.longest_group_rule_length = longest_group_rule_length;
        self
    }

    pub fn node_limit(self) -> usize {
        self.max_nodes.clamp(1, MAX_WHOLE_VAULT_GRAPH_NODES)
    }

    pub fn edge_limit(self) -> usize {
        self.max_edges.clamp(1, MAX_WHOLE_VAULT_GRAPH_EDGES)
    }

    pub fn label_limit(self) -> usize {
        self.max_label_bytes
            .clamp(1, MAX_WHOLE_VAULT_GRAPH_LABEL_BYTES)
    }

    pub fn tag_limit(self) -> usize {
        self.max_tags_per_node
            .clamp(0, MAX_WHOLE_VAULT_GRAPH_TAGS_PER_NODE)
    }

    fn group_limit(self) -> usize {
        self.max_groups.min(MAX_WHOLE_VAULT_GRAPH_GROUPS)
    }

    fn rule_length_limit(self) -> usize {
        self.max_rule_length.min(MAX_WHOLE_VAULT_GRAPH_RULE_LENGTH)
    }
}

pub fn build_whole_vault_graph_snapshot(
    request: WholeVaultGraphRequest,
    generation: u64,
    inputs: WholeVaultGraphInputs,
) -> WholeVaultGraphBuild {
    let files_by_id: HashMap<String, GraphFileRecord> = inputs
        .files
        .iter()
        .cloned()
        .map(|file| (file.file_id.clone(), file))
        .collect();
    let degree_by_file = degree_by_file(&inputs.resolved_edges, &inputs.unresolved_edges, request);
    let node_count_total = inputs.node_count_total;
    let edge_count_total = inputs.edge_count_total;
    let tags_by_file = tags_by_file(inputs.tags);

    let mut builder = SnapshotBuilder::new(
        request,
        generation,
        node_count_total,
        edge_count_total,
        &files_by_id,
        &tags_by_file,
        &degree_by_file,
    );

    if request.group_rule_count > request.group_limit() {
        builder.add_partial_reason(WholeVaultGraphPartialReason::MaxGroups);
    }
    if request.longest_group_rule_length > request.rule_length_limit() {
        builder.add_partial_reason(WholeVaultGraphPartialReason::MaxRuleLength);
    }

    for edge in &inputs.resolved_edges {
        builder.add_resolved_edge(edge);
    }
    if request.include_unresolved {
        for edge in &inputs.unresolved_edges {
            builder.add_unresolved_edge(edge);
        }
    }
    if request.include_orphans {
        for file in &inputs.orphan_files {
            builder.add_file_node(&file.file_id);
        }
    }

    builder.finish()
}

pub fn graph_file_node_id(file_id: &str) -> String {
    format!("file:{}", stable_hash_hex(file_id))
}

pub fn graph_unresolved_node_id(target_text: &str) -> String {
    format!(
        "unresolved:{}",
        stable_hash_hex(&unresolved_target_key(target_text))
    )
}

struct SnapshotBuilder<'a> {
    request: WholeVaultGraphRequest,
    generation: u64,
    node_count_total: usize,
    edge_count_total: usize,
    files_by_id: &'a HashMap<String, GraphFileRecord>,
    tags_by_file: &'a HashMap<String, Vec<String>>,
    degree_by_file: &'a HashMap<String, usize>,
    node_ids: HashSet<String>,
    nodes: Vec<WholeVaultGraphNode>,
    edges: Vec<WholeVaultGraphEdge>,
    partial_reasons: Vec<WholeVaultGraphPartialReason>,
}

impl<'a> SnapshotBuilder<'a> {
    fn new(
        request: WholeVaultGraphRequest,
        generation: u64,
        node_count_total: usize,
        edge_count_total: usize,
        files_by_id: &'a HashMap<String, GraphFileRecord>,
        tags_by_file: &'a HashMap<String, Vec<String>>,
        degree_by_file: &'a HashMap<String, usize>,
    ) -> Self {
        Self {
            request,
            generation,
            node_count_total,
            edge_count_total,
            files_by_id,
            tags_by_file,
            degree_by_file,
            node_ids: HashSet::new(),
            nodes: Vec::new(),
            edges: Vec::new(),
            partial_reasons: Vec::new(),
        }
    }

    fn add_resolved_edge(&mut self, edge: &GraphResolvedEdgeRecord) {
        if !self.can_add_edge() {
            return;
        }
        let source_node_id = graph_file_node_id(&edge.source_file_id);
        let target_node_id = graph_file_node_id(&edge.target_file_id);
        if !self.add_file_node(&edge.source_file_id) || !self.add_file_node(&edge.target_file_id) {
            return;
        }
        self.add_edge(WholeVaultGraphEdge {
            source_node_id,
            target_node_id,
            kind: WholeVaultGraphEdgeKind::Resolved,
            weight: edge.weight,
        });
    }

    fn add_unresolved_edge(&mut self, edge: &GraphUnresolvedEdgeRecord) {
        if !self.can_add_edge() {
            return;
        }
        let source_node_id = graph_file_node_id(&edge.source_file_id);
        let target_node_id = graph_unresolved_node_id(&edge.target_text);
        if !self.add_file_node(&edge.source_file_id) || !self.add_unresolved_node(&edge.target_text)
        {
            return;
        }
        self.add_edge(WholeVaultGraphEdge {
            source_node_id,
            target_node_id,
            kind: WholeVaultGraphEdgeKind::Unresolved,
            weight: edge.weight,
        });
    }

    fn add_file_node(&mut self, file_id: &str) -> bool {
        let node_id = graph_file_node_id(file_id);
        if self.node_ids.contains(&node_id) {
            return true;
        }
        if self.nodes.len() >= self.request.node_limit() {
            self.add_partial_reason(WholeVaultGraphPartialReason::MaxNodes);
            return false;
        }
        let Some(file) = self.files_by_id.get(file_id) else {
            return false;
        };

        let (label, was_truncated) = bounded_label(
            &file.relative_path.display().to_string(),
            self.request.label_limit(),
        );
        if was_truncated {
            self.add_partial_reason(WholeVaultGraphPartialReason::MaxLabelBytes);
        }
        let tags = self.visible_tags(file_id);
        self.node_ids.insert(node_id.clone());
        self.nodes.push(WholeVaultGraphNode {
            node_id,
            file_id: Some(file_id.to_string()),
            label,
            kind: WholeVaultGraphNodeKind::Resolved,
            degree: self.degree_by_file.get(file_id).copied().unwrap_or(0),
            tags,
        });
        true
    }

    fn add_unresolved_node(&mut self, target_text: &str) -> bool {
        let node_id = graph_unresolved_node_id(target_text);
        if self.node_ids.contains(&node_id) {
            return true;
        }
        if self.nodes.len() >= self.request.node_limit() {
            self.add_partial_reason(WholeVaultGraphPartialReason::MaxNodes);
            return false;
        }
        let (label, was_truncated) = bounded_label(target_text, self.request.label_limit());
        if was_truncated {
            self.add_partial_reason(WholeVaultGraphPartialReason::MaxLabelBytes);
        }
        self.node_ids.insert(node_id.clone());
        self.nodes.push(WholeVaultGraphNode {
            node_id,
            file_id: None,
            label,
            kind: WholeVaultGraphNodeKind::Unresolved,
            degree: 0,
            tags: Vec::new(),
        });
        true
    }

    fn can_add_edge(&mut self) -> bool {
        if self.edges.len() >= self.request.edge_limit() {
            self.add_partial_reason(WholeVaultGraphPartialReason::MaxEdges);
            return false;
        }
        true
    }

    fn add_edge(&mut self, edge: WholeVaultGraphEdge) {
        self.edges.push(edge);
    }

    fn visible_tags(&mut self, file_id: &str) -> Vec<String> {
        let tag_limit = self.request.tag_limit();
        let Some(tags) = self.tags_by_file.get(file_id) else {
            return Vec::new();
        };
        if tags.len() > tag_limit {
            self.add_partial_reason(WholeVaultGraphPartialReason::MaxTagsPerNode);
        }
        tags.iter().take(tag_limit).cloned().collect()
    }

    fn add_partial_reason(&mut self, reason: WholeVaultGraphPartialReason) {
        if !self.partial_reasons.contains(&reason) {
            self.partial_reasons.push(reason);
        }
    }

    fn finish(self) -> WholeVaultGraphBuild {
        let partial = !self.partial_reasons.is_empty();
        WholeVaultGraphBuild {
            snapshot: WholeVaultGraphSnapshot {
                request_id: self.request.request_id,
                generation: self.generation,
                partial_reasons: self.partial_reasons,
                node_count_total: self.node_count_total,
                edge_count_total: self.edge_count_total,
                nodes: self.nodes,
                edges: self.edges,
            },
            partial,
        }
    }
}

fn degree_by_file(
    resolved_edges: &[GraphResolvedEdgeRecord],
    unresolved_edges: &[GraphUnresolvedEdgeRecord],
    request: WholeVaultGraphRequest,
) -> HashMap<String, usize> {
    let mut degrees = HashMap::new();
    for edge in resolved_edges {
        *degrees.entry(edge.source_file_id.clone()).or_insert(0) += edge.weight;
        *degrees.entry(edge.target_file_id.clone()).or_insert(0) += edge.weight;
    }
    if request.include_unresolved {
        for edge in unresolved_edges {
            *degrees.entry(edge.source_file_id.clone()).or_insert(0) += edge.weight;
        }
    }
    degrees
}

fn tags_by_file(tags: Vec<GraphTagRecord>) -> HashMap<String, Vec<String>> {
    let mut by_file: HashMap<String, Vec<String>> = HashMap::new();
    for tag in tags {
        by_file.entry(tag.file_id).or_default().push(tag.tag);
    }
    by_file
}

fn bounded_label(value: &str, max_bytes: usize) -> (String, bool) {
    let normalized = normalize_label(value);
    if normalized.len() <= max_bytes {
        return (normalized, false);
    }

    let mut end = 0;
    for (index, ch) in normalized.char_indices() {
        let next = index + ch.len_utf8();
        if next > max_bytes {
            break;
        }
        end = next;
    }
    (normalized[..end].to_string(), true)
}

fn normalize_label(value: &str) -> String {
    value
        .chars()
        .map(|ch| {
            if ch.is_control() || is_bidi_control(ch) {
                '\u{FFFD}'
            } else {
                ch
            }
        })
        .collect()
}

fn is_bidi_control(ch: char) -> bool {
    matches!(
        ch,
        '\u{202A}'..='\u{202E}' | '\u{2066}'..='\u{2069}'
    )
}

fn stable_hash_hex(value: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn whole_vault_graph_builds_resolved_unresolved_orphan_and_tag_snapshot() {
        let home = graph_file("home.md", "Home.md");
        let target = graph_file("target.md", "Target.md");
        let orphan = graph_file("orphan.md", "Orphan.md");
        let request = WholeVaultGraphRequest::with_request_id(7, 10, 10)
            .including_unresolved(true)
            .including_orphans(true);

        let build = build_whole_vault_graph_snapshot(
            request,
            3,
            WholeVaultGraphInputs {
                node_count_total: 4,
                edge_count_total: 2,
                files: vec![home.clone(), target.clone(), orphan.clone()],
                resolved_edges: vec![resolved_edge(&home, &target, 2)],
                unresolved_edges: vec![unresolved_edge(&home, "Missing", 1)],
                orphan_files: vec![orphan.clone()],
                tags: vec![GraphTagRecord {
                    file_id: home.file_id.clone(),
                    tag: "project/native".to_string(),
                }],
            },
        );

        assert!(!build.partial);
        assert_eq!(build.snapshot.request_id, 7);
        assert_eq!(build.snapshot.generation, 3);
        assert_eq!(build.snapshot.node_count_total, 4);
        assert_eq!(build.snapshot.edge_count_total, 2);
        assert_eq!(build.snapshot.edges.len(), 2);
        assert!(build.snapshot.nodes.iter().any(|node| {
            node.file_id.as_deref() == Some("home.md")
                && node.kind == WholeVaultGraphNodeKind::Resolved
                && node.degree == 3
                && node.tags == vec!["project/native"]
        }));
        assert!(
            build
                .snapshot
                .nodes
                .iter()
                .any(|node| { node.file_id.as_deref() == Some("orphan.md") && node.degree == 0 })
        );
        assert!(
            build
                .snapshot
                .nodes
                .iter()
                .any(|node| node.kind == WholeVaultGraphNodeKind::Unresolved)
        );
        assert!(
            build
                .snapshot
                .edges
                .iter()
                .any(|edge| { edge.kind == WholeVaultGraphEdgeKind::Resolved && edge.weight == 2 })
        );
    }

    #[test]
    fn whole_vault_graph_caps_nodes_edges_labels_tags_and_group_rules() {
        let long_label = format!("{}.md", "a".repeat(80));
        let file = graph_file("long.md", &long_label);
        let target = graph_file("target.md", "Target.md");
        let extra = graph_file("extra.md", "Extra.md");
        let request = WholeVaultGraphRequest::new(2, 2)
            .with_label_limit(8)
            .with_tag_limit(1)
            .with_group_limits(1_000, 100, 1_000, 600);

        let build = build_whole_vault_graph_snapshot(
            request,
            1,
            WholeVaultGraphInputs {
                node_count_total: 3,
                edge_count_total: 4,
                files: vec![file.clone(), target.clone(), extra.clone()],
                resolved_edges: vec![
                    resolved_edge(&file, &target, 1),
                    resolved_edge(&file, &extra, 1),
                    resolved_edge(&target, &file, 1),
                    resolved_edge(&file, &target, 1),
                ],
                unresolved_edges: Vec::new(),
                orphan_files: Vec::new(),
                tags: vec![
                    GraphTagRecord {
                        file_id: file.file_id.clone(),
                        tag: "one".to_string(),
                    },
                    GraphTagRecord {
                        file_id: file.file_id.clone(),
                        tag: "two".to_string(),
                    },
                ],
            },
        );

        assert!(build.partial);
        assert_eq!(build.snapshot.edges.len(), 2);
        assert_eq!(build.snapshot.nodes.len(), 2);
        assert!(
            build
                .snapshot
                .partial_reasons
                .contains(&WholeVaultGraphPartialReason::MaxNodes)
        );
        assert!(
            build
                .snapshot
                .partial_reasons
                .contains(&WholeVaultGraphPartialReason::MaxEdges)
        );
        assert!(
            build
                .snapshot
                .partial_reasons
                .contains(&WholeVaultGraphPartialReason::MaxLabelBytes)
        );
        assert!(
            build
                .snapshot
                .partial_reasons
                .contains(&WholeVaultGraphPartialReason::MaxTagsPerNode)
        );
        assert!(
            build
                .snapshot
                .partial_reasons
                .contains(&WholeVaultGraphPartialReason::MaxGroups)
        );
        assert!(
            build
                .snapshot
                .partial_reasons
                .contains(&WholeVaultGraphPartialReason::MaxRuleLength)
        );
    }

    #[test]
    fn whole_vault_graph_handles_hostile_metadata_without_panic() {
        let file = graph_file("hostile.md", "SecretProject\u{0000}<script>\u{202E}.md");
        let build = build_whole_vault_graph_snapshot(
            WholeVaultGraphRequest::new(10, 10)
                .including_unresolved(true)
                .including_orphans(true),
            1,
            WholeVaultGraphInputs {
                node_count_total: 2,
                edge_count_total: 2,
                files: vec![file.clone()],
                resolved_edges: vec![resolved_edge(&file, &file, 1)],
                unresolved_edges: vec![unresolved_edge(&file, "Missing\u{202E}<script>", 1)],
                orphan_files: Vec::new(),
                tags: vec![GraphTagRecord {
                    file_id: file.file_id.clone(),
                    tag: "client@example.com".to_string(),
                }],
            },
        );

        assert_eq!(build.snapshot.nodes.len(), 2);
        assert_eq!(build.snapshot.edges.len(), 2);
        assert!(!build.snapshot.nodes[0].label.contains('\u{0000}'));
        assert!(!build.snapshot.nodes[0].label.contains('\u{202E}'));
        assert!(build.snapshot.nodes[0].label.contains('\u{FFFD}'));
        for node in &build.snapshot.nodes {
            assert!(!node.node_id.contains("hostile.md"));
            assert!(!node.node_id.contains("SecretProject"));
            assert!(!node.node_id.contains("Missing"));
            assert!(!node.node_id.contains("<script>"));
        }
        for edge in &build.snapshot.edges {
            assert!(!edge.source_node_id.contains("hostile.md"));
            assert!(!edge.target_node_id.contains("Missing"));
            assert!(!edge.target_node_id.contains("<script>"));
        }
    }

    fn graph_file(file_id: &str, relative_path: &str) -> GraphFileRecord {
        GraphFileRecord {
            file_id: file_id.to_string(),
            relative_path: PathBuf::from(relative_path),
        }
    }

    fn resolved_edge(
        source: &GraphFileRecord,
        target: &GraphFileRecord,
        weight: usize,
    ) -> GraphResolvedEdgeRecord {
        GraphResolvedEdgeRecord {
            source_file_id: source.file_id.clone(),
            source_relative_path: source.relative_path.clone(),
            target_file_id: target.file_id.clone(),
            target_relative_path: target.relative_path.clone(),
            weight,
        }
    }

    fn unresolved_edge(
        source: &GraphFileRecord,
        target_text: &str,
        weight: usize,
    ) -> GraphUnresolvedEdgeRecord {
        GraphUnresolvedEdgeRecord {
            source_file_id: source.file_id.clone(),
            source_relative_path: source.relative_path.clone(),
            target_text: target_text.to_string(),
            weight,
        }
    }
}
