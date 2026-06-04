import Foundation

public enum FrontmatterEditPlanner {
    public static func planAddProperty(
        source: String,
        key: String,
        value: FilePropertyValue
    ) -> FrontmatterEditPlan {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            return .noOp
        }
        let newline = FrontmatterBlockLocator.dominantNewline(in: source)
        if let block = FrontmatterBlockLocator.locateClosedBlock(in: source) {
            if let existing = topLevelPropertyRanges(in: source, block: block)
                .first(where: { $0.key == normalizedKey }) {
                return .duplicateKey(
                    existingKey: existing.key,
                    focus: SourceFocusTarget(range: existing.keyRange, preferredField: .name)
                )
            }
            let inserted = FrontmatterPropertySerializer.propertyText(
                key: normalizedKey,
                value: value,
                newline: block.newline
            )
            let focus = valueFocus(
                insertedText: inserted,
                key: normalizedKey,
                insertionIndex: block.insertionIndex,
                source: source,
                preferredField: .value
            )
            return .replaceText(
                replacement: SourceTextReplacement(range: block.insertionIndex..<block.insertionIndex, text: inserted),
                focus: focus
            )
        }

        let insertionIndex = FrontmatterBlockLocator.insertionIndexForNewBlock(in: source)
        let property = FrontmatterPropertySerializer.propertyText(key: normalizedKey, value: value, newline: newline)
        let inserted = "---\(newline)\(property)---\(newline)"
        let focus = valueFocus(
            insertedText: inserted,
            key: normalizedKey,
            insertionIndex: insertionIndex,
            source: source,
            preferredField: .value
        )
        return .replaceText(
            replacement: SourceTextReplacement(range: insertionIndex..<insertionIndex, text: inserted),
            focus: focus
        )
    }

    public static func planUpdateProperty(
        source: String,
        key: String,
        value: FilePropertyValue
    ) -> FrontmatterEditPlan {
        guard let block = FrontmatterBlockLocator.locateClosedBlock(in: source) else {
            return planAddProperty(source: source, key: key, value: value)
        }
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let existing = topLevelPropertyRanges(in: source, block: block)
            .first(where: { $0.key == normalizedKey })
        else {
            return planAddProperty(source: source, key: normalizedKey, value: value)
        }
        guard existing.isSimpleEditable else {
            return .complexValueRequiresSourceMode(
                key: existing.key,
                focus: SourceFocusTarget(range: existing.keyRange, preferredField: .value)
            )
        }
        let inserted = FrontmatterPropertySerializer.propertyText(
            key: normalizedKey,
            value: value,
            newline: block.newline
        )
        let focus = valueFocus(
            insertedText: inserted,
            key: normalizedKey,
            insertionIndex: existing.fullRange.lowerBound,
            source: source,
            preferredField: .value
        )
        return .replaceText(
            replacement: SourceTextReplacement(range: existing.fullRange, text: inserted),
            focus: focus
        )
    }

    static func topLevelPropertyRanges(
        in source: String,
        block: FrontmatterBlockLocation
    ) -> [FrontmatterPropertyRange] {
        var result: [FrontmatterPropertyRange] = []
        var activeIndex: Int?
        var index = block.contentRange.lowerBound
        while index < block.contentRange.upperBound {
            let lineStart = index
            let newlineIndex = source[index..<block.contentRange.upperBound].firstIndex { $0.isNewline }
            let lineEnd = newlineIndex.map { source.index(after: $0) } ?? block.contentRange.upperBound
            let contentEnd: String.Index
            contentEnd = newlineIndex ?? lineEnd
            let fullRange = lineStart..<lineEnd
            let contentRange = lineStart..<contentEnd
            let text = String(source[contentRange])

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                if let activeIndex {
                    result[activeIndex].fullRange = result[activeIndex].fullRange.lowerBound..<fullRange.upperBound
                }
                index = lineEnd
                continue
            }

            let isIndented = text.first?.isWhitespace == true
            if isIndented {
                if let activeIndex {
                    result[activeIndex].fullRange = result[activeIndex].fullRange.lowerBound..<fullRange.upperBound
                    if !text.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                        result[activeIndex].isSimpleEditable = false
                    }
                }
                index = lineEnd
                continue
            }

            guard let colon = source[contentRange].firstIndex(of: ":") else {
                activeIndex = nil
                index = lineEnd
                continue
            }
            let keyRange = trimmedRange(contentRange.lowerBound..<colon, in: source)
            guard !keyRange.isEmpty else {
                activeIndex = nil
                index = lineEnd
                continue
            }
            let valueRange = trimmedRange(source.index(after: colon)..<contentRange.upperBound, in: source)
            let property = FrontmatterPropertyRange(
                key: String(source[keyRange]),
                keyRange: LivePreviewRangeMapper.sourceRange(for: keyRange, in: source),
                valueRange: valueRange.isEmpty ? nil : LivePreviewRangeMapper.sourceRange(for: valueRange, in: source),
                fullRange: fullRange,
                isSimpleEditable: true
            )
            result.append(property)
            activeIndex = result.indices.last
            index = lineEnd
        }
        return result
    }

    private static func valueFocus(
        insertedText: String,
        key: String,
        insertionIndex: String.Index,
        source: String,
        preferredField: FilePropertyFocusedField
    ) -> SourceFocusTarget? {
        let prefixLength = (source[..<insertionIndex] as Substring).utf16.count
        let nsText = insertedText as NSString
        let keyRange = nsText.range(of: key)
        guard keyRange.location != NSNotFound else {
            return SourceFocusTarget(
                range: LivePreviewSourceRange(location: prefixLength, length: 0),
                preferredField: preferredField
            )
        }
        let colonLocation = keyRange.location + keyRange.length
        let focusLocation = min(nsText.length, colonLocation + 2)
        return SourceFocusTarget(
            range: LivePreviewSourceRange(location: prefixLength + focusLocation, length: 0),
            preferredField: preferredField
        )
    }

    private static func trimmedRange(
        _ range: Range<String.Index>,
        in source: String
    ) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, source[lower].isWhitespace {
            lower = source.index(after: lower)
        }
        while lower < upper {
            let previous = source.index(before: upper)
            guard source[previous].isWhitespace else {
                break
            }
            upper = previous
        }
        return lower..<upper
    }
}

struct FrontmatterPropertyRange {
    var key: String
    var keyRange: LivePreviewSourceRange
    var valueRange: LivePreviewSourceRange?
    var fullRange: Range<String.Index>
    var isSimpleEditable: Bool
}
