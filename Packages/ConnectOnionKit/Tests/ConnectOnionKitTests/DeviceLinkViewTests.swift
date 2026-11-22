import Foundation
import SwiftUI
import Testing
@testable import ConnectOnionKit

@Test func theQRCodeIsDrawnForAnOffer() throws {
    let payload = try DeviceLinkReceiver().offer.qrPayload

    let image = try #require(DeviceLinkView<Never>.qrImage(for: payload))

    #expect(image.width == image.height)
    #expect(image.width >= 21) // the smallest QR is 21 modules a side
}

@Test func theLinkCodeIsShownInTwoGroupsOfFive() {
    #expect(DeviceLinkView<Never>.grouped("0123456789") == "01234 56789")
}

@Test func theExpiryCountsDownToExpired() {
    let expiry = Date(timeIntervalSince1970: 1_000)

    #expect(DeviceLinkView<Never>.expiryText(expiry, now: expiry.addingTimeInterval(-102)) == "Expires in 1:42")
    #expect(DeviceLinkView<Never>.expiryText(expiry, now: expiry.addingTimeInterval(-5.5)) == "Expires in 0:06")
    #expect(DeviceLinkView<Never>.expiryText(expiry, now: expiry) == "Expired")
}

@Test func settingsNamesBothEntryPoints() {
    #expect(DeviceLinkRole.giving.settingsTitle == "Link a new device")
    #expect(DeviceLinkRole.receiving.settingsTitle == "Link from another device")
}

@Test func codeEntryOffersScanningOnlyWhenTheAppGaveAScanner() {
    let typingOnly = DeviceLinkView<EmptyView>.codeEntryInstruction(for: .giving)
    let withScanner = DeviceLinkView<Text>.codeEntryInstruction(for: .giving)

    #expect(!typingOnly.contains("Scan"))
    #expect(typingOnly.contains("type the Link Code"))
    #expect(withScanner.contains("Scan the QR code"))
    #expect(DeviceLinkView<EmptyView>.enterCodeInstead == "Type a code instead")
    #expect(DeviceLinkView<Text>.enterCodeInstead == "Scan a code instead")
}

@Test func theInstructionsSendThePersonToTheOtherRoleOnTheOtherDevice() {
    let giverOtherDevice = "Settings › Identity › \(DeviceLinkRole.giving.settingsTitle)"
    let receiverOtherDevice = "Settings › Identity › \(DeviceLinkRole.receiving.settingsTitle)"

    #expect(DeviceLinkView<Text>.codeEntryInstruction(for: .giving).contains(receiverOtherDevice))
    #expect(DeviceLinkView<Text>.codeEntryInstruction(for: .receiving).contains(giverOtherDevice))
    #expect(DeviceLinkView<Text>.showingCodeInstruction(for: .giving).contains(receiverOtherDevice))
    #expect(DeviceLinkView<Text>.showingCodeInstruction(for: .receiving).contains(giverOtherDevice))
}

@Test func theReplaceWarningSaysAgentNamesWillMatch() {
    #expect(DeviceLinkFlow.agentNamesWarning == "Agent names will match the other device.")
    #expect(DeviceLinkView<Text>.replaceMessage.hasSuffix(" Agent names will match the other device."))
}
