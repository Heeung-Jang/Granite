import NativeMarkdownCore
import SwiftUI

struct FilePropertyDraft: Equatable {
    var id = UUID()
    var name = ""
    var value = ""
    var type: FilePropertyType = .text
    var warning: String?

    var canCommit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct FilePropertyQuickAddOverlay: View {
    @Binding var draft: FilePropertyDraft
    var suggestions: [FilePropertySuggestion] = []
    var typeForPropertyName: (String) -> FilePropertyType = { FilePropertySuggestions.defaultType(for: $0) }
    var commit: (FilePropertyDraft) -> Void
    var cancel: () -> Void

    @FocusState private var focusedField: Field?
    @State private var userSelectedType = false

    private enum Field {
        case name
        case value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Property type", selection: typeBinding) {
                    ForEach(FilePropertyType.allCases, id: \.self) { type in
                        Text(type.label).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 132)
                .accessibilityLabel("Property type")

                TextField("Property", text: $draft.name)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel("Property name")
                    .onSubmit {
                        focusedField = .value
                    }

                valueControl

                Button("Add") {
                    commit(draft)
                }
                .disabled(!draft.canCommit)
                .keyboardShortcut(.return, modifiers: [])

                Button("Cancel") {
                    cancel()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            if !visibleSuggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(visibleSuggestions) { suggestion in
                        Button {
                            selectSuggestion(suggestion)
                        } label: {
                            HStack(spacing: 4) {
                                Text(suggestion.name)
                                Text(suggestion.type.label)
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                }
            }

            if let warning = draft.warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Property warning: \(warning)")
            }
        }
        .padding(10)
        .frame(maxWidth: 760)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
        .padding(.top, 18)
        .padding(.horizontal, 24)
        .onAppear {
            focusedField = .name
        }
        .onChange(of: draft.name) { _, nextName in
            guard !userSelectedType else {
                return
            }
            draft.type = typeForPropertyName(nextName)
        }
    }

    private var visibleSuggestions: [FilePropertySuggestion] {
        let query = draft.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = suggestions.filter { suggestion in
            guard !suggestion.existsInNote else {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            return suggestion.name.lowercased().hasPrefix(query)
        }
        return Array(filtered.prefix(6))
    }

    private var typeBinding: Binding<FilePropertyType> {
        Binding(
            get: { draft.type },
            set: { nextType in
                userSelectedType = true
                draft.type = nextType
            }
        )
    }

    private func selectSuggestion(_ suggestion: FilePropertySuggestion) {
        draft.name = suggestion.name
        draft.type = suggestion.type
        userSelectedType = false
        focusedField = .value
    }

    @ViewBuilder
    private var valueControl: some View {
        switch draft.type {
        case .checkbox:
            Toggle("Value", isOn: checkboxBinding)
                .labelsHidden()
                .accessibilityLabel("Property checkbox value")
        case .list, .tags:
            TextField("Comma-separated values", text: $draft.value)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .value)
                .accessibilityLabel(draft.type == .tags ? "Property tag values" : "Property list values")
                .onSubmit { commit(draft) }
        case .date:
            TextField("YYYY-MM-DD", text: $draft.value)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .value)
                .accessibilityLabel("Property date value")
                .onSubmit { commit(draft) }
        case .dateTime:
            TextField("YYYY-MM-DDTHH:mm:ss", text: $draft.value)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .value)
                .accessibilityLabel("Property date and time value")
                .onSubmit { commit(draft) }
        case .number:
            TextField("Number", text: $draft.value)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .value)
                .accessibilityLabel("Property number value")
                .onSubmit { commit(draft) }
        case .text:
            TextField("Value", text: $draft.value)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .value)
                .accessibilityLabel("Property value")
                .onSubmit { commit(draft) }
        }
    }

    private var checkboxBinding: Binding<Bool> {
        Binding(
            get: { draft.value.lowercased() == "true" },
            set: { draft.value = $0 ? "true" : "false" }
        )
    }
}

extension FilePropertyDraft {
    var propertyValue: FilePropertyValue? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .text:
            return .text(trimmed)
        case .list:
            return .list(splitValues(trimmed))
        case .number:
            guard trimmed.isEmpty || Double(trimmed) != nil else {
                return nil
            }
            return .number(trimmed)
        case .checkbox:
            return .checkbox(trimmed.lowercased() == "true")
        case .date:
            return .date(trimmed)
        case .dateTime:
            return .dateTime(trimmed)
        case .tags:
            return .tags(splitValues(trimmed))
        }
    }

    private func splitValues(_ raw: String) -> [String] {
        raw.split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
