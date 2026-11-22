import Testing
@testable import ConnectOnionKit

@Suite struct MirroredTurnTests {
    private func item(_ type: String, _ text: String) -> JSONValue {
        .object(["type": .string(type), "content": .string(text)])
    }

    @Test func itemsKeepOnlyUserAndAgentText() {
        let items = MirroredTurn.items(fromChatItems: [
            item("user", "hi"), item("tool_call", "x"), item("agent", "yo"),
            .object(["type": .string("agent")])
        ])
        #expect(items == [CatchUpItem(role: .user, text: "hi"), CatchUpItem(role: .agent, text: "yo")])
        #expect(MirroredTurn.items(fromChatItems: nil).isEmpty)
    }

    @Test func promptComesFromUserMessageContent() {
        #expect(MirroredTurn.prompt(fromUserMessage: ["content": .string("hello")]) == "hello")
        #expect(MirroredTurn.prompt(fromUserMessage: [:]) == nil)
    }

    private let host = [
        CatchUpItem(role: .user, text: "a"), CatchUpItem(role: .agent, text: "A"),
        CatchUpItem(role: .user, text: "b"), CatchUpItem(role: .agent, text: "B")
    ]

    @Test func addsEverythingAfterLastKnownItem() {
        let local = [CatchUpItem(role: .user, text: "a"), CatchUpItem(role: .agent, text: " A ")]
        let steps = MirroredTurn.catchUpSteps(host: host, local: local, isRunning: false)
        #expect(steps == [.user("b"), .agent("B")])
    }

    @Test func emptyTranscriptTakesOnlyNewestTurn() {
        let steps = MirroredTurn.catchUpSteps(host: host, local: [], isRunning: false)
        #expect(steps == [.user("b"), .agent("B")])
    }

    @Test func runningLastPromptGetsARun() {
        let running = Array(host.prefix(3))
        let fresh = MirroredTurn.catchUpSteps(host: running, local: [], isRunning: true)
        #expect(fresh == [.runningUser("b", isKnown: false)])
        let local = [CatchUpItem(role: .user, text: "b")]
        let known = MirroredTurn.catchUpSteps(host: running, local: local, isRunning: true)
        #expect(known == [.runningUser("b", isKnown: true)])
    }

    @Test func nothingToAddWhenUpToDate() {
        let local = host.map { CatchUpItem(role: $0.role, text: $0.text) }
        #expect(MirroredTurn.catchUpSteps(host: host, local: local, isRunning: false).isEmpty)
    }

    @Test func viewerStateLocksAndReleases() {
        var state = ViewerTurnState()
        state.apply(.userMessage)
        #expect(state.isActive && state.isMirrored)
        #expect(state.interruptInputID(local: "mine") == nil)
        state.apply(.finished)
        #expect(!state.isActive && !state.isMirrored)
    }

    @Test func catchUpNeverOverridesLocalTurn() {
        var state = ViewerTurnState()
        state.apply(.localSendStarted)
        state.apply(.catchUp(isRunning: false))
        #expect(state.isActive && !state.isMirrored)
        #expect(state.interruptInputID(local: "mine") == "mine")
    }

    @Test func endedViewerReleasesOnlyMirroredTurn() {
        var mirrored = ViewerTurnState()
        mirrored.apply(.catchUp(isRunning: true))
        mirrored.apply(.viewerEnded)
        #expect(!mirrored.isActive)
        var local = ViewerTurnState()
        local.apply(.localSendStarted)
        local.apply(.viewerEnded)
        #expect(local.isActive)
    }

    @Test func userMessageDoesNotOverrideLocalTurn() {
        var state = ViewerTurnState()
        state.apply(.localSendStarted)
        state.apply(.userMessage)
        #expect(state.isActive && !state.isMirrored)
    }

    @Test func sameTextTrims() {
        #expect(MirroredTurn.sameText(" a\n", "a"))
        #expect(!MirroredTurn.sameText("a", "b"))
    }
}
