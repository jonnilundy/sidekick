import AppKit
import KeyboardShortcuts
import SwiftUI
import SidekickCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let defaults: UserDefaults
    let conversation: Conversation
    let model: PanelModel
    let panel: PanelController
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var environment: [String: String]
    private var warmTimer: Timer?
    private let log = Logger(subsystem: SidekickBundleID, category: "app")
    /// Probe runs skip the status item, the hotkey and login items.
    let isProbe: Bool

    init(defaults: UserDefaults = .standard, isProbe: Bool = false) {
        self.defaults = defaults
        self.isProbe = isProbe
        Preferences.register(defaults)
        // Until the login shell answers, use the app's own environment with the usual tool folders.
        let base = ShellEnvironment.withFallbackPath(ProcessInfo.processInfo.environment)
        environment = base
        var current: [String: String] = base
        let defaults = defaults
        let conversation = Conversation(makeConfig: { Preferences.config(defaults: defaults, environment: current) })
        self.conversation = conversation
        model = PanelModel(conversation: conversation)
        panel = PanelController(model: model)
        super.init()
        loadShellEnvironment { env in current = env }
    }

    /// Reads the login shell's environment off the main thread, then starts the spare claude with it.
    private func loadShellEnvironment(_ apply: @escaping @MainActor ([String: String]) -> Void) {
        let base = ProcessInfo.processInfo.environment
        DispatchQueue.global(qos: .userInitiated).async {
            let env = ShellEnvironment.load(base: base)
            let fallback = ShellEnvironment.lastFallbackReason
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let fallback { self.log.error("login shell environment not loaded: \(fallback, privacy: .public)") }
                    self.environment = env
                    apply(env)
                    self.conversation.setKeepWarm(self.defaults.bool(forKey: Preferences.Key.keepWarm))
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        conversation.keepWarm = defaults.bool(forKey: Preferences.Key.keepWarm)
        conversation.onTurnEnded = { [weak self] in self?.panel.turnEnded() }
        conversation.onModel = { [defaults] id in defaults.set(id, forKey: Preferences.Key.lastModel) }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.dailyResetEnabled = { [defaults] in defaults.bool(forKey: Preferences.Key.dailyReset) }
        model.dailyResetEnabled = panel.dailyResetEnabled
        panel.onVisibilityChange = { [weak self] visible in self?.updateStatusIcon(visible: visible) }
        model.shortcutHint = KeyboardShortcuts.getShortcut(for: .togglePanel)?.description ?? "Your shortcut"

        guard !isProbe else { return }
        setUpStatusItem()
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in self?.panel.toggle() }
        // Keep the spare fresh: replace it when it gets old or settings changed.
        warmTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.isVisible else { return }
                if self.defaults.bool(forKey: Preferences.Key.dailyReset), self.conversation.resetIfDue() { self.model.resetVisibility(); return }
                self.conversation.prewarm()
            }
        }
        defaults.addObserver(self, forKeyPath: Preferences.Key.keepWarm, context: nil)

        if !defaults.bool(forKey: Preferences.Key.didFirstRun) {
            defaults.set(true, forKey: Preferences.Key.didFirstRun)
            // Only from an installed copy: a first run from Downloads or a disk image would register
            // the wrong path. The Settings toggle shows the real state either way.
            let path = Bundle.main.bundlePath
            if !LaunchAtLogin.isEnabled, path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") {
                do { try LaunchAtLogin.setEnabled(true) } catch { log.error("open at login failed: \(error.localizedDescription, privacy: .public)") }
            }
            model.showWelcome = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.panel.show() }
        }
        log.notice("Sidekick \(SidekickVersion, privacy: .public) started")
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // KVO can arrive on any thread (a `defaults write` from Terminal), so hop to main first.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.conversation.setKeepWarm(self.defaults.bool(forKey: Preferences.Key.keepWarm))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        conversation.shutdown()
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusImage(active: false)
        item.button?.setAccessibilityLabel("Sidekick")
        item.button?.toolTip = "Sidekick"
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func statusImage(active: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sidekick")
        image?.isTemplate = true
        return image?.withSymbolConfiguration(.init(pointSize: 14, weight: active ? .bold : .medium))
    }

    private func updateStatusIcon(visible: Bool) {
        statusItem?.button?.image = statusImage(active: visible)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let shortcut = KeyboardShortcuts.getShortcut(for: .togglePanel)?.description
        menu.addItem(withTitle: shortcut.map { "Ask  \($0)" } ?? "Ask", action: #selector(askFromMenu), keyEquivalent: "").target = self
        let newItem = menu.addItem(withTitle: "Reset Session", action: #selector(newFromMenu), keyEquivalent: "")
        newItem.target = self
        newItem.isEnabled = !conversation.isEmpty
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sidekick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func askFromMenu() { panel.show() }
    @objc private func newFromMenu() { panel.newConversation(); panel.show() }
    @objc private func settingsFromMenu() { openSettings() }

    // MARK: Settings

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(defaults: defaults)))
            window.title = "Sidekick Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        panel.hide()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
