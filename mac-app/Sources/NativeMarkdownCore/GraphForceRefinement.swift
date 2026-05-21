import Foundation

public enum GraphForceRefinement {
    public static func refined(
        _ layout: GraphRendererSnapshot,
        settings: GraphForceSettings,
        iterations: Int = 20,
        checkCancellation: () throws -> Void = {}
    ) throws -> GraphRendererSnapshot {
        let force = settings.clamped
        guard force.isEnabled, !layout.nodes.isEmpty, iterations > 0 else {
            return layout
        }

        var positions = layout.nodes.map(\.position)
        var velocities = Array(
            repeating: GraphPoint(x: 0, y: 0),
            count: layout.nodes.count
        )

        for iteration in 0..<iterations {
            if iteration.isMultiple(of: 4) {
                try checkCancellation()
            }
            applyCenterAndRepel(
                positions: positions,
                velocities: &velocities,
                force: force
            )
            applyLinkForces(
                edges: layout.edges,
                positions: positions,
                velocities: &velocities,
                force: force
            )
            integrate(positions: &positions, velocities: &velocities)
        }

        let refinedNodes = layout.nodes.enumerated().map { index, node in
            GraphLayoutNode(
                index: node.index,
                nodeID: node.nodeID,
                fileID: node.fileID,
                relativePath: node.relativePath,
                label: node.label,
                kind: node.kind,
                degree: node.degree,
                tags: node.tags,
                position: positions[index],
                radius: node.radius
            )
        }

        return GraphRendererSnapshot(
            requestID: layout.requestID,
            generation: layout.generation,
            nodes: refinedNodes,
            edges: layout.edges,
            components: layout.components
        )
    }

    private static func applyCenterAndRepel(
        positions: [GraphPoint],
        velocities: inout [GraphPoint],
        force: GraphForceSettings
    ) {
        for index in positions.indices {
            let position = positions[index]
            velocities[index].x += -position.x * force.centerStrength * 0.002
            velocities[index].y += -position.y * force.centerStrength * 0.002

            let distance = max(80, hypot(position.x, position.y))
            let repel = force.repelStrength * 12 / distance
            velocities[index].x += (position.x / distance) * repel
            velocities[index].y += (position.y / distance) * repel
        }
    }

    private static func applyLinkForces(
        edges: [GraphLayoutEdge],
        positions: [GraphPoint],
        velocities: inout [GraphPoint],
        force: GraphForceSettings
    ) {
        for edge in edges {
            guard positions.indices.contains(edge.sourceIndex),
                  positions.indices.contains(edge.targetIndex)
            else {
                continue
            }

            let source = positions[edge.sourceIndex]
            let target = positions[edge.targetIndex]
            let dx = target.x - source.x
            let dy = target.y - source.y
            let distance = max(1, hypot(dx, dy))
            let pull = (distance - force.linkDistance) * force.linkStrength * 0.001
            let x = dx / distance * pull
            let y = dy / distance * pull

            velocities[edge.sourceIndex].x += x
            velocities[edge.sourceIndex].y += y
            velocities[edge.targetIndex].x -= x
            velocities[edge.targetIndex].y -= y
        }
    }

    private static func integrate(
        positions: inout [GraphPoint],
        velocities: inout [GraphPoint]
    ) {
        for index in positions.indices {
            positions[index].x += velocities[index].x
            positions[index].y += velocities[index].y
            velocities[index].x *= 0.72
            velocities[index].y *= 0.72
        }
    }
}
