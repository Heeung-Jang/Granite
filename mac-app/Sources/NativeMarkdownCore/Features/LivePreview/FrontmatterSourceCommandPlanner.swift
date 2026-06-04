import Foundation

public enum FrontmatterSourceCommandPlanner {
    public static func planAddFilePropertyCommand(source: String) -> FrontmatterEditPlan {
        if let block = FrontmatterBlockLocator.locateClosedBlock(in: source) {
            return .replaceText(
                replacement: SourceTextReplacement(range: block.insertionIndex..<block.insertionIndex, text: ""),
                focus: SourceFocusTarget(
                    range: LivePreviewSourceRange(location: block.closingSourceRange.location, length: 0),
                    preferredField: .name
                )
            )
        }

        let newline = FrontmatterBlockLocator.dominantNewline(in: source)
        let insertionIndex = FrontmatterBlockLocator.insertionIndexForNewBlock(in: source)
        let inserted = "---\(newline)\(newline)---\(newline)"
        let prefixLength = (source[..<insertionIndex] as Substring).utf16.count
        let focusLocation = prefixLength + ("---\(newline)" as NSString).length
        return .replaceText(
            replacement: SourceTextReplacement(range: insertionIndex..<insertionIndex, text: inserted),
            focus: SourceFocusTarget(
                range: LivePreviewSourceRange(location: focusLocation, length: 0),
                preferredField: .name
            )
        )
    }
}
