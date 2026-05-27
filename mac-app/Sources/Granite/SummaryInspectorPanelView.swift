import NativeMarkdownCore
import SwiftUI

enum SummaryPanelViewState: Equatable {
    case ready
    case editorNotReady
    case loading(SummaryProgressState)
    case unavailable(SummaryUnavailableReason)
    case tooLarge(sourceByteCount: Int, maxSourceBytes: Int)
    case failed(SummaryFailureReason)
    case streaming(String)
    case fastComplete(DocumentSummary)
    case refining(DocumentSummary)
    case refinedComplete(DocumentSummary)
    case complete(DocumentSummary)

    var isComplete: Bool {
        switch self {
        case .complete, .fastComplete, .refinedComplete:
            return true
        default:
            return false
        }
    }

    var isWorking: Bool {
        switch self {
        case .loading, .streaming, .refining:
            return true
        default:
            return false
        }
    }

    var currentSummary: DocumentSummary? {
        switch self {
        case .fastComplete(let summary), .refining(let summary), .refinedComplete(let summary), .complete(let summary):
            return summary
        default:
            return nil
        }
    }
}

struct SummaryInspectorPanelView: View {
    @Environment(\.appContentZoomScale) private var appContentZoomScale
    let state: SummaryPanelViewState
    let generate: () -> Void
    let cancel: () -> Void

    var body: some View {
        InspectorSection(title: "Summary") {
            VStack(alignment: .leading, spacing: ObsidianUI.scaled(10, scale: appContentZoomScale)) {
                privacyNote
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .ready:
            generateButton
        case .editorNotReady:
            EmptyInlineText("에디터가 준비되면 요약할 수 있습니다.")
            generateButton
        case .loading(let progress):
            loadingView(progress)
        case .unavailable(let reason):
            EmptyInlineText(unavailableText(reason))
            generateButton
        case .tooLarge(let sourceByteCount, let maxSourceBytes):
            EmptyInlineText("문서가 너무 큽니다. \(sourceByteCount / 1024)KB / 제한 \(maxSourceBytes / 1024)KB")
        case .failed(let reason):
            EmptyInlineText(failureText(reason))
            generateButton
        case .streaming(let snapshot):
            stagedStatus("빠른 요약", isLoading: true)
            streamingView(snapshot)
            cancelButton
        case .fastComplete(let summary):
            stagedStatus("빠른 요약", isLoading: false)
            summaryView(summary)
            regenerateButton
        case .refining(let summary):
            stagedStatus("정교화 중", isLoading: true)
            summaryView(summary)
            cancelButton
        case .refinedComplete(let summary):
            stagedStatus("정교화 완료", isLoading: false)
            summaryView(summary)
            regenerateButton
        case .complete(let summary):
            summaryView(summary)
            regenerateButton
        }
    }

    private var privacyNote: some View {
        Text("현재 에디터 내용과 저장되지 않은 편집을 로컬 Apple 모델로 요약합니다. 원본 문서에는 저장하지 않습니다.")
            .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var generateButton: some View {
        summaryButton(title: "요약 생성", accessibilityLabel: "Generate summary")
    }

    private var regenerateButton: some View {
        summaryButton(title: "다시 생성", accessibilityLabel: "Regenerate summary")
    }

    private var cancelButton: some View {
        Button {
            cancel()
        } label: {
            Label("취소", systemImage: "xmark")
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("Cancel summary")
    }

    private func summaryButton(title: String, accessibilityLabel: String) -> some View {
        Button {
            generate()
        } label: {
            Label(title, systemImage: "sparkles")
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(accessibilityLabel)
    }

    private func loadingView(_ progress: SummaryProgressState) -> some View {
        VStack(alignment: .leading, spacing: ObsidianUI.scaled(8, scale: appContentZoomScale)) {
            HStack(spacing: ObsidianUI.scaled(6, scale: appContentZoomScale)) {
                ProgressView()
                    .controlSize(.small)
                Text(progressText(progress))
                    .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale)))
                    .foregroundStyle(.secondary)
            }
            cancelButton
        }
    }

    private func stagedStatus(_ title: String, isLoading: Bool) -> some View {
        HStack(spacing: ObsidianUI.scaled(6, scale: appContentZoomScale)) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Text(title)
                .font(.system(size: ObsidianUI.fontSize(12, scale: appContentZoomScale), weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel(title)
    }

    private func streamingView(_ snapshot: String) -> some View {
        Text(snapshot.isEmpty ? "요약을 준비하는 중입니다." : snapshot)
            .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
            .lineSpacing(ObsidianUI.scaled(2, scale: appContentZoomScale))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Summary body")
    }

    private func summaryView(_ summary: DocumentSummary) -> some View {
        VStack(alignment: .leading, spacing: ObsidianUI.scaled(14, scale: appContentZoomScale)) {
            summaryBlock(title: "핵심 요약", lines: [summary.overview])
            summaryBlock(title: "주요 포인트", lines: summary.keyPoints)
            summaryBlock(title: "액션/결정 사항", lines: summary.actionItems)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Summary body")
    }

    private func summaryBlock(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: ObsidianUI.scaled(6, scale: appContentZoomScale)) {
            Text(title)
                .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale), weight: .semibold))
            ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                Text(line)
                    .font(.system(size: ObsidianUI.fontSize(13, scale: appContentZoomScale)))
                    .lineSpacing(ObsidianUI.scaled(2, scale: appContentZoomScale))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressText(_ progress: SummaryProgressState) -> String {
        switch progress {
        case .analyzing:
            return "문서를 분석하는 중입니다."
        case .summarizingChunk(let current, let total):
            return "\(current)/\(total) 섹션 요약 중입니다."
        case .finalizing:
            return "최종 요약을 만드는 중입니다."
        case .fastStreaming:
            return "빠른 요약을 표시하는 중입니다."
        case .fastComplete:
            return "빠른 요약을 완료했습니다."
        case .refining:
            return "요약을 정교화하는 중입니다."
        case .refinedComplete:
            return "정교화 요약을 완료했습니다."
        case .fallingBack:
            return "기존 요약 경로로 전환하는 중입니다."
        default:
            return "요약 중입니다."
        }
    }

    private func unavailableText(_ reason: SummaryUnavailableReason) -> String {
        switch reason {
        case .frameworkMissing:
            return "현재 SDK에서 Apple Foundation Models를 사용할 수 없습니다."
        case .osUnsupported:
            return "이 macOS 버전에서는 Apple Foundation Models를 사용할 수 없습니다."
        case .deviceNotEligible:
            return "이 기기는 Apple Intelligence 모델을 지원하지 않습니다."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence가 비활성화되어 있습니다."
        case .modelNotReady:
            return "Apple Intelligence 모델이 아직 준비 중입니다."
        case .unavailable:
            return "요약 모델을 사용할 수 없습니다."
        }
    }

    private func failureText(_ reason: SummaryFailureReason) -> String {
        switch reason {
        case .contextWindowExceeded:
            return "모델 context 한도를 초과했습니다."
        case .rateLimited:
            return "요청이 잠시 제한되었습니다. 다시 시도하세요."
        case .unsupportedLanguageOrLocale:
            return "현재 모델이 이 언어를 지원하지 않습니다."
        case .malformedResponse:
            return "요약 응답 형식이 올바르지 않습니다."
        case .unavailable:
            return "요약 모델을 사용할 수 없습니다."
        case .cancelled:
            return "요약이 취소되었습니다."
        case .unknown:
            return "요약을 완료하지 못했습니다."
        }
    }
}
