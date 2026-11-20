import XCTest
@testable import OOChatIOS

@MainActor
final class ConversationBarrierScopeTests: XCTestCase {
    func testConversationsGetDistinctScopesThatSurviveRelaunch() throws {
        let repository = InMemoryConversationRepository()
        let state = ConversationState(store: repository)
        let agent = state.saveAgent(id: nil, name: "Agent", address: "0xabc")
        let first = state.createConversation(for: agent, currentDraft: "")
        let second = state.createConversation(for: agent, currentDraft: "")

        let firstScope = try XCTUnwrap(state.barrierScope(forConversationID: first.id))
        let secondScope = try XCTUnwrap(state.barrierScope(forConversationID: second.id))
        XCTAssertNotEqual(firstScope, secondScope)

        let relaunched = ConversationState(store: repository)
        XCTAssertEqual(relaunched.barrierScope(forConversationID: first.id), firstScope)
        XCTAssertNil(relaunched.barrierScope(forConversationID: "unsaved"))
    }
}
