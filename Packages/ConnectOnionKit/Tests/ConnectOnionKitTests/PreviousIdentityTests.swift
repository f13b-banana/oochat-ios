import XCTest
@testable import ConnectOnionKit

final class PreviousIdentityTests: XCTestCase {
    private let old = "0xaaaa"
    private let new = "0xbbbb"

    func testAnUnstampedConversationIsCurrent() {
        XCTAssertFalse(PreviousIdentity.isPrevious(stamp: nil, current: new))
        XCTAssertFalse(PreviousIdentity.isPrevious(stamp: nil, current: nil))
    }

    func testAConversationStampedWithTheCurrentAddressIsCurrentInAnyCase() {
        XCTAssertFalse(PreviousIdentity.isPrevious(stamp: new, current: new))
        XCTAssertFalse(PreviousIdentity.isPrevious(stamp: "0xBBBB", current: new))
    }

    func testAConversationStampedWithAnotherAddressIsPrevious() {
        XCTAssertTrue(PreviousIdentity.isPrevious(stamp: old, current: new))
    }

    // Without a readable current Address the device can't sign as the stamp, so the chat stays locked.
    func testAStampWithAnUnknownCurrentAddressIsPrevious() {
        XCTAssertTrue(PreviousIdentity.isPrevious(stamp: old, current: nil))
    }

    func testReplacingStampsAnUnstampedConversationWithTheReplacedAddress() {
        XCTAssertEqual(PreviousIdentity.stamp(nil, replacing: old), old)
    }

    func testReplacingKeepsAnExistingStamp() {
        XCTAssertEqual(PreviousIdentity.stamp("0xfirst", replacing: old), "0xfirst")
    }

    func testLinkingBackToTheStampedAddressMakesTheConversationCurrentAgain() {
        let stamp = PreviousIdentity.stamp(nil, replacing: old)
        XCTAssertTrue(PreviousIdentity.isPrevious(stamp: stamp, current: new))
        XCTAssertFalse(PreviousIdentity.isPrevious(stamp: PreviousIdentity.stamp(stamp, replacing: new), current: old))
    }
}
