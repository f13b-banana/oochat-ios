import Foundation
import Testing
import ConnectOnionKit

private let upper = "0X" + String(repeating: "AB", count: 32)
private let lower = "0x" + String(repeating: "ab", count: 32)
private let other = "0x" + String(repeating: "cd", count: 32)

private struct Agent: Equatable {
    var address: String?
    var name: String
}

@Test func anAddressIsMatchedLowerCasedAndOnlyIfItIsA0xAddress() {
    #expect(AgentAddress.normalized(" \(upper) ") == nil)
    #expect(AgentAddress.normalized(upper) == lower)
    #expect(AgentAddress.normalized("https://agent.example.com") == nil)
    #expect(AgentAddress.normalized("0x" + String(repeating: "ab", count: 31)) == nil)
    #expect(DeviceLinkAgentName(address: upper, name: "Bot") == DeviceLinkAgentName(address: lower, name: "Bot"))
    #expect(DeviceLinkAgentName(address: upper, name: "Bot")?.address == lower)
    #expect(DeviceLinkAgentName(address: "https://agent.example.com", name: "Bot") == nil)
}

@Test func anEntryCarriesOnlyItsAddressAndAgentName() throws {
    let entry = try #require(DeviceLinkAgentName(address: upper, name: "Bot"))
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: String]

    #expect(object == ["address": lower, "name": "Bot"])
}

@Test func theReceiverRenamesItsMatchAddsWhatIsMissingAndLeavesTheRest() {
    let agents = [
        Agent(address: upper, name: "Mine"),
        Agent(address: nil, name: "Direct URL"),
        Agent(address: "0x" + String(repeating: "ef", count: 32), name: "Only here"),
        Agent(address: other, name: "Same")
    ]
    let list = [(lower, "Theirs"), (other, "Same"), ("0x" + String(repeating: "12", count: 32), "New")]
        .compactMap { DeviceLinkAgentName(address: $0, name: $1) }

    let plan = DeviceLinkAgentName.apply(list, to: agents, address: \.address)

    #expect(plan.renames.map(\.index) == [0, 3])
    #expect(plan.renames.map(\.name) == ["Theirs", "Same"])
    #expect(plan.additions == [list[2]])
}

@Test func anAddressTheListNamesTwiceIsAddedOnce() {
    let list = [(lower, "First"), (upper, "Second")].compactMap { DeviceLinkAgentName(address: $0, name: $1) }

    let plan = DeviceLinkAgentName.apply(list, to: [Agent](), address: \.address)

    #expect(plan.additions.map(\.name) == ["First"])
}

@Test func duplicatesMergeIntoTheFirstAgentWithThatAddressInAnyCase() {
    let first = Agent(address: lower, name: "First")
    let second = Agent(address: other, name: "Alone")
    let third = Agent(address: upper, name: "Later")
    let fourth = Agent(address: nil, name: "Unknown")
    let fifth = Agent(address: nil, name: "Unknown too")

    let groups = DeviceLinkAgentName.duplicates(in: [first, second, third, fourth, fifth], address: \.address)

    #expect(groups.count == 1)
    #expect(groups.first?.keep == first)
    #expect(groups.first?.extras == [third])
}
