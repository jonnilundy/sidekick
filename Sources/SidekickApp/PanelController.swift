import AppKit
import SwiftUI
import SidekickCore

/// A borderless panel that can take typing without activating the app, like Spotlight.
final class SidekickPanel: NSPanel {
    /// Keys the panel handles itself, before the text field sees them.
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, keyHandler?(event) == true { return }  // Esc
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// Owns the panel window: where it sits, when it shows, how it slides, and its keys.
@MainActor
final class PanelController {
    let model: PanelModel
    let panel: SidekickPanel
    private let hosting: NSHostingView<PanelView>
    private var mouseMonitor: Any?
    private var shrinkWork: DispatchWorkItem?
    private var cardHeight: CGFloat = 60
    /// The app that was in front when the panel opened. It gets the keyboard back when the panel goes.
    private var previousApp: NSRunningApplication?
    var onVisibilityChange: ((Bool) -> Void)?
    /// Checked on every open: when true and 5 AM has passed since the session began, start fresh.
    var dailyResetEnabled: () -> Bool = { true }
    var onOpenSettings: (() -> Void)?

    /// What the user asked for last. `model.shown` follows a frame later (the card lays out hidden
    /// first so it can slide), so decisions like toggle read this one.
    private(set) var wantsShown = false
    var isVisible: Bool { wantsShown }
    var screenProvider: () -> NSScreen? = {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    init(model: PanelModel) {
        self.model = model
        panel = SidekickPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.windowWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own shadow; a window shadow would outline the transparent margin.
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.title = "Sidekick"
        panel.setAccessibilityIdentifier("sidekick-panel")

        hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        model.onCardSize = { [weak self] size in self?.cardSizeChanged(size) }
        model.onHide = { [weak self] in self?.hide() }
        model.onNew = { [weak self] in self?.newConversation() }
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.wantsShown == true { self?.place(on: self?.panel.screen) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        }
    }

    // MARK: Show and hide

    func toggle() {
        if wantsShown && panel.isKeyWindow { hide() } else { show() }
    }

    /// Brings the card in from the right edge and puts the cursor in the text field.
    /// `focus: false` shows it without taking the keyboard (an answer arriving while you work elsewhere).
    func show(focus: Bool = true) {
        // Only when the user opens it: an answer arriving at 5:01 must not be wiped on its way in.
        if focus, !wantsShown, dailyResetEnabled(), model.conversation.resetIfDue() {
            model.input = ""
            model.resetVisibility()
        }
        // Opened by you after a quiet spell: just the empty field. An answer arriving shows as is.
        if focus, !wantsShown { model.collapseIfIdle() }
        model.conversation.prewarm()
        if focus, let front = NSWorkspace.shared.frontmostApplication, front != .current {
            previousApp = front
        }
        if !wantsShown {
            wantsShown = true
            if !panel.isVisible { place(on: screenProvider()) }
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            debug("before orderFront")
            panel.orderFrontRegardless()
            debug("after orderFront")
            // Let the card lay out at its hidden offset first, so the slide starts from the edge.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.wantsShown else { return }
                withAnimation(self.arriveAnimation) { self.model.shown = true }
            }
            onVisibilityChange?(true)
        } else {
            panel.orderFrontRegardless()
        }
        if focus {
            panel.makeKey()
            debug("after makeKey")
            model.focusRequest += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.debug("after focus") }
        }
        startMouseMonitor()
    }

    /// Slides the card back out the way it came. The conversation stays until Reset.
    func hide() {
        guard wantsShown else { return }
        wantsShown = false
        model.touch()
        stopMouseMonitor()
        withAnimation(leaveAnimation) {
            model.shown = false
        } completion: { [weak self] in
            self?.finishHide()
        }
        // SwiftUI skips the completion when nothing on screen changed, so never depend on it alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.finishHide() }
        onVisibilityChange?(false)
    }

    private func finishHide() {
        guard !wantsShown, panel.isVisible else { return }
        panel.orderOut(nil)
        returnFocus()
    }

    /// makeKey activates the app even for a nonactivating panel (macOS 26), so hand the keyboard back
    /// to the app that had it. Skipped when another Sidekick window (Settings) is in use.
    private func returnFocus() {
        defer { previousApp = nil }
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }) else { return }
        if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    private func debug(_ what: String) {
        guard ProcessInfo.processInfo.environment["SIDEKICK_DEBUG"] != nil else { return }
        print("panel: \(what) active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
    }

    func newConversation() {
        model.conversation.reset()
        model.resetVisibility()
        model.input = ""
        model.focusRequest += 1
    }

    /// A turn ended. If the panel was put away while it ran, bring it back so the answer is seen.
    func turnEnded() {
        model.touch()
        if !wantsShown { show(focus: false) }
    }

    private var arriveAnimation: Animation {
        model.reduceMotion ? .easeOut(duration: 0.18) : .spring(response: Spring.arrive.response, dampingFraction: Spring.arrive.damping)
    }

    private var leaveAnimation: Animation {
        model.reduceMotion ? .easeIn(duration: 0.14) : .spring(response: Spring.leave.response, dampingFraction: Spring.leave.damping)
    }

    // MARK: Geometry

    /// Puts the window at the top right of the screen, under the menu bar, flush with the right edge.
    func place(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        model.maxTranscriptHeight = max(200, (visible.height - 140) * 0.78)
        let height = windowHeight(for: cardHeight)
        let frame = NSRect(x: visible.maxX - PanelMetrics.windowWidth, y: visible.maxY - height,
                           width: PanelMetrics.windowWidth, height: height)
        panel.setFrame(frame, display: false)
    }

    private func windowHeight(for card: CGFloat) -> CGFloat {
        PanelMetrics.top + card + PanelMetrics.bottom
    }

    /// The card's layout size changed (a new answer line, a new turn). Grow the window at once so the
    /// card can animate into the room; shrink it only after the card has finished shrinking.
    private func cardSizeChanged(_ size: CGSize) {
        guard size.height > 0, abs(size.height - cardHeight) > 0.5 else { return }
        cardHeight = size.height
        shrinkWork?.cancel()
        let target = windowHeight(for: size.height)
        if target >= panel.frame.height {
            setWindowHeight(target)
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.setWindowHeight(self.windowHeight(for: self.cardHeight))
            }
            shrinkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    private func setWindowHeight(_ height: CGFloat) {
        var frame = panel.frame
        guard abs(frame.height - height) > 0.5 else { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }

    // MARK: Keys and clicks

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 && flags.subtracting([.function, .numericPad]).isEmpty {  // Esc
            hide()
            return true
        }
        guard flags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = flags.contains(.shift)
        switch key {
        case "n": newConversation(); return true
        case "w": hide(); return true
        case ".": model.conversation.stop(); return true
        case ",": onOpenSettings?(); return true
        case "c" where shift:
            copyLastAnswer(); return true
        // An app without a main menu gets no Edit menu, so wire the text keys here.
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case "z": return NSApp.sendAction(shift ? Selector(("redo:")) : Selector(("undo:")), to: nil, from: nil)
        default: return false
        }
    }

    func copyLastAnswer() {
        guard let answer = model.conversation.lastAnswer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    /// Clicking into another app puts the panel away, unless an answer is still coming.
    func clickedOutside() {
        guard wantsShown, !model.conversation.isRunning else { return }
        hide()
    }

    private func startMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }
    }

    private func stopMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}
