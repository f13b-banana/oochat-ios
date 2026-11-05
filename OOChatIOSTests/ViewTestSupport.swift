import SwiftUI
import UIKit
import ConnectOnionKit
import XCTest
@testable import OOChatIOS

@MainActor
enum ViewHost {
    private static let accessibilityEnabled: Bool = {
        guard
            let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
            let symbol = dlsym(handle, "_AXSSetAutomationEnabled")
        else {
            return false
        }
        typealias SetAutomationEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetAutomationEnabled.self)(1)
        return true
    }()

    static func host(_ view: some View, size: CGSize = CGSize(width: 390, height: 844)) -> UIWindow {
        precondition(accessibilityEnabled, "Failed to enable accessibility automation in simulator")
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        pump()
        return window
    }

    static func pump(_ interval: TimeInterval = 0.08) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    static func accessibilityElements(in window: UIWindow) -> [NSObject] {
        var found: [NSObject] = []
        var queue: [NSObject] = [window]
        var visited = Set<ObjectIdentifier>()

        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard visited.insert(ObjectIdentifier(node)).inserted else {
                continue
            }
            found.append(node)

            if let elements = node.accessibilityElements as? [NSObject] {
                queue.append(contentsOf: elements)
            }
            let count = node.accessibilityElementCount()
            if count != NSNotFound, count > 0, count < 500 {
                for index in 0..<count {
                    if let element = node.accessibilityElement(at: index) as? NSObject {
                        queue.append(element)
                    }
                }
            }
            if let view = node as? UIView {
                queue.append(contentsOf: view.subviews)
            }
        }

        return found
    }

    static func element(
        identifier: String? = nil,
        labelContains: String? = nil,
        valueContains: String? = nil,
        in window: UIWindow
    ) -> NSObject? {
        accessibilityElements(in: window).first { element in
            if let identifier {
                guard accessibilityIdentifier(of: element) == identifier else {
                    return false
                }
            }
            if let labelContains {
                guard element.accessibilityLabel?.contains(labelContains) == true else {
                    return false
                }
            }
            if let valueContains {
                guard element.accessibilityValue?.contains(valueContains) == true else {
                    return false
                }
            }
            return true
        }
    }

    static func waitForElement(
        identifier: String? = nil,
        labelContains: String? = nil,
        valueContains: String? = nil,
        in window: UIWindow,
        timeout: TimeInterval = 1.0
    ) -> NSObject? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let match = element(
                identifier: identifier,
                labelContains: labelContains,
                valueContains: valueContains,
                in: window
            ) {
                return match
            }
            pump(0.05)
        } while Date() < deadline

        return element(
            identifier: identifier,
            labelContains: labelContains,
            valueContains: valueContains,
            in: window
        )
    }

    @discardableResult
    static func activate(
        identifier: String? = nil,
        labelContains: String? = nil,
        in window: UIWindow
    ) -> Bool {
        guard let match = element(identifier: identifier, labelContains: labelContains, in: window) else {
            return false
        }
        let activated = match.accessibilityActivate()
        pump()
        return activated
    }

    @discardableResult
    static func enterText(_ text: String, intoTextInput labelContains: String, in window: UIWindow) -> Bool {
        let inputs = textInputs(in: window)
        let input = inputs.first(where: { textInputLabel($0).contains(labelContains) })
            ?? (inputs.count == 1 ? inputs[0] : nil)
        guard let input else {
            return false
        }

        input.becomeFirstResponder()
        if let field = input as? UITextField {
            field.text = ""
            field.sendActions(for: .editingChanged)
            field.insertText(text)
            field.sendActions(for: .editingChanged)
        } else if let textView = input as? UITextView {
            textView.text = ""
            textView.delegate?.textViewDidChange?(textView)
            textView.insertText(text)
            textView.delegate?.textViewDidChange?(textView)
            NotificationCenter.default.post(name: UITextView.textDidChangeNotification, object: textView)
        }
        pump(0.1)
        return true
    }

    @discardableResult
    static func activateButton(labelContains: String, in window: UIWindow) -> Bool {
        guard let match = accessibilityElements(in: window).first(where: { element in
            element.accessibilityLabel?.contains(labelContains) == true &&
                element.accessibilityTraits.contains(.button)
        }) else {
            return false
        }
        let activated = match.accessibilityActivate()
        pump()
        return activated
    }

    private static func accessibilityIdentifier(of element: NSObject) -> String? {
        if let identification = element as? UIAccessibilityIdentification,
           let identifier = identification.accessibilityIdentifier {
            return identifier
        }
        guard element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else {
            return nil
        }
        return element.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func textInputs(in window: UIWindow) -> [UIView] {
        allViews(in: window).filter { $0 is UITextField || $0 is UITextView }
    }

    private static func allViews(in root: UIView) -> [UIView] {
        var found: [UIView] = []
        var queue: [UIView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            found.append(view)
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    private static func textInputLabel(_ view: UIView) -> String {
        if let field = view as? UITextField {
            return [field.accessibilityLabel, field.placeholder]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        if let textView = view as? UITextView {
            return [textView.accessibilityLabel, textView.accessibilityValue]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return view.accessibilityLabel ?? ""
    }
}

@MainActor
final class InMemoryConversationRepository: ConversationRepository {
    private var snapshot: ChatSnapshot

    init(snapshot: ChatSnapshot = .empty) {
        self.snapshot = snapshot
    }

    func load() -> ChatSnapshot {
        snapshot
    }

    func upsertConversation(_ conversation: Conversation) {
        if let index = snapshot.conversations.firstIndex(where: { $0.id == conversation.id }) {
            snapshot.conversations[index] = conversation
        } else {
            snapshot.conversations.append(conversation)
        }
    }

    func deleteConversation(id: String) {
        snapshot.conversations.removeAll { $0.id == id }
    }

    func upsertAgent(_ agent: SavedAgent) {
        if let index = snapshot.agents.firstIndex(where: { $0.id == agent.id }) {
            snapshot.agents[index] = agent
        } else {
            snapshot.agents.append(agent)
        }
    }

    func deleteAgent(id: String) {
        snapshot.agents.removeAll { $0.id == id }
    }

    func saveActive(agentID: String?, conversationID: String?) {
        snapshot.activeAgentID = agentID
        snapshot.activeConversationID = conversationID
    }

    func search(_ query: String) -> [Conversation] {
        snapshot.conversations.filter { $0.title.localizedStandardContains(query) }
    }
}

@MainActor
final class MockSpeechTranscriber: SpeechTranscribing {
    typealias ResultHandler = (_ transcript: String, _ isFinal: Bool) -> Void
    typealias FailureHandler = (Error) -> Void

    var authorizationError: Error?
    var startError: Error?
    private(set) var authorizationRequestCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var resultHandlers: [ResultHandler] = []
    private var failureHandlers: [FailureHandler] = []

    func requestAuthorization() async throws {
        authorizationRequestCount += 1
        if let authorizationError {
            throw authorizationError
        }
    }

    func start(
        resultHandler: @escaping ResultHandler,
        failureHandler: @escaping FailureHandler
    ) throws {
        if let startError {
            throw startError
        }
        startCount += 1
        resultHandlers.append(resultHandler)
        failureHandlers.append(failureHandler)
    }

    func stop() {
        stopCount += 1
    }

    func emit(
        _ transcript: String,
        isFinal: Bool = false,
        session index: Int? = nil
    ) {
        guard let handler = handler(in: resultHandlers, at: index) else {
            XCTFail("No speech result handler is available")
            return
        }
        handler(transcript, isFinal)
    }

    func fail(_ error: Error, session index: Int? = nil) {
        guard let handler = handler(in: failureHandlers, at: index) else {
            XCTFail("No speech failure handler is available")
            return
        }
        handler(error)
    }

    private func handler<T>(in handlers: [T], at index: Int?) -> T? {
        if let index {
            return handlers.indices.contains(index) ? handlers[index] : nil
        }
        return handlers.last
    }
}

enum ViewFixtures {
    static func agent(
        id: String = "agent1",
        address: String = "0x" + String(repeating: "ab", count: 32)
    ) -> SavedAgent {
        SavedAgent(id: id, address: address, name: "Test Agent")
    }

    static func conversation(
        id: String = "con1",
        agent: SavedAgent,
        messages: [ChatMessage] = []
    ) -> Conversation {
        Conversation(
            id: id,
            title: "Test Chat",
            agentID: agent.id,
            agentAddress: agent.address,
            mode: .safe,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            messages: messages,
            serverSession: nil
        )
    }

    static func toolMessage(
        id: String = UUID().uuidString,
        name: String? = "read_file",
        state: ToolCallState? = .completed,
        content: String = "",
        arguments: [String: JSONValue]? = ["path": .string("/tmp/example.txt")]
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            role: .tool,
            content: content,
            toolName: name,
            toolArguments: arguments,
            toolState: state
        )
    }

    @MainActor
    static func chatViewModel(
        transport: MockAgentTransport = MockAgentTransport(),
        messages: [ChatMessage] = [],
        voiceInputController: VoiceInputController? = nil
    ) -> ChatViewModel {
        let agent = agent()
        let conversation = conversation(agent: agent, messages: messages)
        let repo = InMemoryConversationRepository(
            snapshot: ChatSnapshot(
                agents: [agent],
                conversations: [conversation],
                activeAgentID: agent.id,
                activeConversationID: conversation.id
            )
        )
        let monitor = MockNetworkMonitor()
        return ChatViewModel(
            store: repo,
            client: transport,
            networkMonitor: monitor,
            voiceInputController: voiceInputController
        )
    }
}
