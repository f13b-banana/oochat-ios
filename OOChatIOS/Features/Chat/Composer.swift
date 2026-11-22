import PhotosUI
import SwiftUI

struct Composer: View {
    @ObservedObject var viewModel: ChatViewModel
    var focusRequest = 0
    var onPromptFocusChange: (Bool) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) var scenePhase
    @FocusState var isPromptFocused: Bool
    @State var showModeMenu = false
    @State var sheetHeight: CGFloat = 400
    @State var selectedPhotoItems: [PhotosPickerItem] = []
    @State var isPhotoPickerPresented = false
    @State var isImportingPhotos = false
    @State var isFileImporterPresented = false
    @State var isImportingFiles = false
    @State var fileImportConversationID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ComposerMetrics.stackSpacing) {
            if viewModel.shouldShowSlashSkillPicker {
                skillPicker
            }

            if !viewModel.pendingImages.isEmpty {
                pendingImageStrip
            }
            if !viewModel.pendingFiles.isEmpty {
                pendingFileStrip
            }

            modeMenu
                .padding(.leading, ComposerMetrics.modeLeadingPadding)
                .padding(.bottom, -ComposerMetrics.modeTargetBottomInset)

            inputBar
        }
        .padding(.horizontal, ComposerMetrics.outerHorizontalPadding)
        .padding(.bottom, ComposerMetrics.outerBottomPadding)
        .frame(maxWidth: ChatReadableWidth.maximum)
        .frame(maxWidth: .infinity)
        .onChange(of: viewModel.activeConversationID) {
            viewModel.stopVoiceInput()
            isPromptFocused = viewModel.activeConversationID != nil
        }
        .onChange(of: focusRequest) {
            isPromptFocused = true
        }
        .onChange(of: isPromptFocused) { _, isFocused in
            onPromptFocusChange(isFocused)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                viewModel.stopVoiceInput()
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else {
                return
            }
            let conversationID = viewModel.activeConversationID
            Task {
                await importSelectedPhotos(items, for: conversationID)
            }
        }
        .onDisappear {
            viewModel.stopVoiceInput()
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(
                1,
                ChatImageAttachment.maximumCount - viewModel.pendingImages.count
            ),
            matching: .images
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            let conversationID = fileImportConversationID
            fileImportConversationID = nil
            switch result {
            case .success(let urls):
                Task {
                    await importSelectedFiles(urls, for: conversationID)
                }
            case .failure(let error):
                viewModel.reportFileImportFailure(error)
            }
        }
    }
}
