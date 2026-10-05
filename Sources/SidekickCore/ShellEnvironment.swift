import Foundation

/// The environment of the user's login shell. An app started from Finder or at login does not get
/// PATH, tokens or anything else from .zshrc, but Claude Code's hooks and MCP servers need them.
/// So read them once from `$SHELL -lic` and give them to every claude process.
public enum ShellEnvironment {
    static let marker = "__SIDEKICK_ENV_START__"

    /// Runs the login shell and returns its environment merged over `base`. Falls back to `base` with a
    /// sane PATH when the shell fails or takes longer than `timeout`.
    public static func load(base: [String: String] = ProcessInfo.processInfo.environment,
                            timeout: TimeInterval = 6) -> [String: String] {
        let shell = base["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "printf '%s\\0' \(marker); /usr/bin/env -0"]
        process.environment = base
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let reader = DispatchQueue(label: "sidekick.shellenv")
        let done = DispatchSemaphore(value: 0)
        reader.async {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        do { try process.run() } catch { return withFallbackPath(base) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return withFallbackPath(base)
        }
        process.waitUntilExit()
        let parsed = parse(box.data)
        guard !parsed.isEmpty else { return withFallbackPath(base) }
        return withFallbackPath(base.merging(parsed) { _, shell in shell })
    }

    /// The `env -0` output after the marker, as a dictionary. Anything the shell printed first is ignored.
    public static func parse(_ data: Data) -> [String: String] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard let start = fields.firstIndex(where: { String(decoding: $0, as: UTF8.self).hasSuffix(marker) }) else { return [:] }
        var env: [String: String] = [:]
        for field in fields[(start + 1)...] {
            let entry = String(decoding: field, as: UTF8.self)
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        // Shell bookkeeping that should not leak into child processes.
        for key in ["SHLVL", "_", "OLDPWD", "PWD"] { env.removeValue(forKey: key) }
        return env
    }

    /// Makes sure the usual tool folders are on PATH, so `node`, `python3` and `claude` resolve.
    public static func withFallbackPath(_ env: [String: String], home: String = NSHomeDirectory()) -> [String: String] {
        var env = env
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        where !parts.contains(dir) {
            parts.append(dir)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }
}
