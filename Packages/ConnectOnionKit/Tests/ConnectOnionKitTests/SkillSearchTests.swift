//
//  SkillSearchTests.swift
//  ConnectOnionKit
//
//  Created by Kevin Chin on 31/10/2026.
//

import XCTest
@testable import ConnectOnionKit

final class SkillSearchTests: XCTestCase {
    private let skills = ["co-browser", "commit", "my-notes", "review", "scoreboard"]

    func testEmptyQueryReturnsEveryNameInOriginalOrder() {
        XCTAssertEqual(SkillSearch.rank(skills, query: ""), skills)
    }

    func testPrefixMatchesComeFirst() {
        // "co" starts co-browser and commit. It is inside scoreboard (substring).
        XCTAssertEqual(
            SkillSearch.rank(["scoreboard", "co-browser", "commit"], query: "co"),
            ["co-browser", "commit", "scoreboard"]
        )
    }

    func testSubstringMatchesComeBeforeLettersInOrderMatches() {
        // "note": substring of my-notes. Letters n,o,t,e also appear in order in "n-o-t-ebook".
        let names = ["n-o-t-ebook", "my-notes"]
        XCTAssertEqual(SkillSearch.rank(names, query: "note"), ["my-notes", "n-o-t-ebook"])
    }

    func testLettersInOrderMatchesWhenNothingIsContiguous() {
        // c, b, r appear in that order in co-browser and in scoreboard, and nowhere else.
        XCTAssertEqual(SkillSearch.rank(skills, query: "cbr"), ["co-browser", "scoreboard"])
    }

    func testLettersOutOfOrderDoNotMatch() {
        XCTAssertEqual(SkillSearch.rank(skills, query: "rbc"), [])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertEqual(SkillSearch.rank(skills, query: "zzz"), [])
    }

    func testQueryLongerThanNameDoesNotMatchThatName() {
        XCTAssertEqual(SkillSearch.rank(["go"], query: "gone"), [])
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(SkillSearch.rank(["Review", "release"], query: "RE"), ["Review", "release"])
        XCTAssertEqual(SkillSearch.rank(["review"], query: "REV"), ["review"])
    }

    func testMatchingIgnoresDiacritics() {
        XCTAssertEqual(SkillSearch.rank(["résumé", "review"], query: "resu"), ["résumé"])
    }

    func testOriginalOrderIsKeptInsideEachGroup() {
        XCTAssertEqual(
            SkillSearch.rank(["review", "release", "rebase"], query: "re"),
            ["review", "release", "rebase"]
        )
    }

    func testEachNameAppearsOnceEvenWhenItMatchesEveryRule() {
        // "aa" is a prefix, a substring and letters in order of "aab".
        XCTAssertEqual(SkillSearch.rank(["aab"], query: "aa"), ["aab"])
    }

    func testDuplicateNamesAreNotMerged() {
        XCTAssertEqual(SkillSearch.rank(["deploy", "deploy"], query: "dep"), ["deploy", "deploy"])
    }

    func testEmptyInputGivesEmptyOutput() {
        XCTAssertEqual(SkillSearch.rank([], query: "a"), [])
        XCTAssertEqual(SkillSearch.rank([], query: ""), [])
    }
}
