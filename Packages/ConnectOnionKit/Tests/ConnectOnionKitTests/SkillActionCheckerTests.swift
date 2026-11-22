import Foundation
import XCTest
@testable import ConnectOnionKit

final class SkillActionCheckerTests: XCTestCase {
    private func skills(_ names: String...) -> [OIPAgentSkill] {
        names.map { OIPAgentSkill(name: $0, description: nil, location: nil) }
    }

    private func check(_ skill: String, _ args: String? = nil, in list: [OIPAgentSkill]? = nil) -> SkillActionChecker.Outcome {
        SkillActionChecker.check(skill: skill, args: args, availableSkills: list ?? skills("commit", "review"))
    }

    // A valid press

    func testAValidPressSendsTheSlashCommand() {
        XCTAssertEqual(check("commit", "fix the login bug"), .send("/commit fix the login bug"))
    }

    func testNoArgumentsSendsTheBareSkillName() {
        XCTAssertEqual(check("commit"), .send("/commit"))
        XCTAssertEqual(check("commit", ""), .send("/commit"))
        XCTAssertEqual(check("commit", "  \n\t "), .send("/commit"))
    }

    func testTheSkillDescriptionAndLocationDoNotMatter() {
        let list = [OIPAgentSkill(name: "review", description: "Reviews a diff", location: "skills/review.md")]
        XCTAssertEqual(check("review", in: list), .send("/review"))
    }

    // An unknown skill

    func testASkillTheAgentDoesNotHaveIsRefused() {
        XCTAssertEqual(check("deploy"), .refused(.unknownSkill("deploy")))
    }

    func testSkillNamesAreCaseSensitive() {
        XCTAssertEqual(check("Commit"), .refused(.unknownSkill("Commit")))
    }

    // A bad name

    func testNamesOutsideThePatternAreRefused() {
        let bad = ["", "-commit", "_commit", "my skill", "a/b", "/commit", "commit\n", "caf\u{E9}", "a.b"]
        for name in bad {
            XCTAssertEqual(check(name, in: skills(name)), .refused(.invalidName), "name: \(name.debugDescription)")
        }
    }

    func testTheLongestAllowedNameIsAccepted() {
        let longest = "a" + String(repeating: "b", count: 63)
        let tooLong = longest + "c"
        XCTAssertEqual(check(longest, in: skills(longest)), .send("/\(longest)"))
        XCTAssertEqual(check(tooLong, in: skills(tooLong)), .refused(.invalidName))
    }

    func testDashesAndUnderscoresAreAllowedAfterTheFirstCharacter() {
        XCTAssertEqual(check("code-review_2", in: skills("code-review_2")), .send("/code-review_2"))
    }

    // A missing profile

    func testNothingIsSentBeforeTheProfileArrives() {
        XCTAssertEqual(
            SkillActionChecker.check(skill: "commit", args: "x", availableSkills: nil),
            .refused(.profileNotLoaded)
        )
    }

    func testAnEmptySkillListRefusesEverything() {
        XCTAssertEqual(
            SkillActionChecker.check(skill: "commit", args: nil, availableSkills: []),
            .refused(.profileNotLoaded)
        )
    }

    // Long and multi-line arguments

    func testLineBreaksAndRepeatedSpacesBecomeSingleSpaces() {
        XCTAssertEqual(check("commit", "  fix\n\nthe   login\r\n\tbug \n"), .send("/commit fix the login bug"))
    }

    func testArgumentsAreCutToFiveHundredCharacters() {
        let long = String(repeating: "a", count: 600)
        XCTAssertEqual(check("commit", long), .send("/commit " + String(repeating: "a", count: 500)))
    }

    func testFiveHundredCharactersExactlyIsKept() {
        let exact = String(repeating: "a", count: 500)
        XCTAssertEqual(check("commit", exact), .send("/commit " + exact))
    }

    func testTheCutHappensAfterTheWhitespaceIsCollapsed() {
        // 400 + 300 line breaks + 200 = 900 raw characters, but only 601 once the breaks collapse to one space.
        let text = String(repeating: "a", count: 400) + String(repeating: "\n", count: 300) + String(repeating: "b", count: 200)
        let expected = String(repeating: "a", count: 400) + " " + String(repeating: "b", count: 99)
        XCTAssertEqual(check("commit", text), .send("/commit " + expected))
    }

    // What a notice can say

    func testEveryRefusalHasWordsForTheScreen() {
        XCTAssertFalse(SkillActionChecker.Refusal.profileNotLoaded.message.isEmpty)
        XCTAssertFalse(SkillActionChecker.Refusal.invalidName.message.isEmpty)
        XCTAssertEqual(SkillActionChecker.Refusal.unknownSkill("deploy").message, "The agent has no skill called deploy.")
    }
}
