import AppKit
import SidekickCore

/// The README demo. Runs the real panel against scripts/fake-claude (with FAKE_CLAUDE_DEMO=1) and
/// drives it at a human pace: real key events, a real drag on the grabber. scripts/vm-demo.sh records
/// the screen around it. Only in the VM, like the probe: it opens the panel and takes the keyboard.
/// Saves full screen stills of the finished answers in the out folder, and prints the card's frame
/// for each so the stills can be cropped later.
@MainActor
final class Demo: NSObject, NSApplicationDelegate {
    let outFolder: URL
    private var app: AppDelegate!
    private var statusItem: NSStatusItem?
    private var hiddenApps: [NSRunningApplication] = []
    private let started = Date()

    init(outFolder: URL) {
        self.outFolder = outFolder
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["SIDEKICK_CLAUDE_PATH"] != nil else {
            print("demo: set SIDEKICK_CLAUDE_PATH to scripts/fake-claude")
            exit(2)
        }
        let suite = "com.jonnilundy.sidekick.demo.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(NSTemporaryDirectory(), forKey: Preferences.Key.folder)
        try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        app = AppDelegate(defaults: defaults, isProbe: true)
        app.applicationDidFinishLaunching(notification)
        setUpStatusItem()
        Task {
            await run()
            app.conversation.shutdown()
            defaults.removePersistentDomain(forName: suite)
            for other in hiddenApps { other.unhide() }
            mark("end")
            exit(0)
        }
    }

    private var panel: SidekickPanel { app.panel.panel }
    private var model: PanelModel { app.model }
    private var conversation: Conversation { app.conversation }

    /// The real app's menu bar item. The probe mode skips it, so the demo adds the same one.
    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        setStatusIcon(active: false)
        app.panel.onVisibilityChange = { [weak self] visible in self?.setStatusIcon(active: visible) }
    }

    private func setStatusIcon(active: Bool) {
        let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sidekick")
        image?.isTemplate = true
        statusItem?.button?.image = image?.withSymbolConfiguration(.init(pointSize: 14, weight: active ? .bold : .medium))
    }

    /// A timestamp in the log, to find the moments in the recording.
    private func mark(_ what: String) {
        print("demo: \(String(format: "%6.2f", Date().timeIntervalSince(started))) \(what)")
    }

    private func until(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: panel.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// Types like a person: about 14 characters per second, a little uneven, a short wait after a
    /// word. Then a breath and Return.
    private func type(_ text: String) async {
        var rng = SeededRandom(seed: UInt64(text.count))
        for char in text {
            panel.sendEvent(key(0, String(char)))
            await pause(0.045 + 0.03 * rng.next() + (char == " " ? 0.02 : 0))
        }
        await pause(0.45)
        panel.sendEvent(key(36, "\r"))
    }

    private func escape() { panel.sendEvent(key(53, "\u{1B}")) }

    /// Waits for the answer to finish, then leaves time to read it.
    private func answer(_ name: String) async {
        mark("\(name) sent")
        _ = await until(20) { !conversation.isRunning && conversation.turns.last?.status == .done }
        mark("\(name) done: \(conversation.turns.last?.answer.count ?? 0) chars")
    }

    // MARK: Pointer

    private var screenTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// A window point as a global point (top left origin), for CGEvent and the cursor.
    private func global(_ windowPoint: NSPoint) -> CGPoint {
        let screen = panel.convertPoint(toScreen: windowPoint)
        return CGPoint(x: screen.x, y: screenTop - screen.y)
    }

    /// A spot on the desktop away from the card, where the pointer waits.
    private var quietSpot: CGPoint {
        let frame = NSScreen.screens.first?.frame ?? .zero
        return CGPoint(x: frame.width * 0.42, y: frame.height * 0.62)
    }

    private var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Moves the cursor in steps. Each step is a real mouse moved event when the process may post
    /// events (hover then works); the warp keeps the cursor moving when it may not.
    private func movePointer(to target: CGPoint, duration: Double) async {
        let from = pointer
        let steps = max(1, Int(duration / 0.016))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let point = CGPoint(x: from.x + (target.x - from.x) * eased, y: from.y + (target.y - from.y) * eased)
            CGWarpMouseCursorPosition(point)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            await pause(0.016)
        }
        app.panel.refreshPointer()
    }

    /// A real drag on the grabber at the bottom center of the card. The cursor follows the drag.
    private func dragGrabber(by distance: CGFloat) async {
        let cardWidth = model.isCompact ? PanelMetrics.compactWidth : PanelMetrics.cardWidth
        let start = NSPoint(x: panel.frame.width - PanelMetrics.edgeGap - cardWidth / 2, y: app.panel.cardRect.minY + 6)
        await movePointer(to: global(start), duration: 0.55)
        await pause(0.35)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        panel.sendEvent(mouse(.leftMouseDown, start))
        let steps = 26
        for step in 1...steps {
            await pause(0.016)
            let t = Double(step) / Double(steps)
            let eased = CGFloat(1 - pow(1 - t, 2))
            // Window coordinates grow upward, so a pull down lowers y.
            let point = NSPoint(x: start.x, y: start.y - distance * eased)
            CGWarpMouseCursorPosition(global(point))
            panel.sendEvent(mouse(.leftMouseDragged, point))
        }
        await pause(0.05)
        panel.sendEvent(mouse(.leftMouseUp, NSPoint(x: start.x, y: start.y - distance)))
    }

    // MARK: Stills

    /// A full screen still. The log line has the card's frame in screen points (top left origin)
    /// and the scale, for cropping.
    private func still(_ name: String) async {
        let window = panel.frame
        let card = app.panel.cardRect
        let scale = panel.screen?.backingScaleFactor ?? 2
        let x = window.minX + card.minX
        let y = screenTop - (window.minY + card.maxY)
        print("demo: still \(name) card x=\(Int(x)) y=\(Int(y)) w=\(Int(card.width)) h=\(Int(card.height)) scale=\(scale) screen=\(NSScreen.screens.first?.frame.size ?? .zero)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", outFolder.appendingPathComponent("\(name).png").path]
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: The take

    private func run() async {
        _ = await until(8) { conversation.spareProcessID != nil }
        // A clean desktop: other apps hidden for the take, shown again at the end. Finder stays and
        // goes in front, so Esc hands the keyboard to Finder and wakes no hidden window.
        let finder = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }
        finder?.activate()
        hiddenApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0 != .current && $0 != finder && !$0.isHidden
        }
        for other in hiddenApps { other.hide() }
        await pause(0.5)
        finder?.activate()
        // Sidekick in dark. The rest of the system keeps its own appearance.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        CGWarpMouseCursorPosition(quietSpot)
        await pause(2.0)

        // The take: open, ask, follow up, put away, reopen after a quiet spell, pull the history.
        mark("show")
        app.panel.show()
        await pause(0.8)
        mark("typing 1")
        await type("What's the time difference between San Francisco and Tokyo?")
        await answer("question 1")
        // A still takes about a second with the screen at rest, so it counts as reading time.
        await pause(1.0)
        await still("dark-1")
        mark("typing 2")
        await type("Best time for a call with both?")
        await answer("question 2")
        await pause(1.3)
        await still("dark-2")
        model.idleCollapseAfter = 0.3
        mark("esc")
        escape()
        await pause(1.0)
        mark("reopen")
        app.panel.show()
        await pause(0.8)
        mark("pull")
        await dragGrabber(by: 150)
        mark("pulled open=\(model.historyOpen)")
        await pause(0.3)
        await movePointer(to: quietSpot, duration: 0.4)
        await pause(0.4)
        await still("dark-history")
        mark("esc 2")
        escape()
        await pause(1.5)
    }
}

/// A tiny repeatable random source, so typing rhythm is the same in every take.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    /// A number in 0..<1.
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }
}
