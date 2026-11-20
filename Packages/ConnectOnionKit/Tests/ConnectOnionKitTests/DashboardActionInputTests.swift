import Foundation
import Testing
@testable import ConnectOnionKit

// What the skill checker lets through becomes a signed INPUT frame built by the kit.
// Same key, host and clock as OIPClientFramesTests.
private let fixtureKey = Data((0..<32).map { UInt8($0) })
private let host = "0x" + String(repeating: "ab", count: 32)

private func frames() -> OIPClientFrames {
    let now = Date(timeIntervalSince1970: 1_700_000_000.9)
    return OIPClientFrames(
        keyStore: InMemoryPrivateKeyStore(rawKey: fixtureKey),
        to: host,
        now: { now },
        nonce: { "nonce-1" }
    )
}

private let profileSkills = [
    OIPAgentSkill(name: "commit", description: nil, location: nil),
    OIPAgentSkill(name: "review", description: "Reviews a diff", location: nil)
]

/// The app's path in miniature: the checker first, then the kit builder. nil means nothing is sent.
private func inputFrame(
    skill: String,
    args: String?,
    skills: [OIPAgentSkill]? = profileSkills
) throws -> [String: JSONValue]? {
    guard case .send(let prompt) = SkillActionChecker.check(skill: skill, args: args, availableSkills: skills) else {
        return nil
    }
    return try frames().input(inputID: "input-1", prompt: prompt)
}

private func signedPrompt(of frame: [String: JSONValue]) -> String? {
    guard case .object(let payload)? = frame["payload"] else {
        return nil
    }
    return payload["prompt"]?.stringValue
}

@Test func anAllowedPressBecomesASignedInputFrame() throws {
    let built = try inputFrame(skill: "commit", args: "fix the login bug")
    let frame = try #require(built)

    #expect(frame["type"] == .string("INPUT"))
    #expect(frame["to"] == .string(host))
    #expect(frame["input_id"] == .string("input-1"))
    #expect(frame["prompt"] == .string("/commit fix the login bug"))
    #expect(signedPrompt(of: frame) == "/commit fix the login bug")
    #expect(frame["signature"]?.stringValue?.isEmpty == false)
}

@Test func argumentsAreCleanedBeforeTheyAreSigned() throws {
    let built = try inputFrame(skill: "commit", args: "  fix\n the   login\tbug ")
    let frame = try #require(built)

    #expect(frame["prompt"] == .string("/commit fix the login bug"))
    #expect(signedPrompt(of: frame) == "/commit fix the login bug")
}

@Test func aPressWithoutArgumentsSignsTheBareSkill() throws {
    let built = try inputFrame(skill: "review", args: "")
    let frame = try #require(built)

    #expect(signedPrompt(of: frame) == "/review")
}

@Test func longArgumentsAreCutBeforeTheyAreSigned() throws {
    let built = try inputFrame(skill: "commit", args: String(repeating: "a", count: 600))
    let frame = try #require(built)

    #expect(signedPrompt(of: frame)?.count == "/commit ".count + SkillActionChecker.maxArgumentLength)
}

@Test func aRefusedPressBuildsNoFrame() throws {
    #expect(try inputFrame(skill: "deploy", args: nil) == nil)
    #expect(try inputFrame(skill: "../commit", args: nil) == nil)
    #expect(try inputFrame(skill: "commit", args: nil, skills: nil) == nil)
    #expect(try inputFrame(skill: "commit", args: nil, skills: []) == nil)
}
