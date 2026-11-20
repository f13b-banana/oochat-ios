import Foundation
import XCTest
@testable import ConnectOnionKit

/// Real Provider previews through the Work Room store: a screenshot shows only while it is evidence for the
/// invocation's current revision, and anything invalid or outdated removes it.
@MainActor
final class WorkRoomPreviewTests: XCTestCase {

    // MARK: Helpers

    private func fields(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> [String: JSONValue] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/frames"),
            "Missing fixture \(name).json"
        )
        var body = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: url))
        for (key, value) in changes {
            body[key] = value
        }
        return body
    }

    private func frame(_ name: String, _ changes: [String: JSONValue?] = [:]) throws -> OIPServerFrame {
        OIPServerFrame.decode(try fields(name, changes))
    }

    private func invocation(_ revision: Int) throws -> OIPServerFrame {
        try frame("provider_invocation", ["stateRevision": .number(Double(revision))])
    }

    private func artifact(_ changes: [String: JSONValue?] = [:], name: String = "provider_artifact") throws -> OIPServerFrame {
        try frame(name, changes)
    }

    /// A store holding the invocation at revision 2 and the fixture's screenshot, which is for revision 2.
    private func storeWithPreview() throws -> WorkRoomStore {
        let store = WorkRoomStore()
        store.receive(try invocation(2))
        store.receive(try artifact())
        return store
    }

    private func preview(_ store: WorkRoomStore) -> OIPProviderArtifact.Screenshot? {
        store.workRooms.first?.preview
    }

    private func dataURL(mime: String = "image/png", _ bytes: [UInt8]) -> JSONValue {
        .string("data:\(mime);base64,\(Data(bytes).base64EncodedString())")
    }

    // MARK: Current

    func testACurrentScreenshotIsShownWithItsBytesAndAlt() throws {
        let screenshot = try XCTUnwrap(preview(try storeWithPreview()))
        XCTAssertEqual(screenshot.alt, "Latest provider workspace view")
        XCTAssertEqual(screenshot.stateRevision, 2)
        XCTAssertTrue([UInt8](screenshot.imageData).starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func testAJPEGScreenshotIsShownAndTheBrowserAltIsAllowed() throws {
        let store = WorkRoomStore()
        store.receive(try invocation(2))
        store.receive(try artifact(["alt": .string("Latest provider browser view")], name: "provider_artifact.jpeg"))
        let screenshot = try XCTUnwrap(preview(store))
        XCTAssertEqual(screenshot.alt, "Latest provider browser view")
        XCTAssertEqual([UInt8](screenshot.imageData).prefix(2), [0xFF, 0xD8])
    }

    func testANewerScreenshotReplacesTheCurrentOne() throws {
        let store = try storeWithPreview()
        store.receive(try invocation(3))
        store.receive(try artifact(["artifactId": .string("latest-3"), "stateRevision": .number(3)]))
        XCTAssertEqual(preview(store)?.artifactID, "latest-3")
    }

    // MARK: Revision

    func testAScreenshotForAnotherRevisionIsDroppedAndRemovesTheCurrentPreview() throws {
        let store = try storeWithPreview()
        store.receive(try artifact(["stateRevision": .number(1)]))
        XCTAssertNil(preview(store))
        store.receive(try artifact())
        XCTAssertNotNil(preview(store))
        store.receive(try artifact(["stateRevision": .number(3)]))
        XCTAssertNil(preview(store))
    }

    func testANewerInvocationRevisionRemovesThePreview() throws {
        let store = try storeWithPreview()
        store.receive(try invocation(3))
        XCTAssertNil(preview(store))
    }

    func testAReplayOfTheOutdatedScreenshotDoesNotRevivePreview() throws {
        let store = try storeWithPreview()
        store.receive(try invocation(3))
        store.receive(try artifact())
        XCTAssertNil(preview(store))
    }

    func testAScreenshotBeforeItsRevisionIsOnScreenIsNotShown() throws {
        let store = WorkRoomStore()
        store.receive(try invocation(1))
        store.receive(try artifact())
        XCTAssertNil(preview(store))
        store.receive(try invocation(2))
        XCTAssertNil(preview(store))
    }

    func testAnEqualRevisionInvocationReplayKeepsThePreview() throws {
        let store = try storeWithPreview()
        store.receive(try invocation(2))
        XCTAssertNotNil(preview(store))
    }

    // MARK: Invalid

    private func assertInvalidRemovesPreview(
        _ changes: [String: JSONValue?], _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let store = try storeWithPreview()
        XCTAssertNotNil(preview(store), file: file, line: line)
        store.receive(try artifact(changes))
        XCTAssertNil(preview(store), message, file: file, line: line)
    }

    func testAnOversizedDataURLRemovesThePreview() throws {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let fits = dataURL(signature + [UInt8](repeating: 0, count: 190_000))
        let tooBig = dataURL(signature + [UInt8](repeating: 0, count: 200_000))
        XCTAssertLessThanOrEqual(try XCTUnwrap(fits.stringValue).count, OIPProviderArtifact.dataURLLimit)
        XCTAssertGreaterThan(try XCTUnwrap(tooBig.stringValue).count, OIPProviderArtifact.dataURLLimit)
        let store = WorkRoomStore()
        store.receive(try invocation(2))
        store.receive(try artifact(["thumbnailDataUrl": fits]))
        XCTAssertNotNil(preview(store), "only the size differs from the oversized case")
        store.receive(try artifact(["thumbnailDataUrl": tooBig]))
        XCTAssertNil(preview(store))
    }

    func testTheWrongMimeTypeRemovesThePreview() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]
        try assertInvalidRemovesPreview(["thumbnailDataUrl": dataURL(mime: "image/gif", png)], "gif")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": dataURL(mime: "image/svg+xml", png)], "svg")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": .string("https://example.com/shot.png")], "a URL")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": .string("/tmp/shot.png")], "a path")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": .string("data:text/plain;base64,AAAA")], "text")
    }

    func testBadBase64RemovesThePreview() throws {
        let prefix = "data:image/png;base64,"
        try assertInvalidRemovesPreview(["thumbnailDataUrl": .string(prefix + "iVBO*Rw0K")], "bad character")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": .string(prefix + "iVBORw0")], "bad padding")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": .string(prefix + "iVBORw===")], "too much padding")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": .string(prefix)], "empty")
    }

    func testBadMagicBytesRemoveThePreview() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0xFF, 0xD9]
        try assertInvalidRemovesPreview(["thumbnailDataUrl": dataURL([0x3C, 0x73, 0x76, 0x67])], "svg bytes as png")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": dataURL(mime: "image/jpeg", png)], "png bytes as jpeg")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": dataURL(jpeg)], "jpeg bytes as png")
        try assertInvalidRemovesPreview(["thumbnailDataUrl": dataURL(mime: "image/jpeg", Array(jpeg.dropLast()))], "no end")
        let store = WorkRoomStore()
        store.receive(try invocation(2))
        store.receive(try artifact(["thumbnailDataUrl": dataURL(mime: "image/jpeg", jpeg)]))
        XCTAssertNotNil(preview(store))
    }

    func testAnUnknownAltRemovesThePreview() throws {
        try assertInvalidRemovesPreview(["alt": .string("Latest provider terminal view")], "unknown alt")
        try assertInvalidRemovesPreview(["alt": .string("latest provider workspace view")], "case")
        try assertInvalidRemovesPreview(["alt": nil], "no alt")
    }

    func testOtherFieldsThatBreakTheRulesRemoveThePreview() throws {
        try assertInvalidRemovesPreview(["kind": .string("diff")], "kind")
        try assertInvalidRemovesPreview(["kind": nil], "no kind")
        try assertInvalidRemovesPreview(["artifactId": .string("has space")], "artifact id")
        try assertInvalidRemovesPreview(["artifactId": .string(String(repeating: "a", count: 129))], "long artifact id")
        try assertInvalidRemovesPreview(["stateRevision": .number(0)], "revision zero")
        try assertInvalidRemovesPreview(["stateRevision": nil], "no revision")
    }

    func testAnArtifactForAnUnknownInvocationIsDroppedAndTouchesNothing() throws {
        let store = try storeWithPreview()
        store.receive(try artifact(["invocationId": .string("codex:other"), "parentToolCallId": .string("other")]))
        store.receive(try artifact(["parentToolCallId": .string("other")]))
        XCTAssertNotNil(preview(store))
        let empty = WorkRoomStore()
        empty.receive(try artifact())
        XCTAssertTrue(empty.workRooms.isEmpty)
        empty.receive(try invocation(2))
        XCTAssertNil(preview(empty))
    }

    func testAFrameWithoutItsCorrelationStaysUnknown() throws {
        for key in ["invocationId", "parentToolCallId", "provider"] {
            let body = try fields("provider_artifact", [key: nil])
            XCTAssertEqual(OIPServerFrame.decode(body), .unknown(type: "provider_artifact", body: body), key)
        }
    }

    // MARK: Snapshot

    private func snapshotArtifact(_ changes: [String: JSONValue?] = [:]) throws -> JSONValue {
        var nested = try fields("provider_artifact", changes)
        for key in ["type", "provider", "invocationId", "parentToolCallId", "artifactId"] {
            nested[key] = nil
        }
        nested["id"] = .string("latest-3")
        nested["stateRevision"] = changes["stateRevision"] ?? .number(3)
        return .object(nested)
    }

    private func snapshot(artifact: JSONValue?) throws -> OIPConnected {
        var body = try fields("CONNECTED.snapshot")
        var items = try XCTUnwrap(body["chat_items"]?.arrayValue)
        var invocation = try XCTUnwrap(items[1].objectValue)
        invocation["artifact"] = artifact
        items[1] = .object(invocation)
        body["chat_items"] = .array(items)
        guard case .connected(let connected) = OIPServerFrame.decode(body) else {
            throw XCTSkip("not a CONNECTED frame")
        }
        return connected
    }

    func testASnapshotArtifactForTheCurrentRevisionIsShown() throws {
        let store = WorkRoomStore()
        store.receiveSnapshot(try snapshot(artifact: try snapshotArtifact()))
        XCTAssertEqual(preview(store)?.artifactID, "latest-3")
    }

    func testASnapshotArtifactIsValidatedLikeALiveOne() throws {
        for changes: [String: JSONValue?] in [
            ["stateRevision": .number(2)], ["alt": .string("Anything else")], ["kind": .string("diff")],
            ["thumbnailDataUrl": dataURL([0x3C, 0x73, 0x76, 0x67])]
        ] {
            let store = WorkRoomStore()
            store.receiveSnapshot(try snapshot(artifact: try snapshotArtifact(changes)))
            XCTAssertNil(preview(store), "\(changes)")
            XCTAssertEqual(store.workRooms.count, 1)
        }
    }

    func testASnapshotWithoutAnArtifactRemovesAnOutdatedPreview() throws {
        let store = try storeWithPreview()
        store.receiveSnapshot(try snapshot(artifact: nil))
        XCTAssertNil(preview(store))
    }
}
