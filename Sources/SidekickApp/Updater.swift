import AppKit
import Observation
import Sparkle
import SidekickCore
import os

/// What the updater knows right now. Background checks only change this; they never show a
/// window or activate the app. The status item menu, its badge and Settings read it.
@Observable
@MainActor
final class UpdateState {
    struct Available: Equatable {
        /// The display version, "0.2.1".
        var version: String
        /// CFBundleVersion of the update, "3".
        var build: String
        /// Downloaded and extracted: installing needs no window, the app relaunches at once.
        var ready: Bool
    }

    nonisolated static let resultKey = "updateLastResult"

    /// Nil when there is nothing to install.
    var available: Available? {
        didSet { if available != oldValue { onAvailableChange?() } }
    }
    /// False when this build has no public key, or Sparkle could not start.
    var running = false
    var checking = false
    var lastCheck: Date?
    /// "Up to date", "Found 0.2.1", "Failed: ...". Kept across relaunches.
    var lastResult: String = UserDefaults.standard.string(forKey: UpdateState.resultKey) ?? "" {
        didSet { UserDefaults.standard.set(lastResult, forKey: UpdateState.resultKey) }
    }
    /// The menu bar badge follows this.
    @ObservationIgnored var onAvailableChange: (() -> Void)?
}

/// Sparkle 2 with the standard user driver and gentle scheduled reminders.
///
/// - Scheduled checks (15 s after launch when one is due, then every 24 hours) never show
///   Sparkle's window: `standardUserDriverShouldHandleShowingScheduledUpdate` returns false, and a
///   found update only lands in `state`, which puts a dot on the menu bar icon and an item at the
///   top of its menu.
/// - Picking that item, Check for Updates… or Check Now shows Sparkle's window: release notes,
///   Install Update, download progress, Install and Relaunch.
/// - When the user turned on automatic downloads in that window, Sparkle downloads in the
///   background and hands over an install block; the menu item then installs and relaunches at once.
/// - A build whose `SUPublicEDKey` is still the placeholder never starts the updater.
@MainActor
final class Updater: NSObject {
    /// The running app's updater. Nil in probe runs.
    private(set) static var shared: Updater?

    let state = UpdateState()
    private let log = Logger(subsystem: SidekickBundleID, category: "updater")
    private var controller: SPUStandardUpdaterController!
    /// From `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)`: installs the
    /// downloaded update and relaunches without any UI.
    private var installNow: (() -> Void)?
    private var testObservers: [any NSObjectProtocol] = []

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater { controller.updater }

    /// The bundle's own version, "0.1.0", and build, "1".
    static var bundleVersion: (version: String, build: String) {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? SidekickVersion,
                info["CFBundleVersion"] as? String ?? String(SidekickBuild))
    }

    func start() {
        Updater.shared = self
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard UpdateRules.hasPublicKey(key) else {
            log.notice("updates off: SUPublicEDKey is not a real key in this build")
            state.lastResult = "Updates are off in this build"
            return
        }
        do {
            // Not the controller's startUpdater(): on an error that one shows a modal alert.
            try updater.start()
        } catch {
            log.error("sparkle did not start: \(error.localizedDescription, privacy: .public)")
            state.lastResult = "Off: \(error.localizedDescription)"
            return
        }
        state.running = true
        state.lastCheck = updater.lastUpdateCheckDate
        let (version, build) = Updater.bundleVersion
        log.notice("sparkle up for \(version, privacy: .public) build \(build, privacy: .public), feed \(self.updater.feedURL?.absoluteString ?? "none", privacy: .public), automatic checks \(self.updater.automaticallyChecksForUpdates, privacy: .public) every \(Int(self.updater.updateCheckInterval), privacy: .public)s, automatic downloads \(self.updater.automaticallyDownloadsUpdates, privacy: .public)")

        if CommandLine.arguments.contains("--check-for-updates") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkForUpdates() }
        }
        listenForTestHooks()
    }

    // MARK: Actions for the menu and Settings

    var canCheck: Bool { state.running && updater.canCheckForUpdates }

    /// Check for Updates… and Check Now. Sparkle's window shows the result.
    func checkForUpdates() {
        guard state.running else { return }
        log.notice("user initiated update check")
        state.checking = true
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// The update item in the menu. A downloaded update installs and relaunches now; one that is
    /// only found comes up in Sparkle's window for the user to confirm.
    func installUpdate() {
        guard state.running else { return }
        if let installNow {
            log.notice("installing \(self.state.available?.version ?? "?", privacy: .public) now, relaunch follows")
            state.lastResult = "Installing \(state.available?.version ?? "update")"
            installNow()
        } else {
            log.notice("showing the found update in Sparkle's window")
            NSApp.activate()
            controller.checkForUpdates(nil)
        }
    }

    var automaticallyChecks: Bool {
        get { state.running && updater.automaticallyChecksForUpdates }
        set {
            guard state.running else { return }
            updater.automaticallyChecksForUpdates = newValue
            log.notice("automatic update checks \(newValue ? "on" : "off", privacy: .public)")
        }
    }

    /// Test copies only (any bundle id but the release one), never the release app:
    /// - `<bundle id>.install-update` runs `installUpdate()`, the menu item's code path, so an end
    ///   to end test installs without clicking.
    /// - `<bundle id>.dump-update-state` logs `state`, so a test can see the badge's source of truth.
    private func listenForTestHooks() {
        guard let id = Bundle.main.bundleIdentifier, !UpdateRules.isRelease(bundleID: id) else { return }
        let center = DistributedNotificationCenter.default()
        let install = Notification.Name(id + ".install-update")
        testObservers.append(center.addObserver(forName: install, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.notice("test hook: install-update received")
                self?.installUpdate()
            }
        })
        let dump = Notification.Name(id + ".dump-update-state")
        testObservers.append(center.addObserver(forName: dump, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let available = self.state.available.map { "\($0.version) build \($0.build) ready \($0.ready)" } ?? "none"
                // The menu bar icon's own window (NSStatusBarWindow, "Item-0") is always there; leave it out.
                let windows = NSApp.windows.filter { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") }
                    .map(\.title).filter { !$0.isEmpty }
                self.log.notice("test hook: state available \(available, privacy: .public), result \(self.state.lastResult, privacy: .public), visible windows \(windows, privacy: .public), active \(NSApp.isActive, privacy: .public)")
            }
        })
        log.notice("test hook: listening for \(install.rawValue, privacy: .public) and \(dump.rawValue, privacy: .public)")
    }

    private func found(_ item: SUAppcastItem, ready: Bool) {
        state.available = UpdateState.Available(version: item.displayVersionString, build: item.versionString, ready: ready)
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.notice("found \(item.displayVersionString, privacy: .public) build \(item.versionString, privacy: .public)")
        found(item, ready: installNow != nil && state.available?.build == item.versionString)
        state.lastResult = "Found \(item.displayVersionString)"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        log.notice("no update: \((error as NSError).localizedDescription, privacy: .public)")
        if installNow == nil { state.available = nil }
        state.lastResult = "Up to date"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        log.notice("\(item.displayVersionString, privacy: .public) downloaded and ready, installs on quit or from the menu")
        installNow = immediateInstallHandler
        found(item, ready: true)
        state.lastResult = "Ready to install \(item.displayVersionString)"
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let error = error as NSError
        guard error.code != Int(SUError.noUpdateError.rawValue) else { return }
        log.error("update aborted: \(error.localizedDescription, privacy: .public) (\(error.code, privacy: .public))")
        state.lastResult = "Failed: \(error.localizedDescription)"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        state.checking = false
        state.lastCheck = updater.lastUpdateCheckDate
        log.notice("update cycle done (\(updateCheck == .updates ? "user" : "background", privacy: .public))")
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        log.notice("user chose \(choice.rawValue, privacy: .public) for \(updateItem.displayVersionString, privacy: .public)")
        if choice == .skip { self.state.available = nil }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        log.notice("relaunching into the new version")
    }
}

extension Updater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled updates are ours to show, and we show them only as the badge and the menu item.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        log.notice("gentle reminder: \(update.displayVersionString, privacy: .public) (stage \(state.stage.rawValue, privacy: .public)), no window")
        found(update, ready: installNow != nil)
        self.state.lastResult = "Found \(update.displayVersionString)"
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Dismissed or skipped in Sparkle's window: drop the reminder unless a download waits.
        if installNow == nil { state.available = nil }
        state.checking = false
    }
}
