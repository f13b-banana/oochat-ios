import SwiftUI

/// The Work Room for one Work Room group. The task title leads, with the Provider state beneath
/// it, then one status sentence, the running step with at most one last result, and the current
/// turn of the Provider's conversation. Earlier turns and activity are folded away. While a verified Provider
/// approval waits, its decision takes the place of the status sentence.
/// The app supplies the navigation around it (a push on iOS, the detail pane on macOS).
public struct OOWorkRoomView: View {
    private let workRoom: WorkRoom
    private let onDecide: ((WorkRoomDecision) -> Void)?
    private let onStop: (() -> Void)?
    private let onDraftChange: ((String) -> Void)?
    private let onSend: (() -> Void)?
    private let mic: OOWorkRoomMic?
    private let onChangePermission: ((String, Bool) -> Void)?
    private let onChangeControl: ((OIPProviderControlAction) -> Void)?
    @State private var showsEarlierActivity = false
    @State private var showsEarlierTurns = false
    @AccessibilityFocusState private var isHeadingFocused: Bool

    /// `onDecide` is the app's answer to the store (`WorkRoomStore.decide`); without it a pending approval is
    /// shown but cannot be answered here.
    /// `onStop` is the app's call to `WorkRoomStore.stop(in:)`; without it no Stop button is drawn.
    /// `onDraftChange` and `onSend` are the app's calls to `WorkRoomStore.setDraft(_:in:)` and `send(in:)`;
    /// the composer is drawn only when `onSend` is given.
    /// `mic` adds the app's dictation control to that composer.
    /// `onChangePermission` is the app's call to `WorkRoomStore.changePermission(to:confirmRisk:in:)`; the Permission
    /// Profile selector is drawn only when the Work Room has a catalog and this is given.
    /// `onChangeControl` is the app's call to `WorkRoomStore.changeControl(_:in:)`; the Control row is drawn only
    /// when the Work Room has `control` and this is given.
    public init(
        workRoom: WorkRoom,
        onDecide: ((WorkRoomDecision) -> Void)? = nil,
        onStop: (() -> Void)? = nil,
        onDraftChange: ((String) -> Void)? = nil,
        onSend: (() -> Void)? = nil,
        onChangePermission: ((String, Bool) -> Void)? = nil,
        onChangeControl: ((OIPProviderControlAction) -> Void)? = nil,
        mic: OOWorkRoomMic? = nil
    ) {
        self.workRoom = workRoom
        self.onDecide = onDecide
        self.onStop = onStop
        self.onDraftChange = onDraftChange
        self.onSend = onSend
        self.mic = mic
        self.onChangePermission = onChangePermission
        self.onChangeControl = onChangeControl
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OOSpace.large) {
                header
                if let approval = workRoom.approval, workRoom.status == .awaitingApproval {
                    OOWorkRoomDecision(approval: approval, onDecide: onDecide)
                } else if let summary = workRoom.summary {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(OOColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let preview = workRoom.preview {
                    OOWorkRoomPreview(screenshot: preview)
                }
                stopControls
                activity
                conversation
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(OOSpace.large)
            .frame(maxWidth: .infinity)
        }
        .background(OOColor.surface)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let onSend {
                OOWorkRoomComposer(
                    composer: workRoom.composer,
                    provider: workRoom.provider,
                    draft: Binding(get: { workRoom.composer.draft }, set: { onDraftChange?($0) }),
                    onSend: onSend,
                    mic: mic
                )
            }
        }
        // VoiceOver lands on the heading when the Work Room opens.
        // Wait for the push transition to finish, or VoiceOver moves back to the navigation bar.
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            isHeadingFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: OOSpace.small) {
            Text(workRoom.displayTitle)
                .font(OOFont.headline(size: 22, relativeTo: .title2))
                .foregroundStyle(OOColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isHeadingFocused)
            HStack(spacing: OOSpace.small) {
                OOProviderBadge(provider: workRoom.provider)
                OOToolStatus(workRoom.status.toolState, isAwaitingApproval: workRoom.status == .awaitingApproval)
                    .accessibilityHidden(true)
                Text(workRoom.status.label)
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkSecondary)
            }
            .accessibilityElement(children: .combine)
            if let permission = workRoom.permission, let onChangePermission {
                OOWorkRoomPermission(permission: permission, provider: workRoom.provider, onChange: onChangePermission)
            }
            if let control = workRoom.control, let onChangeControl {
                OOWorkRoomControl(control: control, onChange: onChangeControl)
            }
        }
    }

    /// The Scoped Stop: the button, then "Stop requested" or "Status needs confirmation" in its place
    /// while the barrier holds, with the host's reason when it refused.
    @ViewBuilder private var stopControls: some View {
        let stop = workRoom.stop
        if let text = stop.barrierText {
            Label(text, systemImage: "hourglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OOColor.ink)
                .accessibilityAddTraits(.isStaticText)
        } else if let onStop, stop.offersStop || stop.isRequesting || stop.unavailableReason != nil {
            VStack(alignment: .leading, spacing: OOSpace.small) {
                if let rejection = stop.rejection {
                    Text(rejection)
                        .font(.subheadline)
                        .foregroundStyle(OOColor.failureText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(stop.isRequesting ? "Requesting stop" : "Stop", action: onStop)
                    .buttonStyle(.ooSecondary)
                    .disabled(!stop.offersStop)
                    .accessibilityLabel(stop.isRequesting ? "Requesting stop" : "Stop this Work Room")
                    .accessibilityHint("Stops only this \(workRoom.provider.displayName) run, not the agent")
                if let reason = stop.unavailableReason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(OOColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var activity: some View {
        if let current = workRoom.currentActivity {
            WorkRoomActivityRow(activity: current)
        }
        if let last = workRoom.lastCompleted {
            VStack(alignment: .leading, spacing: OOSpace.small) {
                OOSectionHeader("Last completed")
                WorkRoomActivityRow(activity: last)
            }
        }
        if !workRoom.earlierActivities.isEmpty {
            DisclosureGroup("Earlier activity", isExpanded: $showsEarlierActivity) {
                VStack(alignment: .leading, spacing: OOSpace.medium) {
                    ForEach(Array(workRoom.earlierActivities.enumerated()), id: \.offset) { _, activity in
                        WorkRoomActivityRow(activity: activity)
                    }
                }
                .padding(.top, OOSpace.small)
            }
            .foregroundStyle(OOColor.ink)
        }
    }

    @ViewBuilder private var conversation: some View {
        if !workRoom.earlierMessages.isEmpty {
            DisclosureGroup("Earlier turns", isExpanded: $showsEarlierTurns) {
                messages(workRoom.earlierMessages)
                    .padding(.top, OOSpace.small)
            }
            .foregroundStyle(OOColor.ink)
        }
        messages(workRoom.currentTurn)
    }

    private func messages(_ messages: [OIPProviderMessage]) -> some View {
        VStack(alignment: .leading, spacing: OOSpace.medium) {
            ForEach(messages, id: \.messageID) { message in
                WorkRoomMessageRow(message: message, provider: workRoom.provider)
            }
        }
    }
}

/// One Provider step: its status mark, allowed title and summary, and its file names.
private struct WorkRoomActivityRow: View {
    let activity: OIPProviderActivity

    var body: some View {
        HStack(alignment: .top, spacing: OOSpace.small) {
            OOToolStatus(state)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(OOColor.ink)
                Text(activity.summary)
                    .font(.subheadline)
                    .foregroundStyle(OOColor.inkSecondary)
                if !activity.files.isEmpty {
                    // Long file names scroll inside the row instead of widening the page.
                    ScrollView(.horizontal) {
                        Text(verbatim: activity.files.joined(separator: "  "))
                            .font(OOFont.mono(size: 12, relativeTo: .caption))
                            .foregroundStyle(OOColor.inkSecondary)
                            .fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var state: OOToolStatus.State {
        switch activity.status {
        case .running: .running
        case .completed: .done
        case .failed: .failed
        }
    }
}

/// One message as plain text. Fenced code keeps its lines and scrolls sideways in its own box.
private struct WorkRoomMessageRow: View {
    let message: OIPProviderMessage
    let provider: OIPProvider

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: OORadius.large, style: .continuous)
        VStack(alignment: .leading, spacing: OOSpace.small) {
            Text(message.role == .user ? "User" : provider.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(OOColor.inkSecondary)
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let text):
                    Text(verbatim: text)
                        .font(.body)
                        .foregroundStyle(OOColor.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(verbatim: code)
                            .font(OOFont.mono(size: 13))
                            .foregroundStyle(OOColor.ink)
                            .fixedSize()
                            .textSelection(.enabled)
                            .padding(OOSpace.small)
                    }
                    .background(OOColor.surface, in: RoundedRectangle(cornerRadius: OORadius.medium))
                }
            }
        }
        .padding(OOSpace.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? OOColor.hover : OOColor.paper, in: shape)
        .overlay(shape.stroke(OOColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

#Preview("Work Room") {
    let message = { (id: String, role: OIPProviderMessage.Role, text: String) in
        OIPProviderMessage(
            invocationID: "codex:preview", parentToolCallID: "preview", provider: .codex,
            messageID: id, role: role, text: text
        )
    }
    let step = { (id: String, sequence: Int, status: OIPProviderActivity.Status, summary: String) in
        OIPProviderActivity(
            invocationID: "codex:preview", parentToolCallID: "preview", provider: .codex, activityID: id,
            sequence: sequence, kind: .command, status: status, title: "Run the requested tests",
            summary: summary, files: ["test_sort_with_a_very_long_name_that_needs_to_scroll_sideways.c"]
        )
    }
    return OOPreviewPair {
        OOWorkRoomView(workRoom: WorkRoom(
            id: "codex:preview", toolCallID: "preview", provider: .codex,
            title: "Build and verify the requested C program", status: .running,
            summary: "Working in the selected workspace",
            activities: [
                step("t1", 1, .completed, "Completed the requested tests"),
                step("t2", 2, .failed, "The requested tests failed"),
                step("t3", 3, .running, "Running the requested tests")
            ],
            messages: [
                message("user:initial", .user, "Write sort.c and test it."),
                message("user:request-1", .user, "Fix the failing test."),
                message("assistant:reply", .assistant,
                        "Rebuilding:\n```\ncc -std=c11 -Wall -o build/sort /workspace/project/src/sort.c test_sort.c\n```")
            ]
        ))
        .frame(width: 375, height: 640)
    }
}
