import Foundation
import XCTest
@testable import ConnectOnionKit

final class SidebarTimeTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }
    private let locale = Locale(identifier: "en_GB")  // day-month order, as the team reads it; other locales get their own order
    // Wednesday 18 November 2026, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_014_000)

    private func relative(_ secondsAgo: TimeInterval) -> String {
        SidebarTime.relative(now.addingTimeInterval(-secondsAgo), now: now, calendar: calendar, locale: locale)
    }

    func testRecentTimesAreShortCounts() {
        XCTAssertEqual(relative(20), "now")
        XCTAssertEqual(relative(-30), "now", "a clock a little ahead is still now")
        XCTAssertEqual(relative(2 * 60), "2m")
        XCTAssertEqual(relative(59 * 60), "59m")
        XCTAssertEqual(relative(3 * 3_600), "3h")
    }

    func testEarlierDaysUseWordsThenDates() {
        XCTAssertEqual(relative(16 * 3_600), "Yesterday", "after midnight, a few hours ago is yesterday")
        XCTAssertEqual(relative(3 * 86_400), "Sun")
        XCTAssertEqual(relative(8 * 86_400), "10 Nov")
        XCTAssertEqual(relative(400 * 86_400), "14 Oct 2025")
    }
}

final class SidebarChatStatusTests: XCTestCase {
    func testEachStatusHasShortWords() {
        XCTAssertEqual(SidebarChatStatus.approval.label, "Approve")
        XCTAssertEqual(SidebarChatStatus.notSent.label, "Not sent")
        XCTAssertEqual(SidebarChatStatus.working.label, "Working")
        XCTAssertEqual(SidebarChatStatus.approval.spokenLabel, "needs your approval")
        XCTAssertEqual(SidebarChatStatus.reply.label, "Reply")
        XCTAssertEqual(SidebarChatStatus.reply.spokenLabel, "waiting for your reply")
        XCTAssertTrue(SidebarChatStatus.reply.needsYou)
    }

    // Waiting on you beats a failure, which beats something just running.
    func testTheMostUrgentStatusWins() {
        XCTAssertEqual(SidebarChatStatus.mostUrgent([.working, .approval, .notSent]), .approval)
        XCTAssertEqual(SidebarChatStatus.mostUrgent([.working, .notSent]), .notSent)
        XCTAssertEqual(SidebarChatStatus.mostUrgent([.notSent, .reply]), .reply)
        XCTAssertEqual(SidebarChatStatus.mostUrgent([.working]), .working)
        XCTAssertNil(SidebarChatStatus.mostUrgent([]))
    }
}

final class SidebarAttentionTests: XCTestCase {
    // One short line that never wraps; the chats themselves are a tap away.
    func testOneChatSaysWhatItNeeds() {
        XCTAssertEqual(SidebarAttention.summary([.approval]), "1 chat needs approval")
        // A question or an invite code isn't an approval.
        XCTAssertEqual(SidebarAttention.summary([.reply]), "1 chat needs a reply")
        XCTAssertEqual(SidebarAttention.summary([.notSent]), "1 message not sent")
    }

    func testSeveralChatsAreCountedTogether() {
        XCTAssertEqual(SidebarAttention.summary([.approval, .notSent]), "2 chats need attention")
        XCTAssertEqual(SidebarAttention.summary([.approval, .approval, .notSent]), "3 chats need attention")
    }

    // A working chat doesn't need you.
    func testNothingToSayWhenNothingNeedsYou() {
        XCTAssertNil(SidebarAttention.summary([]))
        XCTAssertNil(SidebarAttention.summary([.working, .working]))
        XCTAssertEqual(SidebarAttention.summary([.working, .approval]), "1 chat needs approval")
    }
}

final class ChatTitleTests: XCTestCase {
    func testTitleIsTheFirstRealLine() {
        XCTAssertEqual(ChatTitle.from("  List my home directory  "), "List my home directory")
        XCTAssertEqual(ChatTitle.from("\n\nFix the parser\nIt crashes on empty input"), "Fix the parser")
        XCTAssertEqual(ChatTitle.from("Summarise   these\tPRs"), "Summarise these PRs")
    }

    // The chat keeps waiting for a real message to name it.
    func testSlashCommandsAndEmptyMessagesGiveNoTitle() {
        XCTAssertNil(ChatTitle.from("/hello"))
        XCTAssertNil(ChatTitle.from("  /review-pr 42"))
        XCTAssertNil(ChatTitle.from("   \n  "))
    }

    // Stored whole up to the cap; the row truncates on screen, never with literal dots.
    func testLongLinesAreCutAtAWordWithoutDots() {
        let line = Array(repeating: "word", count: 40).joined(separator: " ")
        let title = ChatTitle.from(line)
        XCTAssertLessThanOrEqual(title?.count ?? 0, ChatTitle.maximumLength)
        XCTAssertFalse(title?.hasSuffix(" ") ?? true)
        XCTAssertFalse(title?.contains("…") ?? true)
        XCTAssertTrue(title?.hasSuffix("word") ?? false)
    }
}
