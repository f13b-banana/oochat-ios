import XCTest
@testable import ConnectOnionKit

final class StarterSkillsTests: XCTestCase {
    private let skills = ["commit", "dashboard", "review-pr", "ship-feature"].map { OIPAgentSkill(name: $0) }

    func testWithoutADashboardTheProfileOrderIsKept() {
        XCTAssertEqual(StarterSkills.ordered(skills, dashboard: nil).map(\.name), skills.map(\.name))
        XCTAssertEqual(
            StarterSkills.ordered(skills, dashboard: .tooLarge(bytes: 1)).map(\.name),
            skills.map(\.name)
        )
    }

    func testSkillsTheDashboardUsesComeFirstInPageOrder() {
        let html = """
        <button data-ochat-skill="ship-feature">Ship</button>
        <button data-ochat-skill='review-pr' data-ochat-args="12">Review</button>
        <button data-ochat-skill="ship-feature">Ship again</button>
        """
        XCTAssertEqual(
            StarterSkills.ordered(skills, dashboard: OIPDashboard(html: html)).map(\.name),
            ["ship-feature", "review-pr", "commit", "dashboard"]
        )
    }

    func testThePageCannotAddASkillTheAgentDoesNotHave() {
        let html = #"<button data-ochat-skill="wipe-disk">x</button><a data-ochat-skill="commit">c</a>"#
        XCTAssertEqual(
            StarterSkills.ordered(skills, dashboard: OIPDashboard(html: html)).map(\.name),
            ["commit", "dashboard", "review-pr", "ship-feature"]
        )
    }
}
