import Testing
@testable import NativeMarkdownCore

@Test
func frontmatterSourceCommandPlannerInsertsSkeletonForBodyOnlyNote() throws {
    let source = "# Body\n"
    let plan = FrontmatterSourceCommandPlanner.planAddFilePropertyCommand(source: source)
    let replacement = try replacement(from: plan)
    let updated = source.replacingCharacters(in: replacement.range, with: replacement.text)

    #expect(updated == "---\n\n---\n# Body\n")
}

@Test
func frontmatterSourceCommandPlannerFocusesExistingClosedBlock() throws {
    let source = "---\ntitle: Home\n---\n# Body\n"
    let plan = FrontmatterSourceCommandPlanner.planAddFilePropertyCommand(source: source)
    let replacement = try replacement(from: plan)
    let updated = source.replacingCharacters(in: replacement.range, with: replacement.text)

    #expect(updated == source)
    guard case .replaceText(_, let focus) = plan else {
        Issue.record("Expected replace plan")
        return
    }
    #expect(focus?.preferredField == .name)
}

@Test
func frontmatterSourceCommandPlannerTreatsUnclosedDelimiterAsBody() throws {
    let source = "---\nBody\n"
    let plan = FrontmatterSourceCommandPlanner.planAddFilePropertyCommand(source: source)
    let replacement = try replacement(from: plan)
    let updated = source.replacingCharacters(in: replacement.range, with: replacement.text)

    #expect(updated == "---\n\n---\n---\nBody\n")
}

private func replacement(from plan: FrontmatterEditPlan) throws -> SourceTextReplacement {
    guard case .replaceText(let replacement, _) = plan else {
        throw TestError.unexpectedPlan
    }
    return replacement
}

private enum TestError: Error {
    case unexpectedPlan
}
