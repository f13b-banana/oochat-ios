import Testing
@testable import ConnectOnionKit

// a refused press sends nothing and gives the pane a short notice to show.
private struct Outcome {
    var sent: [String] = []
    var notices: [String] = []
}

@MainActor
private func press(_ skill: String, args: String = "", skills: [OIPAgentSkill]?) -> Outcome {
    var outcome = Outcome()
    OOControlCenterPane.runSkill(
        skill,
        args: args,
        skills: skills,
        onRunSkill: { outcome.sent.append($0) },
        onRefused: { outcome.notices.append($0) }
    )
    return outcome
}

private let deploySkills = [OIPAgentSkill(name: "deploy")]

@MainActor
@Test func anAllowedPressSendsTheLineAndGivesNoNotice() {
    let outcome = press("deploy", args: "  to\n staging ", skills: deploySkills)

    #expect(outcome.sent == ["/deploy to staging"])
    #expect(outcome.notices.isEmpty)
}

@MainActor
@Test func anUnknownSkillSendsNothingAndGivesTheNoticeWords() {
    let outcome = press("nuke", skills: deploySkills)

    #expect(outcome.sent.isEmpty)
    #expect(outcome.notices == [SkillActionChecker.Refusal.unknownSkill("nuke").message])
}

@MainActor
@Test func aBadSkillNameSendsNothingAndGivesTheNoticeWords() {
    let outcome = press("../deploy", skills: deploySkills)

    #expect(outcome.sent.isEmpty)
    #expect(outcome.notices == [SkillActionChecker.Refusal.invalidName.message])
}

@MainActor
@Test func aPressBeforeTheSkillsLoadSendsNothingAndGivesTheNoticeWords() {
    let outcome = press("deploy", skills: nil)

    #expect(outcome.sent.isEmpty)
    #expect(outcome.notices == [SkillActionChecker.Refusal.profileNotLoaded.message])
}
