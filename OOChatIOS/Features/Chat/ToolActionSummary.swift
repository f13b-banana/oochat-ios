import ConnectOnionKit

enum ToolActionSummary {
    static func completed(toolName: String, arguments: [String: JSONValue]) -> String {
        summary(
            toolName: toolName,
            arguments: arguments,
            commandPrefix: "Ran",
            writePrefix: "Wrote",
            editPrefix: "Updated",
            searchPrefix: "Searched",
            listPrefix: "Listed"
        )
    }

    static func requested(toolName: String, arguments: [String: JSONValue]) -> String {
        summary(
            toolName: toolName,
            arguments: arguments,
            commandPrefix: "Run",
            writePrefix: "Write",
            editPrefix: "Update",
            searchPrefix: "Search",
            listPrefix: "List"
        )
    }

    static func argumentsDescription(_ arguments: [String: JSONValue]) -> String {
        arguments
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \(displayValue($0.value))" }
            .joined(separator: "\n")
    }

    private static func summary(
        toolName: String,
        arguments: [String: JSONValue],
        commandPrefix: String,
        writePrefix: String,
        editPrefix: String,
        searchPrefix: String,
        listPrefix: String
    ) -> String {
        if let command = stringArgument(named: "cmd", in: arguments)
            ?? stringArgument(named: "command", in: arguments)
            ?? stringArgument(named: "script", in: arguments) {
            return "\(commandPrefix) \(command)"
        }

        let normalizedName = toolName.lowercased()
        let path = stringArgument(named: "path", in: arguments)
            ?? stringArgument(named: "file", in: arguments)
            ?? stringArgument(named: "url", in: arguments)

        if normalizedName.contains("read"), let path {
            return "Read \(path)"
        }
        if normalizedName.contains("write"), let path {
            return "\(writePrefix) \(path)"
        }
        if normalizedName.contains("edit") || normalizedName.contains("patch"), let path {
            return "\(editPrefix) \(path)"
        }
        if normalizedName.contains("search"), let query = stringArgument(named: "query", in: arguments) {
            return "\(searchPrefix) \(query)"
        }
        if normalizedName.contains("list") || normalizedName.contains("glob"), let path {
            return "\(listPrefix) \(path)"
        }

        let details = argumentsDescription(arguments)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ": ", with: "=")
        if details.isEmpty {
            return toolName.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "\(commandPrefix) \(toolName) \(details)"
    }

    private static func stringArgument(named name: String, in arguments: [String: JSONValue]) -> String? {
        arguments[name]?.stringValue
    }

    private static func displayValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let value):
            return value
        case .number(let value):
            // Tool arguments come from the hosted agent and may contain numbers
            // outside the range representable by Int. Keep rendering total so a
            // malicious or simply large JSON number cannot trap the app.
            if value.rounded() == value, let integer = Int64(exactly: value) {
                return String(integer)
            }
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return "[\(values.count) items]"
        case .object(let values):
            return "[\(values.count) fields]"
        case .null:
            return "null"
        }
    }
}
