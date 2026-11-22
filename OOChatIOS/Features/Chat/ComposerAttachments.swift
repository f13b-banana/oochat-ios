import ConnectOnionKit
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension Composer {
    var attachmentMenu: some View {
        Menu {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("Upload Photo", systemImage: "photo")
            }
            .disabled(
                viewModel.pendingImages.count >= ChatImageAttachment.maximumCount
                    || isImportingPhotos
            )

            Button {
                fileImportConversationID = viewModel.activeConversationID
                isFileImporterPresented = true
            } label: {
                Label("Upload File", systemImage: "doc")
            }
            .disabled(
                viewModel.pendingFiles.count >= ChatFileAttachment.maximumCount
                    || isImportingFiles
            )
        } label: {
            Group {
                if isImportingPhotos || isImportingFiles {
                    ProgressView()
                } else {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                }
            }
            .foregroundStyle(AppTheme.primary)
            .frame(width: ComposerMetrics.attachmentButtonSize, height: ComposerMetrics.attachmentButtonSize)
            .frame(width: ooMinimumTarget, height: ooMinimumTarget)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(
            viewModel.activeConversation == nil
                || isImportingPhotos
                || isImportingFiles
                || (
                    viewModel.pendingImages.count >= ChatImageAttachment.maximumCount
                        && viewModel.pendingFiles.count >= ChatFileAttachment.maximumCount
                )
        )
        .accessibilityLabel(
            isImportingPhotos || isImportingFiles
                ? "Loading attachments"
                : "Add attachment"
        )
    }

    var pendingImageStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: ComposerMetrics.attachmentSpacing) {
                ForEach(Array(viewModel.pendingImages.enumerated()), id: \.element.id) { index, image in
                    if let uiImage = UIImage(data: image.data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: ComposerMetrics.attachmentPreviewSize,
                                    height: ComposerMetrics.attachmentPreviewSize
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: ComposerMetrics.attachmentCornerRadius,
                                        style: .continuous
                                    )
                                )

                            Button {
                                viewModel.removePendingImage(id: image.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.72))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                            .accessibilityLabel("Remove photo \(index + 1)")
                        }
                        .padding(.top, 5)
                        .padding(.trailing, 5)
                    }
                }
            }
            .padding(.horizontal, ComposerMetrics.modeLeadingPadding)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Selected photos")
    }

    var pendingFileStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: ComposerMetrics.attachmentSpacing) {
                ForEach(Array(viewModel.pendingFiles.enumerated()), id: \.element.id) { index, file in
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.fill")
                                .font(.title3)
                                .foregroundStyle(AppTheme.primary)
                                .frame(width: 34, height: 34)
                                .background(
                                    AppTheme.primary.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(Self.fileSizeLabel(file.data.count))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(width: ComposerMetrics.filePreviewWidth, height: ComposerMetrics.filePreviewHeight)
                        .background(
                            Color(.secondarySystemBackground),
                            in: RoundedRectangle(
                                cornerRadius: ComposerMetrics.attachmentCornerRadius,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: ComposerMetrics.attachmentCornerRadius,
                                style: .continuous
                            )
                            .stroke(Color(.separator).opacity(0.25), lineWidth: 0.5)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Selected file \(file.name), \(Self.fileSizeLabel(file.data.count))")

                        Button {
                            viewModel.removePendingFile(id: file.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.72))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("Remove file \(index + 1)")
                    }
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }
            }
            .padding(.horizontal, ComposerMetrics.modeLeadingPadding)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Selected files")
    }

    func importSelectedPhotos(
        _ items: [PhotosPickerItem],
        for conversationID: String?
    ) async {
        isImportingPhotos = true
        defer {
            selectedPhotoItems = []
            isImportingPhotos = false
        }

        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw PhotoImportError.noData
                }
                let mimeType = item.supportedContentTypes
                    .first(where: { $0.conforms(to: .image) })?
                    .preferredMIMEType ?? "image/jpeg"
                _ = viewModel.addPendingImage(
                    data: data,
                    mimeType: mimeType,
                    to: conversationID
                )
            } catch {
                viewModel.reportImageImportFailure(error)
            }
        }
    }

    func importSelectedFiles(
        _ urls: [URL],
        for conversationID: String?
    ) async {
        isImportingFiles = true
        defer { isImportingFiles = false }

        let selectedURLs = urls.prefix(ChatFileAttachment.maximumCount)
        for url in selectedURLs {
            do {
                let imported = try await Self.loadFile(at: url)
                _ = viewModel.addPendingFile(
                    name: imported.name,
                    data: imported.data,
                    mimeType: imported.mimeType,
                    to: conversationID
                )
            } catch {
                viewModel.reportFileImportFailure(error)
            }
        }

        if urls.count > selectedURLs.count {
            viewModel.reportFileImportFailure(FileImportError.tooMany)
        }
    }

    private static func loadFile(at url: URL) async throws -> ImportedChatFile {
        try await Task.detached(priority: .userInitiated) {
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let values = try url.resourceValues(forKeys: [
                .contentTypeKey,
                .fileSizeKey,
                .isRegularFileKey,
                .nameKey
            ])
            guard values.isRegularFile != false else {
                throw FileImportError.notARegularFile
            }
            if let fileSize = values.fileSize,
               fileSize > ChatFileAttachment.maximumByteCount {
                throw FileImportError.tooLarge
            }
            return ImportedChatFile(
                name: values.name ?? url.lastPathComponent,
                data: try Data(contentsOf: url, options: .mappedIfSafe),
                mimeType: values.contentType?.preferredMIMEType ?? "application/octet-stream"
            )
        }.value
    }

    private static func fileSizeLabel(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }
}

private struct ImportedChatFile {
    let name: String
    let data: Data
    let mimeType: String
}

private enum PhotoImportError: LocalizedError {
    case noData

    var errorDescription: String? {
        "The selected photo contained no readable data."
    }
}

private enum FileImportError: LocalizedError {
    case notARegularFile
    case tooLarge
    case tooMany

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "Please choose a regular file."
        case .tooLarge:
            return "The selected file is larger than 10 MB."
        case .tooMany:
            return "You can attach up to 10 files."
        }
    }
}
