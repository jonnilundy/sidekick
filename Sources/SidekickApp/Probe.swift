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
        app = AppDelegate(defaults: defaults, isProbe: true)
        app.applicationDidFinishLaunching(notification)
        Task {
            await run()
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

    private func shot(_ name: String) async {
        await pause(0.1)
        let url = outFolder.appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // A region, not the window alone, so the glass shows what is behind it.
        let f = panel.frame
        let screenTop = NSScreen.screens.first?.frame.maxY ?? f.maxY
        process.arguments = ["-x", "-R\(Int(f.minX)),\(Int(screenTop - f.maxY)),\(Int(f.width)),\(Int(f.height))", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private var textFieldHasFocus: Bool {
        (panel.firstResponder as? NSTextView)?.isFieldEditor == true || panel.firstResponder is NSTextView
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
        let emptyHeight = panel.frame.height

        // Ask through real key events.
        await type("hello")
        check(conversation.isRunning || conversation.turns.last?.status == .done, "Return sends the question")
        check(model.input.isEmpty, "the field clears on send")
        check(await until(5) { conversation.turns.last?.status == .done }, "the echo answer arrives")
        check(conversation.turns.last?.answer == "Echo: hello (turn 1)", "the answer text", conversation.turns.last?.answer ?? "nil")
        await pause(0.6)
        check(panel.frame.height > emptyHeight + 40, "the panel grows for the answer", "\(emptyHeight) -> \(panel.frame.height)")
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
