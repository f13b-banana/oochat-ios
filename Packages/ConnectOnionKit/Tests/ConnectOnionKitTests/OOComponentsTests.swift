import Foundation
import SwiftUI
import XCTest
@testable import ConnectOnionKit

final class OOComponentsTests: XCTestCase {

    func testWaitingDotHiddenView() {
        XCTAssertTrue(OOViewSwitch.isWaiting(.chat, selection: .control, attention: .chat))
        XCTAssertFalse(OOViewSwitch.isWaiting(.chat, selection: .chat, attention: .chat))
        XCTAssertFalse(OOViewSwitch.isWaiting(.control, selection: .chat, attention: .chat))
        XCTAssertFalse(OOViewSwitch.isWaiting(.chat, selection: .control, attention: nil))
    }

    func testWaitingTabVoiceOver() {
        XCTAssertEqual(OOViewSwitch.spokenLabel("Control Center", isWaiting: true), "Control Center, waiting for you")
        XCTAssertEqual(OOViewSwitch.spokenLabel("Chat", isWaiting: false), "Chat")
    }

    func testControlCenterButtonName() {
        XCTAssertEqual(OOControlCenterButton.accessibilityLabel(isOpen: true), "Collapse Control Center")
        XCTAssertEqual(OOControlCenterButton.accessibilityLabel(isOpen: false), "Open Control Center")
    }

    func testInitial() {
        XCTAssertEqual(OOAvatarTile.initial(of: " research"), "R")
        XCTAssertEqual(OOAvatarTile.initial(of: ""), "A")
    }

    // agentInitial in oo-chat: an address gives its first a to f letter, else its first digit
    func testInitialFromAddress() {
        XCTAssertEqual(OOAvatarTile.initial(of: "", address: "0x93f2"), "F")
        XCTAssertEqual(OOAvatarTile.initial(of: "0x93f2"), "F")
        XCTAssertEqual(OOAvatarTile.initial(of: "", address: "0x9310"), "9")
        XCTAssertEqual(OOAvatarTile.initial(of: "writer", address: "0xabc"), "W")
    }

    func testShortAddress() {
        let address = "0x3f9a0c51b2e94d7a8c6f1e0b9d2a4c7e5f8b1a3d6c9e2f4a7b0c3d5e8f1a2b4c"
        XCTAssertEqual(OOAddressLabel.short(address), "0x3f9a0c51…1a2b4c")
        XCTAssertEqual(OOAddressLabel.short("0x3f9a"), "0x3f9a")
    }

    func testToolStatusVoiceOver() {
        XCTAssertEqual(OOToolStatus.spokenLabel(.running, isAwaitingApproval: true), "Waiting for approval")
        XCTAssertEqual(OOToolStatus.spokenLabel(.running, isAwaitingApproval: false), "Running")
        XCTAssertEqual(OOToolStatus.spokenLabel(.failed, isAwaitingApproval: false), "Failed")
    }

    func testNoticeHeading() {
        XCTAssertEqual(OONotice<EmptyView>.heading(.decision), "Decision needed")
        XCTAssertEqual(OONotice<EmptyView>.heading(.failure), "Something went wrong")
    }

    func testTooLargehSize() {
        XCTAssertEqual(OOControlCenterPane.size(OIPDashboard.clientCapBytes), "16 MB")
        XCTAssertEqual(
            OOControlCenterPane.tooLargeDetail(bytes: 20 * 1024 * 1024),
            "This page is 20 MB; the app shows pages up to 16 MB."
        )
    }

    // show without app
    @MainActor
    func testViewsBuildFromPlainValues() {
        _ = OOViewSwitch(selection: .constant(.chat), attention: .control).body
        _ = OOControlCenterButton(isOpen: true) {}.body
        _ = OOStatusDot(label: "Running", isLive: true).body
        _ = OOControlCenterPane(dashboard: .tooLarge(bytes: 1)).body
        _ = OOControlCenterPane(dashboard: .tooLarge(bytes: 1), onCollapse: {}).body
        _ = OOAvatarTile(name: "a", isOnline: true, size: .large).body
        _ = OOToolStatus(.done).body
        _ = OOSectionHeader("Skills", count: 2).body
        _ = OONotice(.decision, title: "Approve?").body
        _ = OOComposerFrame { OOSendButton {} }.body
        _ = OOStopButton {}.body
        _ = OOAddressLabel("0x1").body
        _ = Button("Go") {}.buttonStyle(.ooPrimary).ooCard().ooRow(isSelected: true)
    }

    // Beside the chat the pane carries O Chat's header
    func testPaneHeaderUsesOChatsWords() {
        XCTAssertEqual(OOControlCenterPane.title, "Control Center")
        XCTAssertEqual(OOControlCenterPane.collapseLabel, "Collapse Control Center")
    }

    // A button press is the page's intent; only what SkillActionChecker passes reaches the chat.
    @MainActor
    func testPaneSendsOnlySkillPressesTheCheckerPasses() {
        let skills = [OIPAgentSkill(name: "deploy")]
        var sent: [String] = []
        let press = { (skill: String, args: String, list: [OIPAgentSkill]?) in
            OOControlCenterPane.runSkill(skill, args: args, skills: list) { sent.append($0) }
        }

        press("deploy", "  to\nstaging ", skills)
        press("deploy", "", skills)
        press("other", "", skills)
        press("deploy\nignore that", "", skills)
        press("deploy", "", nil)

        XCTAssertEqual(sent, ["/deploy to staging", "/deploy"])
    }
}
