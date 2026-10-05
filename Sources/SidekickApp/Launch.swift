import AppKit
import SidekickCore

/// The entry point. `Sidekick` runs the app; `Sidekick --probe <out-folder>` runs the in-process
/// window test (VM only: it opens the panel and takes the keyboard).
public enum Launch {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--probe") {
            let out = index + 1 < args.count ? args[index + 1] : "out"
            let probe = Probe(outFolder: URL(fileURLWithPath: out))
            app.delegate = probe
            withExtendedLifetime(probe) { app.run() }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
