import Testing
@testable import NativeMarkdownCore

@Test
func frontmatterEditPlannerAddsFirstPropertyToBodyOnlyNote() throws {
    let source = "# Body\n"
    let plan = FrontmatterEditPlanner.planAddProperty(source: source, key: "status", value: .text("draft"))
    let replacement = try replacement(from: plan)
    let updated = source.replacingCharacters(in: replacement.range, with: replacement.text)

    #expect(updated == "---\nstatus: draft\n---\n# Body\n")
}

@Test
func frontmatterEditPlannerAddsPropertyInsideExistingFrontmatter() throws {
    let source = "---\ntitle: Home\n---\n# Body\n"
    let plan = FrontmatterEditPlanner.planAddProperty(source: source, key: "status", value: .text("draft"))
    let replacement = try replacement(from: plan)
    let updated = source.replacingCharacters(in: replacement.range, with: replacement.text)

    #expect(updated == "---\ntitle: Home\nstatus: draft\n---\n# Body\n")
}

@Test
func frontmatterEditPlannerPreventsDuplicateKeysWithoutMutation() throws {
    let source = "---\nstatus: draft\n---\n# Body\n"
    let plan = FrontmatterEditPlanner.planAddProperty(source: source, key: "status", value: .text("done"))

    guard case .duplicateKey(let key, let focus) = plan else {
        Issue.record("Expected duplicate key plan")
        return
    }
    #expect(key == "status")
    #expect(focus.preferredField == .name)
}

@Test
func frontmatterEditPlannerTreatsUnclosedTopDelimiterAsBodyContent() throws {
    let source = "---\nBody that is not closed front matter.\n"
    let plan = FrontmatterEditPlanner.planAddProperty(source: source, key: "status", value: .text("draft"))
    let replacement = try replacement(from: plan)
    let updated = source.replacingCharacters(in: replacement.range, with: replacement.text)

    #expect(updated == "---\nstatus: draft\n---\n---\nBody that is not closed front matter.\n")
}

@Test
func frontmatterEditPlannerUpdatesSimplePropertyWithoutRewritingBlock() throws {
    let source = "---\n# keep\nstatus: draft\naliases:\n  - Home\n---\n# Body\n"
    let plan = FrontmatterEditPlanner.planUpdateProperty(source: source, key: "status", value: .text("done"))
    let replacement = try replacement(from: plan)
    let updated = source.replacingCharacters(in: replacement.range, with: replacement.text)

    #expect(updated == "---\n# keep\nstatus: done\naliases:\n  - Home\n---\n# Body\n")
}

@Test
func frontmatterEditPlannerRefusesComplexNestedValue() {
    let source = "---\nconfig:\n  nested: true\n---\n# Body\n"
    let plan = FrontmatterEditPlanner.planUpdateProperty(source: source, key: "config", value: .text("flat"))

    guard case .complexValueRequiresSourceMode(let key, _) = plan else {
        Issue.record("Expected complex value refusal")
        return
    }
    #expect(key == "config")
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
