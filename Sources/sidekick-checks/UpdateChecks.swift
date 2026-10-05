// Checks for the Sparkle setup that need no window: the update rules, the Info.plist keys, the
// appcast in the repo, scripts/appcast-add.sh and release.sh's refusals.
import Foundation
import SidekickCore

/// Runs a script and returns its exit code with stdout and stderr together.
private func run(_ path: String, _ args: [String], in folder: URL) -> (code: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    process.currentDirectoryURL = folder
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The items of an appcast, newest first, as (shortVersion, build, enclosure attributes, notes).
private func appcastItems(_ url: URL) -> [(version: String, build: String, enclosure: [String: String], notes: String)]? {
    guard let doc = try? XMLDocument(contentsOf: url), let items = try? doc.nodes(forXPath: "/rss/channel/item") else { return nil }
    return items.compactMap { node in
        guard let item = node as? XMLElement else { return nil }
        func text(_ name: String) -> String { item.elements(forName: name).first?.stringValue ?? "" }
        var enclosure: [String: String] = [:]
        for attribute in item.elements(forName: "enclosure").first?.attributes ?? [] {
            enclosure[attribute.name ?? ""] = attribute.stringValue ?? ""
        }
        return (text("sparkle:shortVersionString"), text("sparkle:version"), enclosure, text("description"))
    }
}

@MainActor
func updateChecks(root: URL) {
    let key = Data(repeating: 7, count: 32).base64EncodedString()
    check(UpdateRules.hasPublicKey(key), "a 32 byte base64 key starts the updater")
    check(!UpdateRules.hasPublicKey(UpdateRules.placeholderKey), "the placeholder keeps the updater off")
    check(!UpdateRules.hasPublicKey(nil) && !UpdateRules.hasPublicKey(""), "no key keeps the updater off")
    check(!UpdateRules.hasPublicKey(Data(repeating: 7, count: 31).base64EncodedString()), "a 31 byte key keeps the updater off")
    check(!UpdateRules.hasPublicKey("not a key!"), "not base64 keeps the updater off")
    check(UpdateRules.isRelease(bundleID: "com.jonnilundy.sidekick") && !UpdateRules.isRelease(bundleID: "com.jonnilundy.sidekick.test"), "only the release bundle id is the release app")
    check(UpdateRules.menuTitle(version: "0.2.1", ready: false) == "Update to Sidekick 0.2.1…", "menu title for a found update opens a window")
    check(UpdateRules.menuTitle(version: "0.2.1", ready: true) == "Install Sidekick 0.2.1 and Relaunch", "menu title for a downloaded update relaunches")
    check(UpdateRules.versionLabel(version: "0.2.1", build: "3") == "Sidekick 0.2.1 (3)", "version label")
    check(UpdateRules.versionLabel(version: "3", build: "3") == "Sidekick 3", "version label without a separate build")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    check(UpdateRules.lastCheckLabel(date: nil, result: "", now: now) == "Never checked", "never checked")
    check(UpdateRules.lastCheckLabel(date: nil, result: "Updates are off in this build", now: now) == "Updates are off in this build", "no check shows why")
    check(UpdateRules.lastCheckLabel(date: now.addingTimeInterval(-5), result: "Up to date", now: now) == "Checked just now: Up to date", "checked just now")
    check(UpdateRules.lastCheckLabel(date: nil, result: "Up to date", checking: true, now: now) == "Checking for updates…", "checking shows while a check runs")
    check(UpdateRules.lastCheckLabel(date: now.addingTimeInterval(-7200), result: "", now: now).hasPrefix("Checked 2 hours ago"), "checked hours ago")

    // Info.plist: the feed, a key Sparkle can use (or the placeholder), and no window on a found update.
    let plistURL = root.appendingPathComponent("Resources/Info.plist")
    let plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)) as? [String: Any] ?? [:]
    check(plist["SUFeedURL"] as? String == UpdateRules.feedURL, "Info.plist points at the appcast on main", "\(plist["SUFeedURL"] ?? "nil")")
    let publicKey = plist["SUPublicEDKey"] as? String
    check(publicKey == UpdateRules.placeholderKey || UpdateRules.hasPublicKey(publicKey), "SUPublicEDKey is the placeholder or a real key", publicKey ?? "nil")
    check(plist["SUAutomaticallyUpdate"] as? Bool == false, "updates never download on their own by default")
    check(plist["SUEnableAutomaticChecks"] as? Bool == true && plist["SUScheduledCheckInterval"] as? Int == 86400, "automatic checks every 24 hours, no permission prompt")

    let repoAppcast = root.appendingPathComponent("appcast.xml")
    check(appcastItems(repoAppcast) != nil, "appcast.xml in the repo parses")

    // appcast-add.sh on a temp appcast: two releases, newest first, notes without the Install part.
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-appcast-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let zip = tmp.appendingPathComponent("Sidekick-0.3.0.zip")
    FileManager.default.createFile(atPath: zip.path, contents: Data(repeating: 1, count: 1234))
    let notes = tmp.appendingPathComponent("notes.md")
    try? Data("## New\n\n- Faster ]]> answers\n\n## Install\n\nDownload the zip.\n".utf8).write(to: notes)
    let appcast = tmp.appendingPathComponent("appcast.xml")
    let script = root.appendingPathComponent("scripts/appcast-add.sh").path
    let first = run(script, [appcast.path, "0.2.0", "2", zip.path, "SIG2", "https://x.test/Sidekick-0.2.0.zip"], in: root)
    let second = run(script, [appcast.path, "0.3.0", "3", zip.path, "SIG3", "https://x.test/Sidekick-0.3.0.zip", notes.path], in: root)
    check(first.code == 0 && second.code == 0, "appcast-add.sh adds two releases", first.output + second.output)
    let items = appcastItems(appcast) ?? []
    check(items.map(\.version) == ["0.3.0", "0.2.0"] && items.map(\.build) == ["3", "2"], "the newest release comes first", "\(items.map(\.version))")
    if let newest = items.first {
        check(newest.enclosure["url"] == "https://x.test/Sidekick-0.3.0.zip" && newest.enclosure["length"] == "1234"
              && newest.enclosure["sparkle:edSignature"] == "SIG3", "the enclosure has the url, length and signature", "\(newest.enclosure)")
        check(newest.notes == "## New\n\n- Faster ]]> answers", "notes keep \"]]>\" and drop the Install section", newest.notes.debugDescription)
    }
    check(items.last?.notes == "Sidekick 0.2.0.", "no notes file gives a one line description")
    let missing = run(script, [appcast.path, "0.4.0", "4", tmp.appendingPathComponent("nope.zip").path, "S", "u"], in: root)
    check(missing.code != 0 && (appcastItems(appcast)?.count ?? 0) == 2, "a missing zip changes nothing", missing.output)

    // release.sh refuses before it changes anything.
    let release = root.appendingPathComponent("scripts/release.sh").path
    let badVersion = run(release, ["1.2"], in: root)
    check(badVersion.code != 0 && badVersion.output.contains("must look like 1.2.3"), "release.sh refuses a bad version", badVersion.output)
    if publicKey == UpdateRules.placeholderKey {
        let placeholder = run(release, ["9.9.9"], in: root)
        check(placeholder.code != 0 && placeholder.output.contains("still the placeholder"), "release.sh refuses while the key is the placeholder", placeholder.output)
    }
}
