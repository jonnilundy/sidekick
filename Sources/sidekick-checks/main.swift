// Plain checks for SidekickCore. No windows, no network, no real claude: the session checks run
// scripts/fake-claude. Prints one line per failure and a summary line last.
import Foundation
import SidekickCore

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passed = 0

func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
    } else {
        failures += 1
        let extra = detail()
        print("FAIL \(name)\(extra.isEmpty ? "" : ": \(extra)")")
    }
}

/// Spins the main run loop until `done` is true or `timeout` passes.
@MainActor
func wait(_ timeout: TimeInterval = 5, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return done()
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fake = root.appendingPathComponent("scripts/fake-claude")

// MARK: Stream parser

do {
    var parser = StreamParser()
    let lines = """
    {"type":"system","subtype":"hook_started","session_id":"s"}
    {"type":"system","subtype":"init","cwd":"/x","session_id":"s"}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"SUB"}},"parent_tool_use_id":"toolu_9"}
    {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","name":"Read","input":{}}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"file_path\\": \\"/a/b/Mind.md\\"}"}},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_stop","index":1},"parent_tool_use_id":null}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"World"}},"parent_tool_use_id":null}
    {"duration_api_ms":3435,"type":"result","subtype":"success","is_error":false,"result":"Hello\\n\\nWorld","session_id":"s"}

    """
    // Feed in awkward chunks to prove partial lines are kept.
    let data = Data(lines.utf8)
    var events: [StreamEvent] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + 37, data.count)
        events += parser.feed(data[offset..<end])
        offset = end
    }
    let texts = events.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    check(texts == "Hello\n\nWorld", "parser joins text and breaks after a tool", texts.debugDescription)
    check(!texts.contains("SUB"), "parser drops subagent text")
    check(events.contains(.tool(name: "Read", detail: "Mind.md")), "parser reports the tool with its file name", "\(events)")
    check(events.filter { $0 == .ready }.count == 2, "parser reports ready for system lines")
    check(events.last == .done(isError: false, text: "Hello\n\nWorld"), "parser reads the result line", "\(String(describing: events.last))")

    var p2 = StreamParser()
    let interrupted = p2.feed(Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":null}"#.utf8 + [0x0A]))
    check(interrupted == [.done(isError: true, text: nil)], "parser reads an interrupted result")
    check(p2.feed(Data("not json\n{}\n".utf8)).isEmpty, "parser ignores junk lines")
}

check(ToolLabel.label(name: "WebSearch", detail: "swift 6") == "Searching the web: swift 6", "tool label for web search")
check(ToolLabel.label(name: "Bash", detail: "rm -rf x") == "Running a command", "tool label hides commands")
check(ToolLabel.label(name: "mcp__claude_ai_Linear__list_issues", detail: nil) == "Using claude", "tool label for MCP", ToolLabel.label(name: "mcp__claude_ai_Linear__list_issues", detail: nil))

// MARK: Command

do {
    let config = ClaudeConfig(executable: URL(fileURLWithPath: "/bin/claude"), workingDirectory: URL(fileURLWithPath: "/tmp"), model: "sonnet", effort: "low")
    let args = config.arguments
    check(args.first == "-p", "args start with -p")
    check(args.contains("--no-session-persistence"), "args keep nothing on disk")
    check(args.contains("--include-partial-messages"), "args stream partial text")
    check(zip(args, args.dropFirst()).contains { $0 == "--model" && $1 == "sonnet" }, "args pass the model")
    check(zip(args, args.dropFirst()).contains { $0 == "--effort" && $1 == "low" }, "args pass the effort")
    check(!ClaudeConfig(executable: config.executable, workingDirectory: config.workingDirectory, model: "", effort: "").arguments.contains("--model"), "empty model uses the user's default")
    check(zip(args, args.dropFirst()).contains { $0 == "--append-system-prompt" && $1.contains("answer first") }, "args append the quick-answer prompt")
    let message = String(decoding: ClaudeConfig.userMessage("hi \"there\"\nnext"), as: UTF8.self)
    check(message.hasSuffix("\n") && message.filter { $0 == "\n" }.count == 1, "user message is one line")
    let decoded = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
    check(((decoded?["message"] as? [String: Any])?["content"] as? String) == "hi \"there\"\nnext", "user message round trips")
}

// MARK: Locator and environment

do {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-checks-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let bin = tmp.appendingPathComponent("bin/claude")
    FileManager.default.createFile(atPath: bin.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    check(ClaudeLocator.find(environment: ["PATH": tmp.appendingPathComponent("bin").path], home: tmp.path) == bin, "locator finds claude on PATH")
    check(ClaudeLocator.find(environment: ["PATH": "/nonexistent"], home: tmp.path) == nil || FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/claude") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/claude"), "locator returns nil when there is no claude")
    check(ClaudeLocator.find(environment: ["SIDEKICK_CLAUDE_PATH": bin.path, "PATH": ""], home: "/nowhere") == bin, "locator honors the override")
    try? FileManager.default.removeItem(at: tmp)

    var raw = Data("Last login: junk\nwelcome\n".utf8)
    raw.append(Data("__SIDEKICK_ENV_START__".utf8)); raw.append(0)
    raw.append(Data("PATH=/a:/b".utf8)); raw.append(0)
    raw.append(Data("TOKEN=x=y".utf8)); raw.append(0)
    raw.append(Data("SHLVL=2".utf8)); raw.append(0)
    let env = ShellEnvironment.parse(raw)
    check(env["PATH"] == "/a:/b" && env["TOKEN"] == "x=y" && env["SHLVL"] == nil, "shell env parses after the marker", "\(env)")
    let path = ShellEnvironment.withFallbackPath(["PATH": "/a"], home: "/h")["PATH"] ?? ""
    check(path.hasPrefix("/a:") && path.contains("/h/.local/bin") && path.contains("/opt/homebrew/bin"), "fallback PATH adds tool folders", path)
    let live = ShellEnvironment.load(timeout: 8)
    check(live["HOME"] != nil && (live["PATH"] ?? "").contains("/usr/bin") && ShellEnvironment.lastFallbackReason == nil,
          "login shell env loads", ShellEnvironment.lastFallbackReason ?? "")

    // A shell that never finishes, and one that leaves a job holding the pipe: both must return fast.
    let tmpShell = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-shell-\(getpid())")
    FileManager.default.createFile(atPath: tmpShell.path, contents: Data("#!/bin/sh\ntrap '' TERM\nsleep 30\n".utf8), attributes: [.posixPermissions: 0o755])
    var t0 = Date()
    let hung = ShellEnvironment.load(base: ["SHELL": tmpShell.path, "PATH": "/usr/bin"], timeout: 0.5)
    check(Date().timeIntervalSince(t0) < 2 && hung["PATH"]?.contains("/opt/homebrew/bin") == true && ShellEnvironment.lastFallbackReason != nil,
          "a hung shell falls back fast", ShellEnvironment.lastFallbackReason ?? "")
    FileManager.default.createFile(atPath: tmpShell.path, contents: Data("#!/bin/sh\n(sleep 30 &)\nprintf '%s\\0' __SIDEKICK_ENV_START__; printf 'FOO=bar\\0'\n".utf8), attributes: [.posixPermissions: 0o755])
    t0 = Date()
    let held = ShellEnvironment.load(base: ["SHELL": tmpShell.path], timeout: 3)
    check(Date().timeIntervalSince(t0) < 1.5 && held["FOO"] == "bar", "a background job holding the pipe does not block", "\(Date().timeIntervalSince(t0))s \(held["FOO"] ?? "nil")")
    try? FileManager.default.removeItem(at: tmpShell)
}

// MARK: Markdown

do {
    let blocks = Markdown.blocks("""
    The answer is **42**.

    Worth knowing:
    - one
    - two
      wrapped
    1. first
    2. second

    ```swift
    let x = 1
    ```
    | a | b |
    | --- | --- |
    # Big
    > quoted
    """)
    check(blocks.first == .paragraph("The answer is **42**."), "markdown paragraph", "\(blocks)")
    check(blocks.contains(.bullets(["one", "two wrapped"])), "markdown bullets with a wrapped line", "\(blocks)")
    check(blocks.contains(.numbered(start: 1, items: ["first", "second"])), "markdown numbered list", "\(blocks)")
    check(blocks.contains(.code(language: "swift", text: "let x = 1")), "markdown code block")
    check(blocks.contains(.table([["a", "b"]])), "markdown table drops the rule line", "\(blocks)")
    check(Markdown.blocks("| x | y |\n|:--|--:|\n| 1 | 2 |") == [.table([["x", "y"], ["1", "2"]])], "markdown table rows")
    check(blocks.contains(.heading(level: 1, text: "Big")), "markdown heading")
    check(blocks.last == .quote("quoted"), "markdown quote")
    check(Markdown.blocks("```\nopen fence") == [.code(language: "", text: "open fence")], "markdown keeps an unclosed fence while streaming")
    check(Markdown.blocks("#hashtag") == [.paragraph("#hashtag")], "markdown needs a space after #")
}

// MARK: Spring

do {
    var x = SpringValue(0, spring: .arrive)
    x.target = 100
    var peak = 0.0
    var frames = 0
    while !x.isSettled && frames < 600 { x.step(1.0 / 120); peak = max(peak, x.value); frames += 1 }
    check(x.value == 100, "arrive spring settles on target")
    check(peak > 100.5 && peak < 112, "arrive spring overshoots a little", "peak \(peak)")
    check(Double(frames) / 120 < 1.2, "arrive spring settles within 1.2 s", "\(Double(frames) / 120)")

    var y = SpringValue(0, spring: .leave)
    y.target = 100
    var over = 0.0
    for _ in 0..<240 { y.step(1.0 / 120); over = max(over, y.value - 100) }
    check(over <= 0.05, "leave spring does not overshoot", "\(over)")

    // Interrupt: reverse mid-flight. The value must not jump, and velocity carries over.
    var z = SpringValue(0, spring: .arrive)
    z.target = 100
    for _ in 0..<12 { z.step(1.0 / 120) }
    let before = z.value, velocity = z.velocity
    z.target = 0
    z.step(1.0 / 120)
    check(abs(z.value - before) < 5 && velocity > 0, "a reversed spring continues from where it was", "\(before) -> \(z.value)")

    var slow = SpringValue(0, spring: .grow)
    slow.target = 50
    slow.step(0.5)  // a very late frame must not explode
    check(slow.value.isFinite && abs(slow.value) < 200, "spring is stable on a late frame", "\(slow.value)")
}

// MARK: Daily reset

do {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    check(!DailyReset.isDue(sessionStart: at(5, 9), now: at(5, 23), calendar: calendar), "same day: no reset")
    check(!DailyReset.isDue(sessionStart: at(5, 9), now: at(6, 4, 59), calendar: calendar), "before 5 AM next day: no reset")
    check(DailyReset.isDue(sessionStart: at(5, 9), now: at(6, 5), calendar: calendar), "5 AM next day: reset")
    check(DailyReset.isDue(sessionStart: at(6, 4, 59), now: at(6, 5, 1), calendar: calendar), "started 4:59, reset at 5:00")
    check(!DailyReset.isDue(sessionStart: at(6, 5, 1), now: at(6, 23), calendar: calendar), "started 5:01 lasts the day")
    check(DailyReset.isDue(sessionStart: at(1, 12), now: at(5, 12), calendar: calendar), "days later: reset")
}

// MARK: Conversation against the fake claude

@MainActor
func conversationChecks() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-conv-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let log = tmp.appendingPathComponent("fake.log")
    var env = ProcessInfo.processInfo.environment
    env["FAKE_CLAUDE_LOG"] = log.path
    env["FAKE_CLAUDE_DELAY"] = "0.5"
    env["CLAUDECODE"] = "1"
    env["ANTHROPIC_API_KEY"] = "sk-should-never-reach-claude"
    env["ANTHROPIC_AUTH_TOKEN"] = "should-never-reach-claude"
    let config = ClaudeConfig(executable: fake, workingDirectory: tmp, model: "haiku", effort: "low", environment: env)
    var current: Result<ClaudeConfig, Conversation.SetupError> = .success(config)
    let conversation = Conversation(makeConfig: { current })
    var ended = 0
    conversation.onTurnEnded = { ended += 1 }

    conversation.prewarm()
    let sparePID = conversation.spareProcessID
    check(sparePID != nil, "prewarm starts a spare process")
    conversation.prewarm()
    check(conversation.spareProcessID == sparePID, "prewarm keeps a fresh spare")

    conversation.ask("  hello  ")
    check(conversation.sessionProcessID == sparePID, "the first question uses the spare process")
    check(conversation.isRunning, "a turn runs")
    check(wait { !conversation.isRunning }, "the echo turn ends")
    check(conversation.turns.last?.answer == "Echo: hello (turn 1)", "echo answer", conversation.turns.last?.answer ?? "nil")
    check(conversation.turns.last?.status == .done, "echo turn is done")
    check(!(conversation.turns.last?.answer.contains("SUBAGENT") ?? true), "subagent text stays out")

    conversation.ask("again")
    check(wait { !conversation.isRunning }, "the follow-up ends")
    check(conversation.turns.last?.answer == "Echo: again (turn 2)", "the follow-up reuses the session", conversation.turns.last?.answer ?? "nil")

    conversation.ask("use a tool")
    var sawActivity = false
    _ = wait { sawActivity = sawActivity || conversation.turns.last?.activity?.hasPrefix("Searching the web: swift release date") == true; return !conversation.isRunning }
    check(sawActivity, "a tool call shows as activity")
    check(conversation.turns.last?.answer == "Swift 6.4 shipped in 2026.", "tool answer", conversation.turns.last?.answer ?? "nil")
    check(conversation.turns.last?.activity == nil, "activity clears at the end")

    conversation.ask("slow please")
    _ = wait(3) { (conversation.turns.last?.answer.count ?? 0) > 20 }
    conversation.stop()
    check(wait(3) { !conversation.isRunning }, "stop ends the turn")
    check(conversation.turns.last?.status == .stopped, "stopped status", "\(String(describing: conversation.turns.last?.status))")
    let partial = conversation.turns.last?.answer ?? ""
    check(!partial.isEmpty && !partial.contains("word39"), "stop keeps the partial answer", partial)

    conversation.ask("after stop")
    check(wait { !conversation.isRunning }, "a question after stop works")
    check(conversation.turns.last?.answer == "Echo: after stop (turn 5)", "the session survives a stop", conversation.turns.last?.answer ?? "nil")

    conversation.ask("fail")
    check(wait { !conversation.isRunning }, "a failed turn ends")
    check(conversation.turns.last?.status == .failed("Not logged in. Run claude in Terminal and log in."), "a failed turn shows the reason", "\(String(describing: conversation.turns.last?.status))")

    conversation.ask("crash now")
    check(wait { !conversation.isRunning }, "a crash ends the turn")
    if case .failed(let why) = conversation.turns.last?.status {
        check(why.contains("crashed on purpose"), "a crash shows stderr", why)
    } else {
        check(false, "a crash is a failure", "\(String(describing: conversation.turns.last?.status))")
    }
    conversation.ask("back")
    check(wait { !conversation.isRunning }, "a question after a crash starts a new session")
    check(conversation.turns.last?.answer == "Echo: back (turn 1)", "the new session starts at turn 1", conversation.turns.last?.answer ?? "nil")
    check(ended == 8, "every turn reported its end once", "\(ended)")

    check(conversation.startedAt != nil, "the session knows when it started")
    check(!conversation.resetIfDue(now: Date()), "no daily reset within the day")
    let oldSession = conversation.sessionProcessID
    check(conversation.resetIfDue(now: Date().addingTimeInterval(2 * 86400)), "the daily reset clears an old session")
    check(conversation.turns.isEmpty && conversation.startedAt == nil, "the daily reset empties the session")
    conversation.reset()
    check(conversation.turns.isEmpty && conversation.sessionProcessID == nil, "reset clears the conversation")
    check(conversation.spareProcessID != nil && conversation.spareProcessID != oldSession, "reset starts a new spare")
    if let oldSession { check(wait(4) { kill(oldSession, 0) != 0 }, "reset ends the old process") }

    // Settings change: the spare is out of date and gets replaced.
    var changed = config
    changed.model = "sonnet"
    current = .success(changed)
    let before = conversation.spareProcessID
    conversation.prewarm()
    check(conversation.spareProcessID != before, "a settings change replaces the spare")

    current = .failure(.init("no claude here"))
    conversation.reset()
    conversation.ask("anything")
    check(conversation.setupProblem == "no claude here" && conversation.turns.last?.status == .failed("no claude here"), "a setup problem shows instead of an answer")

    // Review fixes. A stop claude ignores: the session is replaced, and its late text never leaks.
    current = .success(config)
    conversation.reset()
    conversation.stopGrace = 0.4
    conversation.ask("stubborn")
    _ = wait(2) { (conversation.turns.last?.answer.count ?? 0) > 5 }
    let stubbornPID = conversation.sessionProcessID
    conversation.stop()
    check(wait(2) { !conversation.isRunning }, "a stop claude ignores still ends the turn")
    conversation.ask("after that")
    check(wait(5) { !conversation.isRunning }, "the next question after an ignored stop ends")
    let next = conversation.turns.last
    check(next?.answer == "Echo: after that (turn 1)", "no late text leaks into the next answer", next?.answer ?? "nil")
    check(next?.notice?.contains("New session") == true, "the panel says a new session started", next?.notice ?? "nil")
    if let stubbornPID { check(wait(4) { kill(stubbornPID, 0) != 0 }, "the stuck session is ended") }
    conversation.stopGrace = 2

    // A live session means no spare: one claude at a time.
    check(conversation.spareProcessID == nil, "no spare runs beside a live session")
    conversation.prewarm()
    check(conversation.spareProcessID == nil, "prewarm does not start a spare beside a live session")

    // A settings change starts a new session at the next question, and says so.
    var sonnet = config
    sonnet.model = "sonnet"
    current = .success(sonnet)
    let beforeChange = conversation.sessionProcessID
    conversation.ask("model changed")
    check(wait(5) { !conversation.isRunning }, "the turn after a settings change ends")
    check(conversation.sessionProcessID != beforeChange, "a settings change starts a new session")
    check(conversation.turns.last?.notice?.hasPrefix("Settings changed") == true, "the panel says settings changed", conversation.turns.last?.notice ?? "nil")
    // An environment-only change (the login shell loading late) keeps the session.
    var envOnly = sonnet
    envOnly.environment["SOMETHING_NEW"] = "1"
    current = .success(envOnly)
    let same = conversation.sessionProcessID
    conversation.ask("env changed")
    check(wait(5) { !conversation.isRunning }, "the turn after an env change ends")
    check(conversation.sessionProcessID == same && conversation.turns.last?.notice == nil, "an env-only change keeps the session")

    // Keep warm off stops the spare at once.
    conversation.reset()
    check(conversation.spareProcessID != nil, "reset starts a spare")
    let warmPID = conversation.spareProcessID
    conversation.setKeepWarm(false)
    check(conversation.spareProcessID == nil, "keep warm off drops the spare")
    if let warmPID { check(wait(4) { kill(warmPID, 0) != 0 }, "keep warm off ends the spare process") }
    conversation.setKeepWarm(true)

    let spare = conversation.spareProcessID
    conversation.shutdown()
    if let spare { check(wait(4) { kill(spare, 0) != 0 }, "shutdown ends the spare") }

    let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check(logText.contains("--no-session-persistence") && logText.contains("\"haiku\""), "claude got the right arguments")
    let realTmp = tmp.path.hasPrefix("/var/") ? "/private" + tmp.path : tmp.path
    check(logText.contains("cwd \(realTmp)") || logText.contains("cwd \(tmp.path)"), "claude runs in the chosen folder", String(logText.prefix(300)))
    check(logText.contains("interrupt"), "stop sent an interrupt")
    check(!logText.contains("env ANTHROPIC") && !logText.contains("env CLAUDECODE") && logText.contains("env \n"),
          "claude gets no API key and no nested-session marker, so it uses the CLI login")
}

MainActor.assumeIsolated { conversationChecks() }

/// `sidekick-checks --live`: one real question through the user's own claude, in the default folder.
/// Costs a few cents, needs a login, opens no windows.
@MainActor
func liveCheck() {
    let defaults = UserDefaults(suiteName: "sidekick-checks-live")!
    Preferences.register(defaults)
    let env = ShellEnvironment.load()
    let conversation = Conversation(makeConfig: { Preferences.config(defaults: defaults, environment: env) })
    let start = Date()
    conversation.prewarm()
    _ = wait(3) { false }
    let asked = Date()
    conversation.ask("Reply with exactly the word pong and nothing else.")
    var firstText: TimeInterval?
    _ = wait(90) {
        if firstText == nil, conversation.turns.last?.answer.isEmpty == false { firstText = Date().timeIntervalSince(asked) }
        return !conversation.isRunning
    }
    let answer = conversation.turns.last?.answer ?? ""
    check(conversation.turns.last?.status == .done, "live: the turn ends", "\(String(describing: conversation.turns.last?.status))")
    check(answer.lowercased().contains("pong"), "live: real claude answers", answer)
    conversation.ask("What word did you just reply with? One word.")
    _ = wait(90) { !conversation.isRunning }
    check(conversation.turns.last?.answer.lowercased().contains("pong") == true, "live: the follow-up remembers", conversation.turns.last?.answer ?? "")
    print(String(format: "live: first text %.1fs after asking (warm), total %.1fs", firstText ?? -1, Date().timeIntervalSince(start)))
    conversation.shutdown()
    defaults.removePersistentDomain(forName: "sidekick-checks-live")
}

if CommandLine.arguments.contains("--live") { MainActor.assumeIsolated { liveCheck() } }

if failures == 0 {
    print("CHECKS PASS: \(passed) checks")
    exit(0)
} else {
    print("CHECKS FAIL: \(failures) of \(passed + failures) failed")
    exit(1)
}
