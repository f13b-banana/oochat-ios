import SwiftUI
import ConnectOnionKit
import UIKit
import UniformTypeIdentifiers

/// What a long-press on a message offers besides Copy.
struct MessageMenu {
    var canEdit = false
    var canRetry = false
    var onEdit: (String) -> Void = { _ in }
    var onRetry: () -> Void = {}
}

struct MessageBubble: View {
    let message: ChatMessage
    var menu = MessageMenu()
    /// Why a failed message wasn't sent, when the app still knows.
    var failureReason: String?
    /// The raw error, offered as "Copy error details".
    var failureDetails: String?
    /// Named in the waiting row while a reply is on its way.
    var agentName = "Agent"
    /// Stops the reply in flight; nil when nothing is running.
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    // The text being edited in place; nil while the bubble shows the sent message.
    @State private var editDraft: String?
    @FocusState private var isEditorFocused: Bool
    @State private var previewedImage: ChatImageAttachment?
    @State private var downloadDocument: ChatFileDocument?
    @State private var downloadFilename = "Attachment"
    @State private var isFileExporterPresented = false

    var body: some View {
        Group {
            switch message.role {
            case .user:
                userMessage
            case .agent:
                agentMessage
            case .thinking:
                thinkingMessage
            case .tool:
                toolMessage
            case .error:
                errorMessage
            }
        }
        .fullScreenCover(item: $previewedImage) { image in
            FullScreenChatImage(image: image)
        }
        .fileExporter(
            isPresented: $isFileExporterPresented,
            document: downloadDocument,
            contentType: .data,
            defaultFilename: downloadFilename
        ) { _ in
            downloadDocument = nil
        }
    }

    private var userMessage: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.images.isEmpty {
                    imageGrid
                }
                if !message.files.isEmpty {
                    fileList
                }
                if editDraft != nil {
                    messageEditor
                } else if !message.content.isEmpty {
                    Text(message.content)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            AppTheme.outgoingMessageBackground,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                        )
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .contextMenu { messageMenuItems }
                }
                deliveryStatus
            }
        }
    }

    @ViewBuilder
    private var messageMenuItems: some View {
        Button {
            UIPasteboard.general.string = message.content
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        if menu.canEdit {
            Button {
                editDraft = message.content
            } label: {
                Label("Edit", systemImage: "pencil")
            }
        }
        if menu.canRetry {
            Button(action: menu.onRetry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
        }
    }

    // Your message, editable where it sits. Send has the agent answer it again in place.
    private var messageEditor: some View {
        let draft = Binding(get: { editDraft ?? "" }, set: { editDraft = $0 })
        let trimmed = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !trimmed.isEmpty && trimmed != message.content
        return VStack(alignment: .trailing, spacing: 8) {
            TextField("Message", text: draft, axis: .vertical)
                .lineLimit(1...8)
                .focused($isEditorFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    AppTheme.outgoingMessageBackground,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(OOColor.primary, lineWidth: 1.5)
                )
            HStack(spacing: 8) {
                Button("Cancel") {
                    editDraft = nil
                }
                .buttonStyle(CardQuietButtonStyle())
                .fixedSize()
                Button("Send") {
                    menu.onEdit(trimmed)
                    editDraft = nil
                }
                .buttonStyle(CardPrimaryButtonStyle())
                .frame(width: 96)
                .disabled(!canSend)
            }
        }
        .onAppear {
            isEditorFocused = true
        }
    }

    private var imageGrid: some View {
        LazyVGrid(columns: imageColumns, alignment: .trailing, spacing: 6) {
            ForEach(Array(message.images.enumerated()), id: \.element.id) { index, image in
                if let uiImage = UIImage(data: image.data) {
                    Button {
                        previewedImage = image
                    } label: {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .aspectRatio(1, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View photo \(index + 1) full screen")
                }
            }
        }
        .frame(width: message.images.count == 1 ? 220 : 270)
    }

    private var imageColumns: [GridItem] {
        let count = message.images.count == 1 ? 1 : 2
        return Array(
            repeating: GridItem(.flexible(), spacing: 6),
            count: count
        )
    }

    private var fileList: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(message.files) { file in
                Button {
                    downloadFilename = file.name
                    downloadDocument = ChatFileDocument(data: file.data)
                    isFileExporterPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.title3)
                            .foregroundStyle(AppTheme.primary)
                            .frame(width: 38, height: 38)
                            .background(
                                AppTheme.primary.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(Self.fileSizeLabel(file.data.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "square.and.arrow.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primary)
                    }
                    .padding(10)
                    .frame(width: 270)
                    .background(
                        Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download file \(file.name)")
                .accessibilityValue(Self.fileSizeLabel(file.data.count))
            }
        }
    }

    private static func fileSizeLabel(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    private var agentMessage: some View {
        MarkdownMessageView(content: message.content)
            .contextMenu { messageMenuItems }
    }

    private var thinkingMessage: some View {
        WaitingForAgentRow(startedAt: message.createdAt, agentName: agentName, onStop: onStop)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toolMessage: some View {
        ToolCallView(message: message)
    }

    private var errorMessage: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message.content)
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .red.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        switch message.deliveryState {
        // A transmitted message is in flight; the waiting row shows that.
        case .sent, .transmitted:
            EmptyView()
        case .queued:
            Label("Queued", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(OOColor.inkSecondary)
        case .failed:
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Label("Not sent", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    if onRetry != nil {
                        retryButton
                            .accessibilityLabel("Retry sending message")
                    }
                }
                if let failureReason {
                    Text(failureReason)
                        .font(.caption2)
                        .foregroundStyle(OOColor.inkSecondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contextMenu {
                if let failureDetails {
                    Button {
                        UIPasteboard.general.string = failureDetails
                    } label: {
                        Label("Copy error details", systemImage: "doc.on.doc")
                    }
                }
            }
        case .cancelled:
            HStack(spacing: 8) {
                Label("Cancelled", systemImage: "stop.circle")
                    .font(.caption2)
                    .foregroundStyle(OOColor.inkSecondary)
                if onRetry != nil {
                    retryButton
                        .accessibilityLabel("Retry cancelled message")
                }
            }
        }
    }

    /// A small tinted pill so it reads as a button. Taps anywhere in the 44 pt around it count.
    private var retryButton: some View {
        Button {
            onRetry?()
        } label: {
            Text("Retry")
                .font(.caption.weight(.semibold))
                .foregroundStyle(OOColor.primary)
                .padding(.horizontal, OOSpace.medium)
                .padding(.vertical, OOSpace.tiny)
                .background(OOColor.currentTint, in: Capsule())
                .frame(minWidth: ooMinimumTarget, minHeight: ooMinimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(AppPressButtonStyle())
    }
}

private struct ChatFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct FullScreenChatImage: View {
    @Environment(\.dismiss) private var dismiss
    let image: ChatImageAttachment

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            if let uiImage = UIImage(data: image.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
                    .accessibilityLabel("Full size photo")
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .padding(16)
            }
            .accessibilityLabel("Close photo")
        }
    }
}

struct UlwCheckpointCard: View {
    let checkpoint: PendingUlwCheckpoint
    var onContinue: () -> Void
    var onSwitchToAuto: () -> Void

    var body: some View {
        OONotice(
            .decision,
            title: "Full access checkpoint",
            message: "The agent completed \(checkpoint.request.turnsUsed) of "
                + "\(checkpoint.request.maxTurns) autonomous turns without tool approvals."
        ) {
            VStack(spacing: OOSpace.small) {
                Button("Continue \(UlwCheckpointDecision.continueTurns) turns", action: onContinue)
                    .buttonStyle(CardPrimaryButtonStyle())
                    .accessibilityHint("Full access ends after these turns.")
                    .accessibilityIdentifier("ulw.continue.\(checkpoint.id)")

                Button("Switch to Auto", action: onSwitchToAuto)
                    .buttonStyle(CardSecondaryButtonStyle())
                    .accessibilityIdentifier("ulw.auto.\(checkpoint.id)")
            }
            .padding(.top, OOSpace.tiny)
        }
    }
}

/// Shown while the agent works on a reply: how long you've waited, and Stop after a while.
struct WaitingForAgentRow: View {
    /// After this long the row says "Still waiting" and offers Cancel, so a quick reply doesn't flash a button.
    static let stopDelay = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let startedAt: Date
    let agentName: String
    /// Nil when there's nothing to stop.
    let onStop: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: OOSpace.small) {
                ProgressView()
                    .tint(OOColor.primary)
                    .accessibilityHidden(true)

                Text("\(seconds >= Self.stopDelay ? "Still waiting" : "Waiting") for \(agentName) · \(seconds) s")
                    .foregroundStyle(OOColor.inkSecondary)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())

                if seconds >= Self.stopDelay, let onStop {
                    Button("Cancel", action: onStop)
                        .buttonStyle(.plain)
                        .foregroundStyle(OOColor.inkSecondary)
                        .underline()
                        .padding(.horizontal, OOSpace.small)
                        .frame(minHeight: ooMinimumTarget)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Cancel waiting for \(agentName)")
                }
            }
            // Always the height of the Cancel button, so the row doesn't grow when it appears.
            .frame(minHeight: ooMinimumTarget)
        }
    }
}
