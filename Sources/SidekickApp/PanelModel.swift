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

    @ObservationIgnored var onSubmit: (() -> Void)?
    @ObservationIgnored var onHide: (() -> Void)?
    @ObservationIgnored var onNew: (() -> Void)?
    /// The card's full size from layout (target values, not the animated ones).
    @ObservationIgnored var onCardSize: ((CGSize) -> Void)?

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !conversation.isRunning else { return }
        input = ""
        showWelcome = false
        conversation.ask(text)
        onSubmit?()
    }
}

/// The sizes the view and the controller share.
enum PanelMetrics {
    static let cardWidth: CGFloat = 440
    /// Gap between the card and the right screen edge.
    static let edgeGap: CGFloat = 12
    /// Room inside the window around the card for the shadow and the arrival overshoot.
    static let leading: CGFloat = 44
    static let top: CGFloat = 8
    static let bottom: CGFloat = 36
    static let cornerRadius: CGFloat = 22
    static var windowWidth: CGFloat { cardWidth + edgeGap + leading }
}
