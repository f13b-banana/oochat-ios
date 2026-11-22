import ConnectOnionKit
import SwiftUI

struct SettingsView<Model: SettingsFeatureModel>: View {
    @ObservedObject var viewModel: Model
    var onClose: (() -> Void)?
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: $appAppearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                IdentitySettingsView(viewModel: viewModel)

                Section("Session") {
                    LabeledContent("Connection", value: viewModel.connectionState.rawValue)
                    LabeledContent("Session ID", value: viewModel.activeConversation?.id ?? "None")
                    Button("Reconnect") {
                        Task {
                            await viewModel.reconnect()
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            onClose()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Close")
                        .tint(.primary)
                    }
                }
            }
        }
        .preferredColorScheme(AppAppearance(rawValue: appAppearance)?.colorScheme)
    }
}

/// This device's Address, and the two ways to link it with another of the person's devices.
struct IdentitySettingsView<Model: SettingsFeatureModel>: View {
    @ObservedObject var viewModel: Model
    @State private var linkRole: DeviceLinkRole?

    var body: some View {
        Section("Identity") {
            HStack {
                Text("This device")
                Spacer()
                if let address = viewModel.identity?.address {
                    OOAddressLabel(address, name: "Your address")
                } else {
                    Text("Creating...").foregroundStyle(.secondary)
                }
            }
            ForEach([DeviceLinkRole.giving, .receiving], id: \.self) { role in
                linkRow(role)
            }
        }
    }

    // Each row carries its own sheet: a sheet on a List Section would be attached to every row.
    private func linkRow(_ role: DeviceLinkRole) -> some View {
        Button {
            linkRole = role
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.settingsTitle)
                Text(role.settingsDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: Binding(get: { linkRole == role }, set: { if !$0 { linkRole = nil } })) {
            DeviceLinkSheet(
                role: role,
                keyStore: viewModel.deviceLinkKeyStore,
                agentNames: { viewModel.linkAgentNames },
                onAgentNames: { try viewModel.applyLinkedAgentNames($0) },
                onReplaced: { previousAddress in
                    // The key was replaced: lock the old chats, show the new Address and reconnect as it.
                    Task { await viewModel.adoptReplacedIdentity(previousAddress: previousAddress) }
                }
            )
        }
    }
}

/// iPhone sheet chrome around the Kit's link view. Each presentation makes its own flow; closing the
/// sheet (Cancel, a swipe, or a "no" inside the flow) cancels the link. Both roles open on the scanner,
/// with "Show my code instead" for when the other device has the camera. Without a camera there is no
/// scanner, so the Kit's copy only offers typing the code.
struct DeviceLinkSheet: View {
    let role: DeviceLinkRole
    @State private var flow: DeviceLinkFlow
    @Environment(\.dismiss) private var dismiss

    init(
        role: DeviceLinkRole,
        keyStore: any DeviceLinkKeyStore,
        agentNames: @escaping @MainActor () -> [DeviceLinkAgentName] = { [] },
        onAgentNames: @escaping @MainActor ([DeviceLinkAgentName]) throws -> Void = { _ in },
        onReplaced: @escaping @MainActor (_ previousAddress: String) -> Void
    ) {
        self.role = role
        _flow = State(initialValue: DeviceLinkFlow(
            role: role,
            keyStore: keyStore,
            displaysCode: false,
            onReplaced: onReplaced,
            agentNames: agentNames,
            onAgentNames: onAgentNames
        ))
    }

    var body: some View {
        NavigationStack {
            Group {
                if AgentQRCodeScannerView.isSupported {
                    DeviceLinkView(flow: flow) {
                        AgentQRCodeScannerView(
                            onCode: { flow.submit($0) },
                            onUnavailable: { _ in },
                            manualEntry: "the Link Code",
                            isEmbedded: true
                        )
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: OORadius.card, style: .continuous))
                    }
                } else {
                    DeviceLinkView(flow: flow)
                }
            }
            .navigationTitle(role.settingsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// First launch: keep the Identity this device just made, or take one from another of the person's
/// devices through the same receive sheet Settings opens. A finished link also ends onboarding.
struct IdentityOnboardingView: View {
    let keyStore: any DeviceLinkKeyStore
    let onReplaced: @MainActor (_ previousAddress: String) -> Void
    /// The giver's Agent Name list, applied before `onReplaced`.
    var onAgentNames: @MainActor ([DeviceLinkAgentName]) throws -> Void = { _ in }
    let onFinish: () -> Void
    @State private var isLinking = false
    @State private var didLink = false

    var body: some View {
        VStack(spacing: OOSpace.large) {
            Spacer()
            // White tile, like the home-screen icon, so the logo's black half shows in dark mode.
            Image("OnionLogo")
                .resizable()
                .scaledToFit()
                .padding(16)
                .frame(width: 96, height: 96)
                .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text("Welcome to oo-chat")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Your identity is how your agents know you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Create a new identity", action: onFinish)
                .buttonStyle(.ooPrimary)
            Button {
                isLinking = true
            } label: {
                VStack(spacing: 2) {
                    Text(DeviceLinkRole.receiving.settingsTitle)
                    Text(DeviceLinkRole.receiving.settingsDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(OOSpace.large)
        .sheet(isPresented: $isLinking, onDismiss: finishIfLinked) {
            DeviceLinkSheet(role: .receiving, keyStore: keyStore, onAgentNames: onAgentNames) { previousAddress in
                didLink = true
                onReplaced(previousAddress)
            }
        }
    }

    private func finishIfLinked() {
        if didLink { onFinish() }
    }
}
