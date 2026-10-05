import Foundation
import Observation

/// One ephemeral conversation: the questions asked since the panel was last cleared, and the claude
/// session that answers them. Keeps a spare session started in the background so the next question
/// does not wait for Claude Code to boot.
@MainActor
@Observable
public final class Conversation {
    public enum Status: Equatable, Sendable {
        case running, done, stopped, failed(String)
    }

    public struct Turn: Identifiable, Equatable, Sendable {
        public let id: Int
        public let question: String
        public var answer = ""
        public var status = Status.running
        /// What claude is doing right now, for example "Searching the web: swift 6 release date".
        public var activity: String?
    }

    public private(set) var turns: [Turn] = []
    /// Set when claude cannot start at all (not installed, folder missing). Shown instead of an answer.
    public private(set) var setupProblem: String?

    /// When the first question of this session was asked. Nil while empty.
    public private(set) var startedAt: Date?

    public var isRunning: Bool { turns.last?.status == .running }
    public var isEmpty: Bool { turns.isEmpty }
    public var lastAnswer: String? { turns.last(where: { !$0.answer.isEmpty })?.answer }

    /// Called when a turn ends in any way, so the app can bring a hidden panel back.
    @ObservationIgnored public var onTurnEnded: (() -> Void)?
    /// Keep a spare process running between conversations.
    @ObservationIgnored public var keepWarm = true
    /// A spare older than this is replaced, so settings and MCP changes get picked up.
    @ObservationIgnored public var warmMaxAge: TimeInterval = 30 * 60

    @ObservationIgnored private let makeConfig: () -> Result<ClaudeConfig, SetupError>
    @ObservationIgnored private var session: ClaudeProcess?
    @ObservationIgnored private var spare: ClaudeProcess?
    @ObservationIgnored private var stopRequested = false
    @ObservationIgnored private var nextID = 0

    public struct SetupError: Error, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    public init(makeConfig: @escaping () -> Result<ClaudeConfig, SetupError>) {
        self.makeConfig = makeConfig
    }

    /// The pid of the spare process, for checks and the debug menu.
    public var spareProcessID: Int32? { spare?.isAlive == true ? spare?.processIdentifier : nil }
    public var sessionProcessID: Int32? { session?.isAlive == true ? session?.processIdentifier : nil }

    /// Starts a spare process when there is none, or replaces one that is old, dead or out of date.
    public func prewarm() {
        guard keepWarm else { return }
        guard case .success(let config) = makeConfig() else { return }
        if let spare, spare.isAlive, spare.config == config, Date().timeIntervalSince(spare.startedAt) < warmMaxAge {
            return
        }
        spare?.stop()
        spare = launch(config)
    }

    public func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        setupProblem = nil
        if turns.isEmpty { startedAt = Date() }
        nextID += 1
        turns.append(Turn(id: nextID, question: text))

        if session?.isAlive != true {
            switch makeConfig() {
            case .failure(let error):
                setupProblem = error.message
                finish(.failed(error.message))
                return
            case .success(let config):
                if let spare, spare.isAlive, spare.config == config {
                    session = spare
                } else {
                    spare?.stop()
                    session = launch(config)
                }
                spare = nil
            }
        }
        guard let session else {
            finish(.failed(setupProblem ?? "Claude did not start."))
            return
        }
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, session === self.session else { return }
            self.handle(event, from: session)
        }
        stopRequested = false
        session.send(text)
    }

    /// Stops the current answer and keeps what arrived so far.
    public func stop() {
        guard isRunning else { return }
        stopRequested = true
        session?.interrupt()
        // If claude does not confirm quickly, end the turn anyway so the panel never hangs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.stopRequested else { return }
                self.finish(.stopped)
            }
        }
    }

    /// Forgets the conversation and ends its session. A fresh spare starts for the next one.
    public func reset() {
        session?.onEvent = nil
        session?.stop()
        session = nil
        turns = []
        startedAt = nil
        setupProblem = nil
        stopRequested = false
        prewarm()
    }

    /// Resets when the daily reset hour has passed since the session started, unless an answer is running.
    /// Returns true when it reset.
    @discardableResult
    public func resetIfDue(now: Date = Date(), hour: Int = 5) -> Bool {
        guard let startedAt, !isRunning, DailyReset.isDue(sessionStart: startedAt, now: now, hour: hour) else { return false }
        reset()
        return true
    }

    /// Ends every process. For quitting.
    public func shutdown() {
        session?.onEvent = nil
        session?.stop()
        spare?.stop()
        session = nil
        spare = nil
    }

    private func launch(_ config: ClaudeConfig) -> ClaudeProcess? {
        let process = ClaudeProcess(config: config)
        do {
            try process.start()
            return process
        } catch {
            setupProblem = "Could not start claude at \(config.executable.path): \(error.localizedDescription)"
            return nil
        }
    }

    private func handle(_ event: StreamEvent?, from session: ClaudeProcess) {
        guard isRunning, let index = turns.indices.last else {
            if event == nil { self.session = nil }
            return
        }
        switch event {
        case .ready:
            break
        case .text(let text):
            turns[index].answer += text
            turns[index].activity = nil
        case .tool(let name, let detail):
            turns[index].activity = ToolLabel.label(name: name, detail: detail)
        case .done(let isError, let text):
            if stopRequested {
                finish(.stopped)
            } else if isError {
                finish(.failed(Self.clean(text) ?? Self.clean(session.stderrTail) ?? "Claude stopped with an error."))
            } else {
                if turns[index].answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text {
                    turns[index].answer = text
                }
                finish(.done)
            }
        case nil:
            self.session = nil
            let code: Int32 = if case .exited(let code) = session.state { code } else { -1 }
            finish(.failed(Self.clean(session.stderrTail) ?? "Claude quit (exit \(code))."))
        }
    }

    private func finish(_ status: Status) {
        guard let index = turns.indices.last, turns[index].status == .running else { return }
        turns[index].status = status
        turns[index].activity = nil
        stopRequested = false
        onTurnEnded?()
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > 400 ? String(text.suffix(400)) : text
    }
}
