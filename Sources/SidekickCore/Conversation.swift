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
        /// Shown above the question, for example when this turn starts a new session.
        public var notice: String?
    }

    public private(set) var turns: [Turn] = []
    /// Set when claude cannot start at all (not installed, folder missing). Shown instead of an answer.
    public private(set) var setupProblem: String?

    /// The model that gave the last answer, as claude reported it.
    public private(set) var lastModel: String?
    @ObservationIgnored public var onModel: ((String) -> Void)?

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
    /// The session died or was replaced mid-conversation; the next turn says so.
    @ObservationIgnored private var sessionLost = false
    @ObservationIgnored private var nextID = 0
    /// Text that arrived but is not on screen yet. Deltas come many times a frame on a fast stream;
    /// showing them in batches keeps the main thread free for drawing.
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var flushScheduled = false
    /// How often batched text reaches the screen.
    @ObservationIgnored public var textBatchInterval: TimeInterval = 1.0 / 30

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
    /// Not while a session is live: one claude at a time is enough.
    public func prewarm() {
        guard keepWarm, session?.isAlive != true else { return }
        guard case .success(let config) = makeConfig() else { return }
        if let spare, spare.isAlive, spare.config == config, Date().timeIntervalSince(spare.startedAt) < warmMaxAge {
            return
        }
        spare?.stop()
        spare = launch(config)
    }

    /// Turns the spare on or off. Off stops the waiting process at once.
    public func setKeepWarm(_ on: Bool) {
        keepWarm = on
        if on {
            prewarm()
        } else {
            spare?.stop()
            spare = nil
        }
    }

    public func ask(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        setupProblem = nil
        if turns.isEmpty { startedAt = Date() }
        nextID += 1
        var turn = Turn(id: nextID, question: text)

        let config: ClaudeConfig
        switch makeConfig() {
        case .failure(let error):
            turns.append(turn)
            setupProblem = error.message
            finish(.failed(error.message))
            return
        case .success(let current):
            config = current
        }
        // The live session goes when it died, when settings changed, or when it is still busy with a
        // turn it never finished (a stop claude did not honor). Earlier turns are then not remembered.
        if let live = session, !live.isAlive || !live.config.sameSettings(as: config) || live.state == .busy {
            if live.isAlive && !live.config.sameSettings(as: config) { turn.notice = "Settings changed. New session: earlier questions are not remembered." }
            else if !turns.isEmpty { turn.notice = "New session: earlier questions are not remembered." }
            endSession()
        } else if session == nil, sessionLost, !turns.isEmpty {
            turn.notice = "New session: earlier questions are not remembered."
        }
        sessionLost = false
        turns.append(turn)

        if session == nil {
            if let spare, spare.isAlive, spare.config == config {
                session = spare
            } else {
                spare?.stop()
                session = launch(config)
            }
            spare = nil
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
        flushText()
        stopRequested = true
        session?.interrupt()
        // If claude does not confirm quickly, end the turn anyway so the panel never hangs. That session
        // may still be mid-turn, so it is ended too; its late output must not leak into the next answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + stopGrace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.stopRequested else { return }
                self.endSession()
                self.sessionLost = true
                self.finish(.stopped)
            }
        }
    }

    /// How long a stop waits for claude to confirm before the session is replaced.
    @ObservationIgnored public var stopGrace: TimeInterval = 2

    /// Forgets the conversation and ends its session. A fresh spare starts for the next one.
    public func reset() {
        endSession()
        sessionLost = false
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
        session?.kill()
        spare?.kill()
        session = nil
        spare = nil
    }

    private func endSession() {
        pendingText = ""
        session?.onEvent = nil
        session?.stop()
        session = nil
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
            if event == nil { self.session = nil; sessionLost = true }
            return
        }
        switch event {
        case .ready:
            break
        case .model(let id):
            if lastModel != id { lastModel = id; onModel?(id) }
        case .text(let text):
            pendingText += text
            if turns[index].activity != nil { turns[index].activity = nil }
            scheduleFlush()
        case .tool(let name, let detail):
            flushText()
            turns[index].activity = ToolLabel.label(name: name, detail: detail)
        case .done(let isError, let text):
            flushText()
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
            flushText()
            self.session = nil
            sessionLost = true
            let code: Int32 = if case .exited(let code) = session.state { code } else { -1 }
            finish(.failed(Self.clean(session.stderrTail) ?? "Claude quit (exit \(code))."))
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + textBatchInterval) { [weak self] in
            MainActor.assumeIsolated { self?.flushText() }
        }
    }

    /// Moves batched text onto the running turn.
    private func flushText() {
        flushScheduled = false
        guard !pendingText.isEmpty else { return }
        defer { pendingText = "" }
        guard let index = turns.indices.last, turns[index].status == .running else { return }
        turns[index].answer += pendingText
    }

    private func finish(_ status: Status) {
        flushText()
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
