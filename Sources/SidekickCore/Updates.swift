import Foundation

/// Rules for the Sparkle updater that do not need Sparkle: when the updater may start, and the
/// words the menu and Settings show.
public enum UpdateRules {
    /// The value Info.plist carries until the release key exists. The updater stays off with it.
    public static let placeholderKey = "REPLACE-WITH-PUBLIC-KEY"
    /// The appcast. release.sh adds an item per release; GitHub serves the file from main.
    public static let feedURL = "https://raw.githubusercontent.com/jonnilundy/sidekick/main/appcast.xml"

    /// An EdDSA public key Sparkle can use: base64 for exactly 32 bytes. The placeholder, an empty
    /// value or anything else keeps the updater off, so a build without a key never shows
    /// Sparkle's "updater failed to start" alert.
    public static func hasPublicKey(_ value: String?) -> Bool {
        guard let value, value != placeholderKey,
              let data = Data(base64Encoded: value.trimmingCharacters(in: .whitespaces)) else { return false }
        return data.count == 32
    }

    /// The release app. Test copies (any other bundle id) also listen for the test notifications.
    public static func isRelease(bundleID: String?) -> Bool {
        bundleID == SidekickBundleID
    }

    /// The menu item for a found update. A downloaded one installs and relaunches at once with no
    /// window; one that is only found opens Sparkle's window, hence the ellipsis.
    public static func menuTitle(version: String, ready: Bool) -> String {
        ready ? "Install Sidekick \(version) and Relaunch" : "Update to Sidekick \(version)…"
    }

    /// The version line in Settings: "Sidekick 0.2.1 (3)", the version alone when the build is the same.
    public static func versionLabel(version: String, build: String) -> String {
        version == build || build.isEmpty ? "Sidekick \(version)" : "Sidekick \(version) (\(build))"
    }

    /// The last check line in Settings.
    public static func lastCheckLabel(date: Date?, result: String, checking: Bool = false, now: Date = Date()) -> String {
        if checking { return "Checking for updates…" }
        guard let date else { return result.isEmpty ? "Never checked" : result }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let when = now.timeIntervalSince(date) < 60 ? "just now" : formatter.localizedString(for: date, relativeTo: now)
        return result.isEmpty ? "Checked \(when)" : "Checked \(when): \(result)"
    }
}
