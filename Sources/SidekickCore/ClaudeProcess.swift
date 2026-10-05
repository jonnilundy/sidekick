import Foundation

/// One running `claude -p` session. Started ahead of time so the first question skips the startup,
/// then kept for the follow-ups of one conversation. Events arrive on the main actor.
@MainActor
public final class ClaudeProcess {
    public enum State: Equatable, Sendable {
        case starting, ready, busy, exited(code: Int32)
    }

    /// Auth variables that would make claude bill an API key instead of using the CLI login.
    public static let apiKeyVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"]

    public private(set) var state: State = .starting
    public let config: ClaudeConfig
    public let startedAt = Date()
    /// Called for every event, and once with nil when the process exits.
    public var onEvent: ((StreamEvent?) -> Void)?
    public private(set) var stderrTail = ""

    private let process = Process()
    private let stdin = Pipe()
    private var parser = StreamParser()
    private var interruptCount = 0

    public init(config: ClaudeConfig) {
        self.config = config
    }

    public var isAlive: Bool {
        if case .exited = state { return false }
        return true
    }

    public func start() throws {
        process.executableURL = config.executable
        process.arguments = config.arguments
        process.currentDirectoryURL = config.workingDirectory
        var env = config.environment
        // A Sidekick started from inside a Claude Code session must not look like a nested session.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
        // Always the user's own Claude Code login (claude.ai subscription), never an API key from the shell.
        for key in ClaudeProcess.apiKeyVariables { env.removeValue(forKey: key) }
        process.environment = env
        process.standardInput = stdin
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // The main queue is FIFO, so chunks arrive in order (separate Tasks do not promise that).
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receiveError(data) } }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            // Let the last stdout bytes land before reporting the exit.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { self?.exited(code: code) }
            }
        }
        try process.run()
        // A write to a claude that just died must fail with an error, not kill Sidekick with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    /// Sends one user message. The answer streams back through `onEvent`.
    public func send(_ text: String) {
        guard isAlive else { return }
        state = .busy
        stderrTail = ""
        write(ClaudeConfig.userMessage(text))
    }

    /// Stops the current answer. The session stays, so a follow-up still knows the earlier turns.
    public func interrupt() {
        guard state == .busy else { return }
        interruptCount += 1
        write(ClaudeConfig.interruptRequest(id: "sidekick-interrupt-\(interruptCount)"))
    }

    /// Ends the session. Closing stdin lets claude exit on its own; a stuck one is killed after a second.
    public func stop() {
        guard isAlive else { return }
        try? stdin.fileHandleForWriting.close()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Ends the process now. For quitting: timers would never fire after the app exits.
    public func kill() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    public var processIdentifier: Int32 { process.processIdentifier }

    private func write(_ data: Data) {
        do {
            try stdin.fileHandleForWriting.write(contentsOf: data)
        } catch {
            stderrTail += "\ncould not write to claude: \(error.localizedDescription)"
        }
    }

    private func receive(_ data: Data) {
        for event in parser.feed(data) {
            switch event {
            case .ready where state == .starting: state = .ready
            case .done: if isAlive { state = .ready }
            default: break
            }
            onEvent?(event)
        }
    }

    private func receiveError(_ data: Data) {
        stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(2000))
    }

    private func exited(code: Int32) {
        guard isAlive else { return }
        state = .exited(code: code)
        onEvent?(nil)
    }
}
