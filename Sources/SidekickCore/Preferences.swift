import Foundation

/// The few settings Sidekick has. Stored in UserDefaults; tests pass their own suite.
public struct Preferences: Sendable {
    public enum Key {
        public static let folder = "folder"
        public static let model = "model"
        public static let effort = "effort"
        public static let keepWarm = "keepWarm"
        public static let dailyReset = "dailyReset"
        public static let didFirstRun = "didFirstRun"
        public static let lastModel = "lastModel"
    }

    /// The folder claude runs in. Default: ~/Workbench/work when it exists, else the home folder.
    public static func defaultFolder(home: String = NSHomeDirectory()) -> String {
        let work = "\(home)/Workbench/work"
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: work, isDirectory: &isDir) && isDir.boolValue ? work : home
    }

    /// Models offered in Settings. The ids are Claude Code's aliases, which always point at the newest
    /// model of each family, so a new release needs no update here. Empty is "your Claude Code default".
    public static let models: [(id: String, label: String)] = [
        ("", "Claude Code default"), ("haiku", "Haiku, newest (fastest)"), ("sonnet", "Sonnet, newest"),
        ("opus", "Opus, newest"), ("fable", "Fable, newest"),
    ]
    public static let efforts: [(id: String, label: String)] = [
        ("low", "Low (fastest)"), ("medium", "Medium"), ("high", "High"), ("", "Claude Code default"),
    ]

    public static func register(_ defaults: UserDefaults) {
        defaults.register(defaults: [
            Key.folder: defaultFolder(),
            Key.model: "",
            Key.effort: "low",
            Key.keepWarm: true,
            Key.dailyReset: true,
        ])
    }

    /// Builds the claude config from the settings, or says what is missing.
    public static func config(defaults: UserDefaults, environment: [String: String]) -> Result<ClaudeConfig, Conversation.SetupError> {
        guard let claude = ClaudeLocator.find(environment: environment) else {
            return .failure(.init("Sidekick could not find the claude command. Install Claude Code (claude.com/claude-code) and log in once in Terminal, then ask again."))
        }
        let folder = (defaults.string(forKey: Key.folder) ?? defaultFolder()) as NSString
        let path = folder.expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .failure(.init("The folder \(path) does not exist. Pick another one in Settings."))
        }
        return .success(ClaudeConfig(
            executable: claude,
            workingDirectory: URL(fileURLWithPath: path),
            model: defaults.string(forKey: Key.model) ?? "",
            effort: defaults.string(forKey: Key.effort) ?? "low",
            environment: environment
        ))
    }
}
