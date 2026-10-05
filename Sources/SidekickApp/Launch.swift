import AppKit
import SidekickCore

/// The entry point. `Sidekick` runs the app; `Sidekick --probe <out-folder>` runs the in-process
/// window test (VM only: it opens the panel and takes the keyboard). `Sidekick --demo <out-folder>`
/// plays the README demo at a human pace (VM only, see scripts/vm-demo.sh).
public enum Launch {
    @MainActor
    public static func run() {
        // Writing to a claude that just exited must not end the app.
        signal(SIGPIPE, SIG_IGN)
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
        if let index = args.firstIndex(of: "--demo") {
            let out = index + 1 < args.count ? args[index + 1] : "out"
            let demo = Demo(outFolder: URL(fileURLWithPath: out))
            app.delegate = demo
            withExtendedLifetime(demo) { app.run() }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
