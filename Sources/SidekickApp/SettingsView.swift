import AppKit
import KeyboardShortcuts
import SwiftUI
import SidekickCore

/// Five settings, nothing else. Every change applies to the next question.
struct SettingsView: View {
    let defaults: UserDefaults
    @AppStorage(Preferences.Key.folder) private var folder = Preferences.defaultFolder()
    @AppStorage(Preferences.Key.model) private var model = ""
    @AppStorage(Preferences.Key.effort) private var effort = "low"
    @AppStorage(Preferences.Key.keepWarm) private var keepWarm = true
    @AppStorage(Preferences.Key.dailyReset) private var dailyReset = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginNote: String?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        _folder = AppStorage(wrappedValue: Preferences.defaultFolder(), Preferences.Key.folder, store: defaults)
        _model = AppStorage(wrappedValue: "", Preferences.Key.model, store: defaults)
        _effort = AppStorage(wrappedValue: "low", Preferences.Key.effort, store: defaults)
        _keepWarm = AppStorage(wrappedValue: true, Preferences.Key.keepWarm, store: defaults)
        _dailyReset = AppStorage(wrappedValue: true, Preferences.Key.dailyReset, store: defaults)
    }

    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("Shortcut", name: .togglePanel)

            LabeledContent("Folder") {
                HStack {
                    Text((folder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                }
            }

            Picker("Model", selection: $model) {
                ForEach(Preferences.models, id: \.id) { Text($0.label).tag($0.id) }
            }
            Picker("Effort", selection: $effort) {
                ForEach(Preferences.efforts, id: \.id) { Text($0.label).tag($0.id) }
            }

            Toggle(isOn: $dailyReset) {
                Text("Start fresh every day at 5 AM")
                Text("One session runs all day. Reset (⌘N) clears it any time.")
            }

            Toggle(isOn: $keepWarm) {
                Text("Keep Claude ready")
                Text("One claude process waits in the background, so answers start about two seconds sooner.")
            }

            Toggle("Open at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        let status = try LaunchAtLogin.setEnabled(on)
                        loginNote = status == .requiresApproval ? "Approve Sidekick in System Settings > General > Login Items." : nil
                    } catch {
                        loginNote = error.localizedDescription
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }
            if let loginNote {
                Text(loginNote).font(.callout).foregroundStyle(.secondary)
            }

            Text("Sidekick \(SidekickVersion) runs your claude command with your own settings, skills and connectors. Conversations are never saved.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.allowsMultipleSelection = false
        open.directoryURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        open.prompt = "Use Folder"
        if open.runModal() == .OK, let url = open.url {
            folder = url.path
        }
    }
}
