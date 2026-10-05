import Foundation

/// The prompt Sidekick appends to Claude Code's own. Answer first, a few notes at most, never an essay.
public let SidekickSystemPrompt = """
You are Sidekick, a small quick-answer panel on the user's Mac. They opened it for one fast question or lookup, \
not a work session. Treat every message that way:

1. Give the answer first, in the first line. One to three short sentences, or a short list when the answer is a list.
2. Then, only when it really helps, add a short "Worth knowing" part: at most three bullets, one line each.
3. No preamble, no restating the question, no headings, no closing offers or questions. No essays. Stop when the answer is done.
4. When you need a fact, look it up (files, web, connectors) quickly and say where it came from in a few words.
5. Do not change files or send anything unless they clearly ask for that in this message.
6. The panel is narrow. Prefer short lines. Use code blocks only for commands or code.
"""

/// What one Sidekick conversation needs to start `claude`. Plain values so checks can build one.
public struct ClaudeConfig: Equatable, Sendable {
    public var executable: URL
    public var workingDirectory: URL
    /// Empty means Claude Code's own default model from the user's settings.
    public var model: String
    /// Empty means the user's default effort.
    public var effort: String
    public var systemPrompt: String
    public var environment: [String: String]

    public init(executable: URL, workingDirectory: URL, model: String = "", effort: String = "low",
                systemPrompt: String = SidekickSystemPrompt, environment: [String: String] = [:]) {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.model = model
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.environment = environment
    }

    /// Same user-facing settings (claude, folder, model, effort, prompt). The environment is left out:
    /// it changes once when the login shell loads, and that alone is no reason to end a session.
    public func sameSettings(as other: ClaudeConfig) -> Bool {
        executable == other.executable && workingDirectory == other.workingDirectory && model == other.model
            && effort == other.effort && systemPrompt == other.systemPrompt
    }

    /// One long-lived print session: messages go in on stdin as stream-json, events come out the same way.
    /// Nothing is saved to disk, so the conversation is gone when the process ends.
    public var arguments: [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--no-session-persistence",
            "--append-system-prompt", systemPrompt,
        ]
        if !model.isEmpty { args += ["--model", model] }
        if !effort.isEmpty { args += ["--effort", effort] }
        return args
    }

    /// The stdin line for one user message.
    public static func userMessage(_ text: String) -> Data {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// The stdin line that stops the current turn but keeps the session.
    public static func interruptRequest(id: String) -> Data {
        let object: [String: Any] = ["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]]
        var data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// Finds the `claude` executable. Apps started from Finder or at login get a bare PATH, so look in
/// the usual install places first, then in the login shell's PATH.
public enum ClaudeLocator {
    public static func find(environment: [String: String], home: String = NSHomeDirectory(),
                            fileManager: FileManager = .default) -> URL? {
        if let override = environment["SIDEKICK_CLAUDE_PATH"], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/claude")
        }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
}
