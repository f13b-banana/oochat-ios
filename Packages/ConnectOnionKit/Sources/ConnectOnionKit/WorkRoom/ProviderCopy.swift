import Foundation

/// The only Provider copy a Work Room may show. Everything else a host sends in these fields is
/// dropped, so drift degrades to blank text, never to unsafe text.
///
/// Source: ConnectOnion Core at commit 971c799 (`connectonion/core/provider_events.py` and
/// `connectonion/cli/co_ai/claude_station.py`). The lists follow Core rather than the web SDK,
/// which is older and drops every Claude Station title and status. Refresh this file when Core
/// adds copy, and update `coreCommit` with it.
public enum ProviderCopy {
    public static let coreCommit = "971c799"

    /// provider_events.provider_task_title, plus the Claude Station session title.
    static let taskTitles: Set<String> = [
        "Complete the requested task",
        "Build and verify the requested C program",
        "Implement and verify the requested change",
        "Review and test the requested change",
        "Inspect the requested workspace",
        "Claude Code session"
    ]

    /// One list for currentSummary, resultSummary and errorSummary: provider_status_summary,
    /// provider_terminal_summary and the Claude Station summaries.
    static let summaries: Set<String> = [
        "Working in the selected workspace",
        "Waiting for your decision",
        "The provider completed its run",
        "The provider reported an error",
        "The provider stopped",
        "The provider ended its run",
        "Completed the provider run after the recorded compilation and test checks",
        "Completed the provider run after the recorded test checks",
        "Completed the provider run after the recorded compilation check",
        "Completed the provider run after the recorded program check",
        "Running in the terminal",
        "Claude Code is working",
        "Ready for a browser message",
        "Session ready in the terminal"
    ]

    /// provider_events._activity_copy and _command_activity_copy: each title with the summaries
    /// Core pairs it with (running, completed, failed). Only these exact pairs are shown.
    static let activitySummaries: [String: Set<String>] = [
        "Update workspace files": [
            "Preparing workspace file changes", "Workspace files updated", "Workspace file change failed"
        ],
        "Inspect the workspace": [
            "Inspecting workspace context", "Workspace inspection completed", "Workspace inspection failed",
            "Completed the workspace inspection", "The workspace inspection failed"
        ],
        "Search for context": [
            "Searching for relevant context", "Context search completed", "Context search failed"
        ],
        "Use a provider tool": [
            "Using a provider tool", "Provider tool completed", "Provider tool failed"
        ],
        "Compile the requested C11 program": [
            "Compiling the requested C11 program", "Compiled the requested C11 program",
            "Could not compile the requested C11 program"
        ],
        "Compile the requested C program": [
            "Compiling the requested C program", "Compiled the requested C program",
            "Could not compile the requested C program"
        ],
        "Compile and run the requested tests": [
            "Compiling and running the requested tests", "Completed the requested compilation and tests",
            "The requested compilation or tests failed"
        ],
        "Run the requested tests": [
            "Running the requested tests", "Completed the requested tests", "The requested tests failed"
        ],
        "Run the requested program": [
            "Running the requested program", "Completed the requested program run", "The requested program run failed"
        ],
        "Run a workspace command": [
            "Running a workspace command", "Completed a workspace command", "A workspace command failed"
        ]
    ]

    /// The trimmed title if it is allowed, otherwise nil.
    static func taskTitle(_ value: String?) -> String? {
        allowed(value, in: taskTitles)
    }

    /// The trimmed summary if it is allowed, otherwise nil.
    static func summary(_ value: String?) -> String? {
        allowed(value, in: summaries)
    }

    /// The trimmed pair if Core sends exactly this title with this summary, otherwise nil.
    static func activity(title: String?, summary: String?) -> (title: String, summary: String)? {
        guard let title = trimmed(title),
              let summary = trimmed(summary),
              activitySummaries[title]?.contains(summary) == true else {
            return nil
        }
        return (title, summary)
    }

    private static func allowed(_ value: String?, in list: Set<String>) -> String? {
        trimmed(value).flatMap { list.contains($0) ? $0 : nil }
    }

    private static func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
