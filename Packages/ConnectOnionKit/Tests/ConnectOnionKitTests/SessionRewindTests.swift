import Foundation
import XCTest
@testable import ConnectOnionKit

final class SessionRewindTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)

    // The shape the ConnectOnion host sends back after two turns.
    private let twoTurns: [String: JSONValue] = [
        "session_id": .string("chat-1"),
        "messages": .array([
            .object(["role": .string("user"), "content": .string("hello")]),
            .object(["role": .string("assistant"), "content": .string("Hi!")]),
            .object(["role": .string("user"), "content": .string("list files")]),
            .object(["role": .string("assistant"), "content": .null]),
            .object(["role": .string("tool"), "content": .string("a.txt")]),
            .object(["role": .string("assistant"), "content": .string("Just a.txt.")])
        ]),
        "trace": .array([
            .object(["type": .string("user_input"), "content": .string("hello"), "turn": .number(1)]),
            .object(["type": .string("llm_call"), "turn": .number(1)]),
            .object(["type": .string("user_input"), "content": .string("list files"), "turn": .number(2)]),
            .object(["type": .string("tool_result"), "turn": .number(2)])
        ]),
        "turn": .number(2),
        "iteration": .number(3),
        "updated": .number(1_000),
        "mode": .string("safe")
    ]

    func testDropsYourLatestMessageAndEverythingTheAgentDidAfterIt() {
        let rewound = SessionRewind.droppingLatestTurn(from: twoTurns, now: now)

        XCTAssertEqual(rewound?["messages"], .array([
            .object(["role": .string("user"), "content": .string("hello")]),
            .object(["role": .string("assistant"), "content": .string("Hi!")])
        ]))
        XCTAssertEqual(rewound?["trace"], .array([
            .object(["type": .string("user_input"), "content": .string("hello"), "turn": .number(1)]),
            .object(["type": .string("llm_call"), "turn": .number(1)])
        ]))
    }

    // The host keeps whichever copy is ahead on (turn, iteration, updated), in that order. Same
    // turn, one more iteration: ours wins, and a newer turn from another device still beats it.
    func testKeepsTheTurnAndOutranksTheHostsCopyOnIteration() {
        let rewound = SessionRewind.droppingLatestTurn(from: twoTurns, now: now)

        XCTAssertEqual(rewound?["turn"], .number(2))
        XCTAssertEqual(rewound?["iteration"], .number(4))
        XCTAssertEqual(rewound?["updated"], .number(2_000))
    }

    func testKeepsEverythingElse() {
        let rewound = SessionRewind.droppingLatestTurn(from: twoTurns, now: now)

        XCTAssertEqual(rewound?["session_id"], .string("chat-1"))
        XCTAssertEqual(rewound?["mode"], .string("safe"))
    }

    func testNothingToRewindWithoutAMessageOfYours() {
        XCTAssertNil(SessionRewind.droppingLatestTurn(from: ["session_id": .string("chat-1")], now: now))
        XCTAssertNil(SessionRewind.droppingLatestTurn(from: [
            "messages": .array([.object(["role": .string("assistant"), "content": .string("Welcome")])])
        ], now: now))
    }

    // Core adds user-role messages mid-turn: a system reminder (internal) and a message sent
    // while the agent worked (framed, and traced with runtime_input). Neither starts the turn.
    func testSkipsMessagesCoreAddedMidTurn() throws {
        var session = twoTurns
        var messages = try XCTUnwrap(session["messages"]?.arrayValue)
        messages.insert(.object([
            "role": .string("user"),
            "content": .string("<system-reminder>\nThe user uploaded a file\n</system-reminder>"),
            "internal": .bool(true)
        ]), at: 3)
        messages.append(.object([
            "role": .string("user"),
            "content": .string(SessionRewind.runtimeInputPrefix + " Treat it as context.]\n\nalso b.txt")
        ]))
        session["messages"] = .array(messages)
        var trace = try XCTUnwrap(session["trace"]?.arrayValue)
        trace.append(.object([
            "type": .string("user_input"), "content": .string("also b.txt"), "runtime_input": .bool(true)
        ]))
        session["trace"] = .array(trace)

        let rewound = SessionRewind.droppingLatestTurn(from: session, prompt: "list files", now: now)

        XCTAssertEqual(rewound?["messages"]?.arrayValue?.count, 2)
        XCTAssertEqual(rewound?["trace"]?.arrayValue?.count, 2)
    }

    func testCutsAtTheMessageWithThePromptBeingRedone() {
        let rewound = SessionRewind.droppingLatestTurn(from: twoTurns, prompt: "  list files ", now: now)
        XCTAssertEqual(rewound?["messages"]?.arrayValue?.count, 2)

        XCTAssertNil(
            SessionRewind.droppingLatestTurn(from: twoTurns, prompt: "something else", now: now),
            "no message carries that prompt, so there's nothing safe to cut"
        )
    }

    func testFindsThePromptInAMessageSentWithImages() {
        var session = twoTurns
        session["messages"] = .array([
            .object(["role": .string("user"), "content": .array([
                .object(["type": .string("text"), "text": .string("list files")]),
                .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:")])])
            ])]),
            .object(["role": .string("assistant"), "content": .string("Done.")])
        ])
        session["trace"] = nil

        let rewound = SessionRewind.droppingLatestTurn(from: session, prompt: "list files", now: now)

        XCTAssertEqual(rewound?["messages"], .array([]))
    }
}
