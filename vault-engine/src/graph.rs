pub use crate::core::graph::{
    WholeVaultGraphBuild, WholeVaultGraphEdge, WholeVaultGraphEdgeKind, WholeVaultGraphNode,
    WholeVaultGraphNodeKind, WholeVaultGraphPartialReason, WholeVaultGraphRequest,
    WholeVaultGraphSnapshot,
};
pub use crate::use_cases::build_graph::{
    MAX_WHOLE_VAULT_GRAPH_EDGES, MAX_WHOLE_VAULT_GRAPH_GROUPS, MAX_WHOLE_VAULT_GRAPH_LABEL_BYTES,
    MAX_WHOLE_VAULT_GRAPH_NODES, MAX_WHOLE_VAULT_GRAPH_RULE_LENGTH,
    MAX_WHOLE_VAULT_GRAPH_TAGS_PER_NODE, WholeVaultGraphInputs, build_whole_vault_graph_snapshot,
    graph_file_node_id, graph_unresolved_node_id, whole_vault_graph_needs_tags,
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::sqlite::{
        GraphFileRecord, GraphResolvedEdgeRecord, GraphTagRecord, GraphUnresolvedEdgeRecord,
    };
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
            node.file_id.is_none()
                && node.relative_path.as_deref() == Some("Home.md")
                && node.label == "Home"
                && node.kind == WholeVaultGraphNodeKind::Resolved
                && node.degree == 3
                && node.tags == vec!["project/native"]
        }));
        assert!(build.snapshot.nodes.iter().any(|node| {
            node.relative_path.as_deref() == Some("Orphan.md")
                && node.label == "Orphan"
                && node.degree == 0
        }));
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
