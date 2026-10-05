import AppKit
import Observation
import SidekickCore

/// What the panel view reads and the controller drives.
@MainActor
@Observable
final class PanelModel {
    let conversation: Conversation
    var input = ""
    /// True while the card is on screen or arriving. The view slides on changes to it.
    var shown = false
    /// Bumped to put the cursor back in the text field.
    var focusRequest = 0
    /// The tallest the transcript may get before it scrolls.
    var maxTranscriptHeight: CGFloat = 520
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// The shortcut, for the placeholder ("⌥⌘Space").
    var shortcutHint = ""
    /// First open after install: say how to open it next time.
    var showWelcome = false
    /// Turns before this index are kept in the session but not shown. Opening after a quiet spell
    /// hides them all; the pull at the bottom of the card shows them again.
    var visibleFrom = 0
    /// The last time something happened: a question sent, an answer finished, the panel put away.
    @ObservationIgnored var lastActivity: Date?
    @ObservationIgnored var idleCollapseAfter: TimeInterval = IdleCollapse.defaultAfter

    @ObservationIgnored var onSubmit: (() -> Void)?
    /// True when the daily reset is on. Checked on submit too, for a panel left open across 5 AM.
    @ObservationIgnored var dailyResetEnabled: () -> Bool = { true }
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onNew: (() -> Void)?
    /// The card's frame in the window (SwiftUI coordinates), from layout.
    @ObservationIgnored var onCardFrame: ((CGRect) -> Void)?

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !conversation.isRunning else { return }
        input = ""
        showWelcome = false
        if dailyResetEnabled(), conversation.resetIfDue() { visibleFrom = 0 }
        conversation.ask(text)
        touch()
        onSubmit?()
    }

    func touch() { lastActivity = Date() }

    var hiddenCount: Int { min(visibleFrom, conversation.turns.count) }
    var visibleTurns: ArraySlice<Conversation.Turn> { conversation.turns[hiddenCount...] }
    var historyOpen: Bool { hiddenCount == 0 && conversation.turns.count > 0 }
    /// True when earlier turns can be pulled into view or tucked away.
    var canPull: Bool { hiddenCount > 0 || (historyOpen && !conversation.isRunning) }

    /// Just the field: no turns on screen. The card is then half as wide until the text needs room.
    var isCompact: Bool {
        visibleTurns.isEmpty && !showWelcome && conversation.setupProblem == nil
            && !input.contains("\n") && input.count <= PanelMetrics.compactCharacters
    }

    /// Opening after a quiet spell: show only the empty field. The session keeps every turn.
    func collapseIfIdle(now: Date = Date()) {
        guard !conversation.isRunning, IdleCollapse.isDue(lastActivity: lastActivity, now: now, after: idleCollapseAfter) else { return }
        visibleFrom = conversation.turns.count
    }

    func showHistory() { visibleFrom = 0 }

    /// Tucks every finished turn away. A running turn stays in view.
    func hideHistory() {
        guard !conversation.isRunning else { return }
        visibleFrom = conversation.turns.count
    }

    func resetVisibility() { visibleFrom = 0 }
}

/// The sizes the view and the controller share.
enum PanelMetrics {
    static let cardWidth: CGFloat = 440
    /// The field alone: half the full width.
    static let compactWidth: CGFloat = 220
    /// About what fits in the compact field before it widens.
    static let compactCharacters = 18
    /// Gap between the card and the right screen edge.
    static let edgeGap: CGFloat = 12
    /// Room inside the window around the card for the shadow and the arrival overshoot.
    static let leading: CGFloat = 44
    static let top: CGFloat = 8
    static let bottom: CGFloat = 36
    static let cornerRadius: CGFloat = 22
    static var windowWidth: CGFloat { cardWidth + edgeGap + leading }
}
