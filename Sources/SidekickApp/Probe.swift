import AppKit
import SidekickCore

/// The window test. Runs the real panel, controller and conversation against scripts/fake-claude,
/// drives it through real key events, checks the result, and saves screenshots of each state.
/// Only in the VM: it opens a panel and takes the keyboard. Prints "PROBE PASS" or the failures.
@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    let outFolder: URL
    private var app: AppDelegate!
    private var failures: [String] = []
    private var passed = 0

    init(outFolder: URL) {
        self.outFolder = outFolder
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["SIDEKICK_CLAUDE_PATH"] != nil else {
            print("probe: set SIDEKICK_CLAUDE_PATH to scripts/fake-claude")
            exit(2)
        }
        let suite = "com.jonnilundy.sidekick.probe.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(NSTemporaryDirectory(), forKey: Preferences.Key.folder)
        try? FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        // Line by line, so the log shows how far a hung run got.
        setvbuf(stdout, nil, _IOLBF, 0)
        app = AppDelegate(defaults: defaults, isProbe: true)
        app.applicationDidFinishLaunching(notification)
        let worst = CommandLine.arguments.contains("worst")
        Task {
            if worst { await runWorst() } else { await run() }
            app.conversation.shutdown()
            defaults.removePersistentDomain(forName: suite)
            if failures.isEmpty {
                print("PROBE PASS: \(passed) checks")
                exit(0)
            }
            for failure in failures { print("FAIL \(failure)") }
            print("PROBE FAIL: \(failures.count) of \(passed + failures.count) failed")
            exit(1)
        }
    }

    private var panel: SidekickPanel { app.panel.panel }
    private var model: PanelModel { app.model }
    private var conversation: Conversation { app.conversation }

    private func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if condition { passed += 1 } else { failures.append(name + (detail().isEmpty ? "" : ": \(detail())")) }
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

    /// Types into whatever has focus in the panel, then presses Return, all as real events.
    private func type(_ text: String) async {
        for char in text {
            panel.sendEvent(key(0, String(char)))
        }
        await pause(0.05)
        panel.sendEvent(key(36, "\r"))
    }

    /// A real mouse drag on the grabber at the bottom center of the card, in small steps.
    private func drag(by distance: CGFloat, hold: Bool = false) async {
        await pause(0.7)  // let the window settle to the card's size
        let cardWidth = model.isCompact ? PanelMetrics.compactWidth : PanelMetrics.cardWidth
        let start = NSPoint(x: panel.frame.width - PanelMetrics.edgeGap - cardWidth / 2, y: app.panel.cardRect.minY + 6)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        panel.sendEvent(mouse(.leftMouseDown, start))
        let steps = 12
        for step in 1...steps {
            await pause(0.016)
            // Window coordinates grow upward, so a pull down lowers y.
            panel.sendEvent(mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - distance * CGFloat(step) / CGFloat(steps))))
        }
        if hold {
            // Stop before letting go, so the release carries no speed.
            await pause(0.2)
            panel.sendEvent(mouse(.leftMouseDragged, NSPoint(x: start.x, y: start.y - distance)))
        }
        await pause(0.05)
        panel.sendEvent(mouse(.leftMouseUp, NSPoint(x: start.x, y: start.y - distance)))
    }

    private func shot(_ name: String) async {
        await pause(0.1)
        let url = outFolder.appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // A region, not the window alone, so the shadow and the desktop around the card show.
        let window = panel.frame
        let card = app.panel.cardRect
        // The card and its shadow, in screen coordinates.
        let f = NSRect(x: window.minX, y: window.minY + max(0, card.minY - PanelMetrics.bottom),
                       width: window.width, height: min(window.height, card.height + PanelMetrics.top + PanelMetrics.bottom))
        let screenTop = NSScreen.screens.first?.frame.maxY ?? f.maxY
        process.arguments = ["-x", "-R\(Int(f.minX)),\(Int(screenTop - f.maxY)),\(Int(f.width)),\(Int(f.height))", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    /// A real mouse click (or a drag of `dragX` points) at a point in window coordinates. Selectable
    /// text runs its own tracking loop on mouse down and waits for the rest in the event queue, so
    /// every event is queued up front instead of sent one by one. The real pointer goes to where the
    /// mouse comes up, since the bubble reads the pointer to tell a click from a drag.
    private func click(at point: NSPoint, dragX: CGFloat = 0) async {
        let end = panel.convertPoint(toScreen: NSPoint(x: point.x + dragX, y: point.y))
        CGWarpMouseCursorPosition(CGPoint(x: end.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - end.y))
        await pause(0.05)
        let start = ProcessInfo.processInfo.systemUptime
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ step: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: start + Double(step) * 0.016,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(mouse(.leftMouseDown, point, 0), atStart: false)
        let steps = dragX == 0 ? 0 : 8
        for step in stride(from: 1, through: steps, by: 1) {
            NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: point.x + dragX * CGFloat(step) / 8, y: point.y), step), atStart: false)
        }
        NSApp.postEvent(mouse(.leftMouseUp, NSPoint(x: point.x + dragX, y: point.y), steps + 1), atStart: false)
        await pause(0.2)
    }

    /// Records a region of the screen to a movie for `seconds`, in the background.
    private func record(_ name: String, seconds: Int) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        let window = panel.frame
        let screenTop = NSScreen.screens.first?.frame.maxY ?? window.maxY
        // The top 260 points of the window: the field and its growth.
        process.arguments = ["-x", "-v", "-V", "\(seconds)", "-R\(Int(window.minX)),\(Int(screenTop - window.maxY)),\(Int(window.width)),260",
                             outFolder.appendingPathComponent("\(name).mov").path]
        try? process.run()
        return process
    }

    /// Types a question that wraps to a second line, key by key at typing speed, while recording, and
    /// logs when the card's height changes (the wrap) relative to the recording's start.
    private func recordWrap(_ name: String, gap: Double) async {
        let text = "Could you tell me what the weather looks like in Helsinki this weekend and whether I should pack a raincoat for the ferry"
        let recording = record(name, seconds: Int(ceil(Double(text.count) * (gap + 0.012))) + 2)
        await pause(1)
        let start = Date()
        var height = app.panel.cardRect.height
        print("probe: \(name) typing at \(String(format: "%.3f", Date().timeIntervalSince(start) + 1))s")
        for char in text {
            panel.sendEvent(key(0, String(char)))
            await pause(gap)
            if abs(app.panel.cardRect.height - height) > 0.5 {
                print("probe: \(name) height \(height) -> \(app.panel.cardRect.height) at \(String(format: "%.3f", Date().timeIntervalSince(start) + 1))s after \(model.input.count) chars")
                height = app.panel.cardRect.height
            }
        }
        recording.waitUntilExit()
        check(model.input == text, "typing fills the field (\(name))", model.input)
        check(app.panel.cardRect.height > 60, "the field grows to two lines (\(name))", "\(app.panel.cardRect.height)")
        await shot(name)
        model.input = ""
        await pause(0.4)
    }

    private var textFieldHasFocus: Bool {
        (panel.firstResponder as? NSTextView)?.isFieldEditor == true || panel.firstResponder is NSTextView
    }

    /// `--probe out worst`: the break-ui pass. Worst-case questions and answers through the fake
    /// claude, screenshots of each, and timings for the big one. Reports; it does not judge looks.
    private func runWorst() async {
        _ = await until(8) { conversation.spareProcessID != nil }
        app.panel.show()
        _ = await until(1) { panel.isVisible }
        let paste = "Can you check whether the enterprise renewal for Northwind Industries Holdings (contract NW-2026-0001284, owner Aleksandra Wiśniewska-Kowalczyk, 1,284 seats) went through, what the final MRR was after the mid-term seat true-up, whether Bartholomew Fitzgerald-Montgomery III countersigned, and whether finance sent the invoice from https://northwind-industries-holdings.example.com/billing/invoices/INV-2026-000128400-enterprise-annual-renewal-final?view=pdf yet, and if not who owns the next step"
        for (name, question) in [("worst-text", "\(paste) worst text"), ("worst-empty", "worst empty"), ("worst-text2", "\(paste) worst text"), ("worst-empty2", "worst empty"), ("worst-blank", "worst blank"), ("worst-error", "worst error")] {
            _ = panel.performKeyEquivalent(with: key(45, "n", .command))
            await pause(0.3)
            model.input = question
            await pause(0.2)
            await type("")
            let started = Date()
            _ = await until(15) { !conversation.isRunning }
            print("probe: \(name) took \(String(format: "%.2f", Date().timeIntervalSince(started)))s, status \(String(describing: conversation.turns.last?.status)), answer \(conversation.turns.last?.answer.count ?? 0) chars")
            await pause(0.8)
            print("probe: \(name) shown=\(model.shown) visible=\(panel.isVisible) frame=\(panel.frame) visibleTurns=\(model.visibleTurns.count) compact=\(model.isCompact)")
            await shot("worst-\(name)")
            if name == "worst-empty" {
                let full = Process()
                full.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                full.arguments = ["-x", outFolder.appendingPathComponent("worst-empty-full.png").path]
                try? full.run(); full.waitUntilExit()
                print("probe: hosting frame \(panel.contentView?.frame ?? .zero) fitting \(panel.contentView?.fittingSize ?? .zero)")
            }
        }
        // The big answer: 100 paragraphs and a 150 item list in 6 character chunks, like a fast stream.
        _ = panel.performKeyEquivalent(with: key(45, "n", .command))
        await type("worst big")
        let started = Date()
        var longestGap = 0.0
        var last = Date()
        var stalls: [String] = []
        while Date().timeIntervalSince(started) < 120 {
            let wasRunning = conversation.isRunning
            try? await Task.sleep(for: .milliseconds(16))
            let gap = Date().timeIntervalSince(last) - 0.016
            longestGap = max(longestGap, gap)
            if gap > 0.08 { stalls.append("\(Int(gap * 1000))ms@\(conversation.turns.last?.answer.count ?? 0)\(wasRunning ? "" : "-done")") }
            last = Date()
            if !wasRunning && !conversation.isRunning { break }
        }
        print("probe: worst-big stalls over 80 ms: \(stalls.joined(separator: " "))")
        print("probe: worst-big took \(String(format: "%.2f", Date().timeIntervalSince(started)))s for \(conversation.turns.last?.answer.count ?? 0) chars, longest main-thread stall \(String(format: "%.0f", longestGap * 1000)) ms")
        await pause(0.8)
        await shot("worst-big")
        // A day of questions: 40 turns, then pull the history open.
        _ = panel.performKeyEquivalent(with: key(45, "n", .command))
        for i in 0..<40 {
            await type("question number \(i) of the day")
            _ = await until(5) { !conversation.isRunning }
        }
        let t0 = Date()
        app.panel.hide()
        _ = await until(2) { !panel.isVisible }
        app.panel.show()
        _ = await until(2) { panel.isVisible }
        print("probe: 40 turns, reopen took \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        await pause(0.8)
        await shot("worst-40-turns")
        // A 3,000 character paste into the field.
        model.input = String(repeating: paste + " ", count: 7)
        await pause(0.6)
        await shot("worst-input-paste")
        model.input = ""
        passed += 1
    }

    private func run() async {
        _ = await until(8) { conversation.spareProcessID != nil }
        check(conversation.spareProcessID != nil, "a spare claude starts at launch")

        // Open from the background, like the hotkey does while another app is in front.
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
        await pause(0.5)
        print("probe: before show active=\(NSApp.isActive)")
        app.panel.show()
        check(await until(1) { panel.isVisible && panel.isKeyWindow }, "the panel opens as the key window")
        check(await until(1) { textFieldHasFocus }, "the text field has focus", "\(String(describing: panel.firstResponder))")
        if let screen = panel.screen {
            check(abs(panel.frame.maxX - screen.visibleFrame.maxX) < 1 && abs(panel.frame.maxY - screen.visibleFrame.maxY) < 1,
                  "the panel sits at the top right", "\(panel.frame) in \(screen.visibleFrame)")
        }
        print("probe: after show active=\(NSApp.isActive) key=\(panel.isKeyWindow) keyWindow=\(String(describing: NSApp.keyWindow))")
        await pause(0.7)
        await shot("1-empty")
        let emptyHeight = app.panel.cardRect.height
        check(model.isCompact, "the empty field is the compact, half-width card")
        model.input = "a question that needs the full width please"
        check(!model.isCompact, "longer text widens the card")
        await pause(0.5)
        await shot("1b-widened")
        model.input = ""
        await pause(0.3)

        // Outside the card the window lets clicks through; over it, it takes them.
        let outside = panel.convertPoint(toScreen: NSPoint(x: 10, y: 10))
        CGWarpMouseCursorPosition(CGPoint(x: outside.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - outside.y))
        await pause(0.1)
        app.panel.refreshPointer()
        check(panel.ignoresMouseEvents, "clicks below the card pass through to the app underneath")
        let over = panel.convertPoint(toScreen: NSPoint(x: app.panel.cardRect.midX, y: app.panel.cardRect.midY))
        CGWarpMouseCursorPosition(CGPoint(x: over.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - over.y))
        await pause(0.1)
        app.panel.refreshPointer()
        check(!panel.ignoresMouseEvents, "the card itself takes clicks")

        // Typing until the field wraps to a second line, recorded in both appearances (plan 010 row 7).
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            await pause(0.3)
            let name = appearance == .aqua ? "wrap-light" : "wrap-dark"
            await recordWrap(name, gap: 0.03)
            await recordWrap(name + "-fast", gap: 0.008)
        }
        NSApp.appearance = nil
        await pause(0.3)

        // Ask through real key events.
        await type("hello")
        check(conversation.isRunning || conversation.turns.last?.status == .done, "Return sends the question")
        check(model.input.isEmpty, "the field clears on send")
        check(await until(5) { conversation.turns.last?.status == .done }, "the echo answer arrives")
        check(conversation.turns.last?.answer == "Echo: hello (turn 1)", "the answer text", conversation.turns.last?.answer ?? "nil")
        await pause(0.6)
        check(app.panel.cardRect.height > emptyHeight + 40, "the card grows for the answer", "\(emptyHeight) -> \(app.panel.cardRect.height)")
        check(abs(app.panel.cardRect.maxY - (panel.frame.height - PanelMetrics.top)) < 1, "the card hangs from the top of the window", "\(app.panel.cardRect)")
        await shot("2-answer")

        // A follow-up with a tool call, and a long markdown answer.
        await type("use a tool")
        var sawActivity = false
        _ = await until(5) {
            sawActivity = sawActivity || conversation.turns.last?.activity != nil
            if sawActivity && conversation.turns.last?.answer.isEmpty == true { return true }
            return conversation.turns.last?.status == .done
        }
        if sawActivity { await shot("3-tool-activity") }
        check(sawActivity, "the tool activity shows")
        check(await until(5) { conversation.turns.last?.status == .done }, "the tool answer arrives")
        await type("long answer please")
        check(await until(5) { conversation.turns.last?.status == .done }, "the long answer arrives")
        await pause(0.7)
        await shot("4-long")
        if let screen = panel.screen {
            check(panel.frame.height <= screen.visibleFrame.height, "the panel never outgrows the screen")
        }

        // Paste works without a main menu.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("pasted text", forType: .string)
        _ = panel.performKeyEquivalent(with: key(9, "v", .command))
        check(await until(1) { model.input == "pasted text" }, "⌘V pastes into the field", model.input)
        _ = panel.performKeyEquivalent(with: key(0, "a", .command))
        panel.sendEvent(key(51, "\u{7F}"))
        check(await until(1) { model.input.isEmpty }, "⌘A then Delete clears the field", model.input)

        // Esc puts it away; the conversation stays.
        panel.sendEvent(key(53, "\u{1B}"))
        check(await until(1.5) { !panel.isVisible }, "Esc hides the panel")
        check(await until(1) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" },
              "Esc gives the keyboard back to the app that had it", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")
        check(!model.shown, "the card is out")
        app.panel.show()
        check(await until(1) { panel.isVisible && model.shown && panel.isKeyWindow }, "it opens again as the key window", "key \(panel.isKeyWindow)")
        check(conversation.turns.count == 3, "the conversation is still there", "\(conversation.turns.count)")

        // ⌘N starts over.
        _ = panel.performKeyEquivalent(with: key(45, "n", .command))
        check(conversation.turns.isEmpty, "⌘N clears the conversation")
        check(textFieldHasFocus, "⌘N keeps the cursor in the field")

        // Hidden while running: the answer brings the panel back without taking the keyboard.
        await type("slow answer")
        await pause(0.4)
        panel.sendEvent(key(53, "\u{1B}"))
        check(await until(1.5) { !panel.isVisible }, "Esc hides it while an answer runs")
        check(await until(8) { panel.isVisible && model.shown }, "the finished answer brings it back")
        check(!panel.isKeyWindow, "it comes back without taking the keyboard")
        await pause(0.6)
        await shot("5-returned")

        // A click in another app puts it away when idle, but not while an answer runs.
        await type("slow again")
        await pause(0.2)
        app.panel.clickedOutside()
        await pause(0.4)
        check(panel.isVisible, "a click elsewhere does not hide it while running")
        conversation.stop()
        check(await until(3) { !conversation.isRunning }, "⌘. stops the answer")
        check(conversation.turns.last?.status == .stopped, "the turn shows as stopped")
        await shot("6-stopped")
        app.panel.clickedOutside()
        check(await until(1.5) { !panel.isVisible }, "a click elsewhere hides it when idle")

        // One continuous session: it survives being put away, until Reset.
        await pause(0.5)
        app.panel.show()
        check(await until(1) { panel.isVisible }, "it opens after a pause")
        check(conversation.turns.count == 2, "the session is still there after a pause", "\(conversation.turns.count)")

        // After a quiet spell it opens as the empty field; the history is kept and a pull shows it.
        model.idleCollapseAfter = 0.3
        app.panel.hide()
        _ = await until(1.5) { !panel.isVisible }
        await pause(0.5)
        app.panel.show()
        check(await until(1) { panel.isVisible }, "it opens after the quiet spell")
        check(model.visibleTurns.isEmpty && conversation.turns.count == 2, "quiet spell: empty field, history kept", "visible \(model.visibleTurns.count) of \(conversation.turns.count)")
        check(model.isCompact, "quiet spell: compact card")
        await pause(0.8)
        await shot("10-collapsed")
        await drag(by: 90)
        check(await until(1) { model.historyOpen }, "a real drag down on the grabber shows the history")
        await pause(0.8)
        await shot("11-pulled-open")
        await drag(by: -90)
        check(await until(1) { model.visibleTurns.isEmpty }, "a real drag up tucks it away")
        await drag(by: 18, hold: true)
        await pause(0.5)
        check(model.visibleTurns.isEmpty, "a short pull springs back shut")
        // The keyboard does what the grabber does.
        let down = key(125, "\u{F701}", [.command, .numericPad, .function])
        check(panel.performKeyEquivalent(with: down), "⌘↓ is taken while turns are hidden")
        check(await until(1) { model.historyOpen && model.visibleTurns.count == 2 }, "⌘↓ shows the earlier questions", "visible \(model.visibleTurns.count)")
        await pause(0.6)
        await shot("12-history-key")
        check(panel.performKeyEquivalent(with: key(126, "\u{F700}", [.command, .numericPad, .function])), "⌘↑ is taken while history shows")
        check(await until(1) { model.visibleTurns.isEmpty }, "⌘↑ tucks the earlier questions away")
        check(!panel.performKeyEquivalent(with: key(126, "\u{F700}", [.command, .numericPad, .function])), "⌘↑ with nothing shown goes to the field")
        await pause(0.5)
        await type("new after collapse")
        check(await until(5) { !conversation.isRunning }, "a question after a collapse ends")
        check(model.visibleTurns.count == 1 && conversation.turns.count == 3, "only the new turn shows; the session keeps all", "\(model.visibleTurns.count) of \(conversation.turns.count)")
        check(conversation.turns.last?.answer == "Echo: new after collapse (turn 3)", "the session still remembers", conversation.turns.last?.answer ?? "nil")
        model.idleCollapseAfter = IdleCollapse.defaultAfter
        _ = panel.performKeyEquivalent(with: key(45, "n", .command))

        // An empty or blank answer says so instead of showing nothing.
        for kind in ["empty", "blank"] {
            await type("worst \(kind)")
            check(await until(5) { !conversation.isRunning }, "a \(kind) answer ends")
            let last = conversation.turns.last
            check(last?.status == .done && TurnView.isBlank(last?.answer ?? "x"), "the \(kind) answer is done and blank", String(describing: last?.answer))
            check(await until(1) { TurnView.noAnswerLabels == 1 }, "a \(kind) answer shows \"No answer came back.\"")
            await pause(0.5)
            await shot("13-no-answer-\(kind)")
            _ = panel.performKeyEquivalent(with: key(45, "n", .command))
            check(await until(1) { TurnView.noAnswerLabels == 0 }, "after ⌘N the \(kind) label is gone")
        }

        // A long question is cut; a click on the bubble shows it whole, a second click cuts it again.
        let question = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 14)
        await type(question)
        check(await until(5) { conversation.turns.last?.status == .done }, "the 600 character question is answered")
        await pause(0.8)
        let cut = app.panel.cardRect.height
        let bubble = NSPoint(x: app.panel.cardRect.maxX - 18 - 80, y: app.panel.cardRect.maxY - 16 - 14)
        await shot("14-question-cut")
        await click(at: bubble, dragX: -120)
        await pause(0.6)
        check(abs(app.panel.cardRect.height - cut) < 1, "selecting text in the bubble does not expand it", "\(cut) -> \(app.panel.cardRect.height)")
        await click(at: bubble)
        check(await until(1.5) { app.panel.cardRect.height > cut + 20 }, "a click on a cut question expands it", "\(cut) -> \(app.panel.cardRect.height)")
        await pause(0.6)
        let whole = app.panel.cardRect.height
        await shot("15-question-whole")
        await click(at: bubble)
        check(await until(1.5) { abs(app.panel.cardRect.height - cut) < 1 }, "a second click cuts it again", "\(whole) -> \(app.panel.cardRect.height)")
        _ = panel.performKeyEquivalent(with: key(45, "n", .command))

        // Errors read clearly; dark mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await type("this will fail")
        check(await until(5) { !conversation.isRunning }, "a failing turn ends")
        await pause(0.5)
        await shot("7-error-dark")
        await type("use a tool in the dark")
        _ = await until(5) { !conversation.isRunning }
        await type("long dark")
        _ = await until(5) { !conversation.isRunning }
        await pause(0.7)
        await shot("8-long-dark")

        // Every markdown form, in both appearances.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let name = appearance == .aqua ? "light" : "dark"
            _ = panel.performKeyEquivalent(with: key(45, "n", .command))
            await type("kitchen one")
            check(await until(5) { !conversation.isRunning }, "kitchen one ends (\(name))")
            await pause(0.8)
            await shot("9-markdown-one-\(name)")
            _ = panel.performKeyEquivalent(with: key(45, "n", .command))
            await type("kitchen two")
            check(await until(5) { !conversation.isRunning }, "kitchen two ends (\(name))")
            await pause(0.8)
            await shot("9-markdown-two-\(name)")
        }

        // Reduced motion: no slide, still opens and closes.
        model.reduceMotion = true
        app.panel.hide()
        check(await until(1) { !panel.isVisible }, "hides with reduced motion")
        app.panel.show()
        check(await until(1) { panel.isVisible && panel.isKeyWindow }, "opens with reduced motion as the key window", "key \(panel.isKeyWindow)")
        model.reduceMotion = false

        // The hotkey path: toggle hides a key panel, and shows a hidden one.
        print("probe: before toggle active=\(NSApp.isActive) key=\(panel.isKeyWindow) visible=\(panel.isVisible) keyWindow=\(String(describing: NSApp.keyWindow))")
        app.panel.toggle()
        check(await until(1.5) { !panel.isVisible }, "toggle hides the open panel")
        app.panel.toggle()
        check(await until(1) { panel.isVisible && panel.isKeyWindow }, "toggle opens it again")
        // Rapid toggles must end in a sane state (interrupting the slide both ways).
        for _ in 0..<5 { app.panel.toggle(); await pause(0.06) }
        await pause(1)
        check(panel.isVisible == model.shown, "rapid toggles leave window and card in agreement", "visible \(panel.isVisible) shown \(model.shown)")
    }
}
