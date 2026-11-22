import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

public extension DeviceLinkRole {
    /// The Settings › Identity row, and the link sheet's title, that opens a link in this role.
    var settingsTitle: String {
        switch self {
        case .giving: "Link a new device"
        case .receiving: "Link from another device"
        }
    }

    /// The line under the Settings row.
    var settingsDetail: String {
        switch self {
        case .giving: "Send this device's identity to another of your devices."
        case .receiving: "Use the identity from another of your devices on this one."
        }
    }
}

/// The link sheet's content for every `DeviceLinkFlow` step. It starts the flow when it appears and
/// cancels it when it goes, so closing the sheet cancels the link. Saying no to a confirmation closes
/// the sheet. The app supplies the chrome (title, toolbar, sheet frame), and on iPhone a camera
/// scanner for code entry that calls `flow.submit(_:)` with what it reads.
public struct DeviceLinkView<Scanner: View>: View {
    private let flow: DeviceLinkFlow
    private let scanner: Scanner
    @State private var typedCode = ""
    @Environment(\.dismiss) private var dismiss

    public init(flow: DeviceLinkFlow, @ViewBuilder scanner: () -> Scanner) {
        self.flow = flow
        self.scanner = scanner()
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: OOSpace.large) {
                content
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            .padding(OOSpace.large)
        }
        .onAppear { flow.start() }
        .onDisappear { flow.cancel() }
        // Brings up the local-network prompt as the sheet opens, before a code can be scanned or typed;
        // if it first appeared mid-connection, that scan was lost.
        .task { await DeviceLinkFlow.askForLocalNetwork() }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .showingCode(let offer):
            showingCode(offer)
        case .enteringCode:
            enteringCode
        case .connecting:
            progress("Connecting to the other device…")
        case .confirmingReplace(let current, let incoming):
            OONotice(
                .decision,
                title: "Replace this device's identity?",
                message: Self.replaceMessage
            ) {
                address("Current", current)
                address("New", incoming)
                buttons(confirm: "Replace identity", role: .destructive, decline: "Keep current identity")
            }
        case .confirmingSend:
            OONotice(
                .decision,
                title: "Send my identity to this device?",
                message: "The other device will use your Address and can open your chats with your agents. You'll confirm it's you first."
            ) {
                if flow.ownerCheckFailed {
                    Text("Couldn't confirm it's you. Try again, or set a passcode or password on this device.")
                        .font(.footnote)
                        .foregroundStyle(OOColor.failureText)
                }
                buttons(confirm: "Send", role: nil, decline: "Don't send")
            }
        case .sending:
            progress(flow.role == .giving ? "Waiting for the other device to accept…" : "Finishing the link…")
        case .done(let shared):
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(OOColor.primary)
                .accessibilityHidden(true)
            Text("Devices linked").font(.headline).foregroundStyle(OOColor.ink)
            Text("Both devices now use this Address.").font(.subheadline).foregroundStyle(OOColor.inkSecondary)
            OOAddressLabel(shared, name: "Your address")
            Button("Done") { dismiss() }.buttonStyle(.ooPrimary)
        case .failed(let failure):
            OONotice(.failure, title: failure.title, message: failure.nextStep) {
                Button(flow.displaysCode ? "New code" : "Try again") {
                    typedCode = "" // a retry shouldn't send the code that just failed
                    flow.start()
                }
                    .buttonStyle(.ooPrimary)
            }
        }
    }

    private func showingCode(_ offer: DeviceLinkOffer) -> some View {
        VStack(spacing: OOSpace.large) {
            Text(Self.showingCodeInstruction(for: flow.role))
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
                .multilineTextAlignment(.center)
            if let payload = try? offer.qrPayload, let image = Self.qrImage(for: payload) {
                // black on white in both modes, with a quiet zone, so any camera reads it
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(OOSpace.medium)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: OORadius.card, style: .continuous))
                    .frame(maxWidth: 240)
                    .accessibilityLabel("QR code for linking")
            }
            Text(Self.grouped(offer.linkCode))
                .font(OOFont.mono(size: 24, relativeTo: .title2))
                .foregroundStyle(OOColor.ink)
                .textSelection(.enabled)
                .accessibilityLabel("Link Code \(offer.linkCode.map(String.init).joined(separator: " "))")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Self.expiryText(offer.expiry, now: context.date))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(OOColor.inkSecondary)
            }
            Button("New code") { flow.start() }.buttonStyle(.ooSecondary)
            Button(Self.enterCodeInstead) { flow.switchCodeMode() }.buttonStyle(.ooQuiet())
        }
    }

    private var enteringCode: some View {
        VStack(spacing: OOSpace.large) {
            Text(Self.codeEntryInstruction(for: flow.role))
                .font(.subheadline)
                .foregroundStyle(OOColor.inkSecondary)
                .multilineTextAlignment(.center)
            scanner
            TextField("Link Code", text: $typedCode)
                .font(OOFont.mono(size: 17, relativeTo: .body))
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .onSubmit(submitTypedCode)
            Button("Link", action: submitTypedCode)
                .buttonStyle(.ooPrimary)
                .disabled(typedCode.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Show my code instead") { flow.switchCodeMode() }.buttonStyle(.ooQuiet())
        }
    }

    private func submitTypedCode() {
        flow.submit(typedCode)
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: OOSpace.medium) {
            ProgressView()
            Text(text).font(.subheadline).foregroundStyle(OOColor.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func address(_ label: String, _ address: String) -> some View {
        HStack(spacing: OOSpace.small) {
            Text(label).font(.subheadline.weight(.medium)).foregroundStyle(OOColor.ink)
            Spacer(minLength: 0)
            OOAddressLabel(address, name: "\(label) address")
        }
    }

    /// The confirmation's yes calls `flow.confirm()`; its no closes the sheet, which cancels the link.
    private func buttons(confirm: String, role: ButtonRole?, decline: String) -> some View {
        HStack(spacing: OOSpace.small) {
            Button(decline) { dismiss() }.buttonStyle(.ooSecondary)
            Button(confirm, role: role) { flow.confirm() }.buttonStyle(.ooPrimary)
        }
    }

    /// The Receiving Device's warning before its key is replaced.
    static var replaceMessage: String {
        "This device will use the identity from your other device. "
            + "Its current identity is replaced and can't be recovered. " + DeviceLinkFlow.agentNamesWarning
    }

    /// The offer as a QR code, one pixel per module; scale it up without smoothing.
    static func qrImage(for payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }

    /// Without a scanner (the Mac) the person can only type the code, so the copy doesn't mention scanning.
    static func codeEntryInstruction(for role: DeviceLinkRole) -> String {
        openOnOtherDevice(role) + (hasScanner
            ? "Scan the QR code it shows, or type the Link Code under it."
            : "Then type the Link Code shown under its QR code.")
    }

    static func showingCodeInstruction(for role: DeviceLinkRole) -> String {
        openOnOtherDevice(role) + "Scan this code, or type the Link Code under it."
    }

    /// Leaves this device's own code for entering the other device's.
    static var enterCodeInstead: String {
        hasScanner ? "Scan a code instead" : "Type a code instead"
    }

    private static var hasScanner: Bool { Scanner.self != EmptyView.self }

    /// Where the other device's person starts the other role, for this device's `role`.
    private static func openOnOtherDevice(_ role: DeviceLinkRole) -> String {
        "On your other device, open Settings › Identity › \(role.counterpart.settingsTitle). "
    }

    static func grouped(_ code: String) -> String {
        "\(code.prefix(5)) \(code.dropFirst(5))"
    }

    static func expiryText(_ expiry: Date, now: Date) -> String {
        let seconds = Int(expiry.timeIntervalSince(now).rounded(.up))
        guard seconds > 0 else { return "Expired" }
        return "Expires in \(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

public extension DeviceLinkView where Scanner == EmptyView {
    /// Code entry by typing only, as on a Mac.
    init(flow: DeviceLinkFlow) {
        self.init(flow: flow) { EmptyView() }
    }
}
