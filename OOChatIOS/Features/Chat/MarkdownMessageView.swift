import MarkdownUI
import SwiftUI
import UIKit

enum MarkdownCodeBlockLanguage {
    static func label(for fenceInfo: String?) -> String? {
        fenceInfo?
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
    }
}

struct MarkdownMessageView: View {
    let content: String

    var body: some View {
        Markdown(content)
            .markdownTextStyle(\.text) {
                ForegroundColor(Color(.label))
                FontSize(16)
                BackgroundColor(nil)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                MarkdownCodeBlockView(configuration: configuration)
            }
            .markdownTheme(.gitHub)
            .markdownTextStyle(\.text) {
                ForegroundColor(Color(.label))
                FontSize(16)
                BackgroundColor(nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownCodeBlockView: View {
    let configuration: CodeBlockConfiguration
    @State private var isCopied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(MarkdownCodeBlockLanguage.label(for: configuration.language) ?? "Code")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    UIPasteboard.general.string = configuration.content
                    isCopied = true
                    copyResetTask?.cancel()
                    copyResetTask = Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled else {
                            return
                        }
                        isCopied = false
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCopied ? "Code copied" : "Copy code")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 4)

            Divider()

            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .relativeLineSpacing(.em(0.225))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.85))
                    }
                    .padding(12)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .markdownMargin(top: 0, bottom: 16)
        .onDisappear {
            copyResetTask?.cancel()
            isCopied = false
        }
    }
}
