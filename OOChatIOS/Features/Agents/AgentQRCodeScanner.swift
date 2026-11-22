import AVFoundation
import SwiftUI
import VisionKit

enum AgentQRCodePayload {
    static func address(from payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if HostedAgentClient.isHostedAgentAddress(trimmed) {
            return trimmed
        }

        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "chat.openonion.ai",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 1 else {
            return nil
        }

        let address = String(path[0])
        return HostedAgentClient.isHostedAgentAddress(address) ? address : nil
    }
}

struct AgentQRCodeScannerView: View {
    let onCode: (String) -> Void
    let onUnavailable: (String) -> Void
    /// What the person types instead when the camera can't scan.
    var manualEntry = "the agent address"
    /// Inside another screen (the Device Link sheet) rather than full screen: no close button of
    /// its own, and it stays inside the safe area and the frame it is given.
    var isEmbedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var readiness: ScannerReadiness = .checking

    /// Scanning needs both an authorization answer and a live capture stack, and neither is
    /// known until `requestAccess` returns — hence a distinct state for "still asking".
    private enum ScannerReadiness {
        case checking
        case ready
        case unavailable
    }

    /// Hardware/OS capability only — safe to check before camera access is granted.
    ///
    /// `@MainActor` because the VisionKit properties it forwards to are main-actor
    /// isolated; without it these accessors are non-isolated and reading them is a
    /// concurrency error. Every caller is already on the main actor (SwiftUI view
    /// bodies and the readiness check), so this annotates the truth rather than
    /// changing behaviour.
    @MainActor
    static var isSupported: Bool {
        DataScannerViewController.isSupported
    }

    /// `DataScannerViewController.isAvailable` reports false while camera access is still
    /// `.notDetermined`, so this is only meaningful after `requestAccess` has resolved.
    @MainActor
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        ZStack {
            switch readiness {
            case .checking:
                ProgressView()
            case .ready:
                AgentQRCodeScannerController(onCode: onCode, onUnavailable: onUnavailable, unavailableMessage: unavailableMessage)
                    .ignoresSafeArea(edges: isEmbedded ? [] : .all)
                RoundedRectangle(cornerRadius: 20)
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 250, height: 250)
                    .shadow(color: .black.opacity(0.35), radius: 8)
                    .accessibilityHidden(true)
            case .unavailable:
                ContentUnavailableView(
                    "Camera Unavailable",
                    systemImage: "camera.fill",
                    description: Text("Enter \(manualEntry) manually.")
                )
            }

            if !isEmbedded {
                closeButton
            }
        }
        .task {
            guard readiness == .checking else {
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            let available = granted && Self.isAvailable
            readiness = available ? .ready : .unavailable
            guard !available else {
                return
            }
            onUnavailable(unavailableMessage)
        }
    }

    private var unavailableMessage: String {
        "Camera scanning is unavailable. Enter \(manualEntry) manually."
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .accessibilityLabel("Close scanner")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Spacer()
        }
    }
}

private struct AgentQRCodeScannerController: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: (String) -> Void
    let unavailableMessage: String

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: false
        )
        controller.delegate = context.coordinator

        do {
            try controller.startScanning()
        } catch {
            context.coordinator.reportUnavailable()
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onUnavailable: onUnavailable, unavailableMessage: unavailableMessage)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void
        private let onUnavailable: (String) -> Void
        private let unavailableMessage: String
        private var didFinish = false

        init(onCode: @escaping (String) -> Void, onUnavailable: @escaping (String) -> Void, unavailableMessage: String) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
            self.unavailableMessage = unavailableMessage
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !didFinish,
                  let code = addedItems.compactMap({ item -> String? in
                      guard case let .barcode(barcode) = item else {
                          return nil
                      }
                      return barcode.payloadStringValue
                  }).first else {
                return
            }

            didFinish = true
            dataScanner.stopScanning()
            onCode(code)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: Error) {
            reportUnavailable()
        }

        func reportUnavailable() {
            guard !didFinish else {
                return
            }
            didFinish = true
            onUnavailable(unavailableMessage)
        }
    }
}
