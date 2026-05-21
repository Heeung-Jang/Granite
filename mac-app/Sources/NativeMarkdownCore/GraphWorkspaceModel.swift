import Foundation

public enum GraphWorkspaceState: String, Equatable, Sendable {
    case noVault
    case missingIndex
    case building
    case stale
    case partial
    case snapshotFailed
    case decodeFailed
    case layoutFailed
    case rendererFailed
    case cancelled
    case ready

    public var retainsPreviousStableGraph: Bool {
        switch self {
        case .building, .stale, .partial, .snapshotFailed, .decodeFailed, .layoutFailed, .rendererFailed, .cancelled:
            true
        case .noVault, .missingIndex, .ready:
            false
        }
    }
}

public struct GraphStableGraphSummary: Equatable, Sendable {
    public let generation: UInt64
    public let nodeCount: Int
    public let edgeCount: Int

    public init(generation: UInt64, nodeCount: Int, edgeCount: Int) {
        self.generation = generation
        self.nodeCount = nodeCount
        self.edgeCount = edgeCount
    }
}

public struct GraphWorkspaceModel: Equatable, Sendable {
    public private(set) var state: GraphWorkspaceState
    public private(set) var previousStableGraph: GraphStableGraphSummary?

    public init(
        state: GraphWorkspaceState = .noVault,
        previousStableGraph: GraphStableGraphSummary? = nil
    ) {
        self.state = state
        self.previousStableGraph = previousStableGraph
    }

    public var shouldDisplayPreviousStableGraph: Bool {
        previousStableGraph != nil && state.retainsPreviousStableGraph
    }

    public mutating func applyStableGraph(_ summary: GraphStableGraphSummary) {
        previousStableGraph = summary
        state = .ready
    }

    public mutating func beginRecompute() {
        state = .building
    }

    public mutating func markPartial() {
        state = .partial
    }

    public mutating func fail(_ failureState: GraphWorkspaceState) {
        guard failureState.retainsPreviousStableGraph else {
            state = failureState
            previousStableGraph = nil
            return
        }
        state = failureState
    }

    public mutating func clear(_ state: GraphWorkspaceState) {
        self.state = state
        previousStableGraph = nil
    }
}
