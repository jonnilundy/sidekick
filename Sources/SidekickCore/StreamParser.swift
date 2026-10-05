import Foundation

/// One thing the panel cares about from `claude -p --output-format stream-json`.
public enum StreamEvent: Equatable, Sendable {
    /// The process is up and talking (any `system` line). Repeats; take the first one.
    case ready
    /// Text for the answer, in order. Text after a tool call starts a new paragraph.
    case text(String)
    /// A tool started. The name is the raw tool name (WebSearch, Read, mcp__x__y).
    case tool(name: String, detail: String?)
    /// The model that answers this turn, from `message_start` (for example claude-sonnet-5-5).
    case model(String)
    /// The turn ended. `text` is the final answer text from the result line.
    case done(isError: Bool, text: String?)
}

/// Turns stream-json bytes into `StreamEvent`s. Feed it chunks as they arrive; it keeps partial lines.
/// Only top-level messages count: anything with a `parent_tool_use_id` comes from a subagent.
public struct StreamParser: Sendable {
    private var buffer = Data()
    /// True once a text block has produced text in this turn, so the next text block gets a paragraph break.
    private var hadText = false
    /// True when a tool ran after the last text, so the next text starts a new paragraph.
    private var toolSinceText = false
    /// Tool input arrives as JSON deltas. Kept per block index until the block stops.
    private var toolInputs: [Int: (name: String, json: String)] = [:]

    public init() {}

    public mutating func feed(_ data: Data) -> [StreamEvent] {
        buffer.append(data)
        var events: [StreamEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            events += parse(line: Data(line))
        }
        return events
    }

    public mutating func parse(line: Data) -> [StreamEvent] {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }
        if let parent = object["parent_tool_use_id"], !(parent is NSNull) { return [] }

        switch type {
        case "system":
            // Hooks report before the first message, init after it. Either one means the process is up.
            return [.ready]
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            return parse(streamEvent: event)
        case "result":
            hadText = false
            toolSinceText = false
            toolInputs = [:]
            let isError = (object["is_error"] as? Bool) ?? (object["subtype"] as? String != "success")
            return [.done(isError: isError, text: object["result"] as? String)]
        default:
            return []
        }
    }

    private mutating func parse(streamEvent event: [String: Any]) -> [StreamEvent] {
        let index = event["index"] as? Int ?? -1
        switch event["type"] as? String {
        case "message_start":
            guard let model = (event["message"] as? [String: Any])?["model"] as? String, !model.isEmpty else { return [] }
            return [.model(model)]
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any] else { return [] }
            switch block["type"] as? String {
            case "tool_use", "server_tool_use", "mcp_tool_use":
                toolInputs[index] = (block["name"] as? String ?? "tool", "")
                toolSinceText = true
            default: break
            }
            return []
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                defer { hadText = true; toolSinceText = false }
                return [.text(hadText && toolSinceText ? "\n\n" + text : text)]
            case "input_json_delta":
                if let partial = delta["partial_json"] as? String, toolInputs[index] != nil {
                    toolInputs[index]!.json += partial
                }
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard let tool = toolInputs.removeValue(forKey: index) else { return [] }
            return [.tool(name: tool.name, detail: ToolLabel.detail(name: tool.name, inputJSON: tool.json))]
        default:
            return []
        }
    }
}

/// Short, human labels for tool calls ("Searching the web", "Reading Mind.md").
public enum ToolLabel {
    /// The most telling input field for a tool, shortened. Nil when nothing useful is there.
    public static func detail(name: String, inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["query", "file_path", "path", "pattern", "url", "description", "command", "skill"] {
            if let value = input[key] as? String, !value.isEmpty {
                let short = key.hasSuffix("path") ? (value as NSString).lastPathComponent : value
                return short.count > 60 ? String(short.prefix(59)) + "…" : short
            }
        }
        return nil
    }

    public static func label(name: String, detail: String?) -> String {
        let verb: String
        switch name {
        case "WebSearch", "web_search": verb = "Searching the web"
        case "WebFetch", "web_fetch": verb = "Reading a page"
        case "Read": verb = "Reading"
        case "Grep", "Glob": verb = "Searching files"
        case "Bash": verb = "Running a command"
        case "Edit", "Write", "NotebookEdit": verb = "Editing"
        case "Task", "Agent": verb = "Asking a helper"
        case "Skill": verb = "Using a skill"
        case "ToolSearch": verb = "Finding a tool"
        default:
            if name.hasPrefix("mcp__") {
                let parts = name.split(separator: "_", omittingEmptySubsequences: true)
                verb = "Using " + (parts.count > 1 ? String(parts[1]) : "a connector")
            } else {
                verb = "Using \(name)"
            }
        }
        guard let detail, !detail.isEmpty else { return verb }
        if name == "Bash" || name == "ToolSearch" { return verb }
        return "\(verb): \(detail)"
    }
}

/// Friendly names for model ids: claude-sonnet-5-5 is "Sonnet 5.5", claude-haiku-4-5-20251001 is "Haiku 4.5".
public enum ModelName {
    public static func display(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude" else { return id }
        let family = parts[1].prefix(1).uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && Int($0) != nil }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }
}
