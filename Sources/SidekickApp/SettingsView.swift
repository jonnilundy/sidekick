import AppKit
import KeyboardShortcuts
import SwiftUI
import SidekickCore

/// A few settings, nothing else. A change to folder, model or effort starts a new session at the
/// next question (the panel says so).
struct SettingsView: View {
    let defaults: UserDefaults
    @AppStorage(Preferences.Key.folder) private var folder = Preferences.defaultFolder()
    @AppStorage(Preferences.Key.model) private var model = ""
    @AppStorage(Preferences.Key.effort) private var effort = "low"
    @AppStorage(Preferences.Key.keepWarm) private var keepWarm = true
    @AppStorage(Preferences.Key.dailyReset) private var dailyReset = true
    @AppStorage(Preferences.Key.lastModel) private var lastModel = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginNote: String?

    let updater: Updater?

    init(defaults: UserDefaults, updater: Updater? = nil) {
        self.defaults = defaults
        self.updater = updater
        _folder = AppStorage(wrappedValue: Preferences.defaultFolder(), Preferences.Key.folder, store: defaults)
        _model = AppStorage(wrappedValue: "", Preferences.Key.model, store: defaults)
        _effort = AppStorage(wrappedValue: "low", Preferences.Key.effort, store: defaults)
        _keepWarm = AppStorage(wrappedValue: true, Preferences.Key.keepWarm, store: defaults)
        _dailyReset = AppStorage(wrappedValue: true, Preferences.Key.dailyReset, store: defaults)
        _lastModel = AppStorage(wrappedValue: "", Preferences.Key.lastModel, store: defaults)
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

            Picker(selection: $model) {
                ForEach(Preferences.models, id: \.id) { Text($0.label).tag($0.id) }
            } label: {
                Text("Model")
                if !lastModel.isEmpty {
                    Text("Last answer came from \(ModelName.display(lastModel)).")
                }
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

            UpdateRows(updater: updater)

            Text("Sidekick runs your claude command with your own settings, skills and connectors. Conversations are never saved.")
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

/// The version, Check Now with the last check, and the automatic check toggle.
struct UpdateRows: View {
    let updater: Updater?
    @State private var automatic: Bool

    init(updater: Updater?) {
        self.updater = updater
        _automatic = State(initialValue: updater?.automaticallyChecks ?? false)
    }

    var body: some View {
        let (version, build) = Updater.bundleVersion
        if let updater, updater.state.running {
            let state = updater.state
            LabeledContent {
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(state.checking)
            } label: {
                Text(UpdateRules.versionLabel(version: version, build: build))
                Text(UpdateRules.lastCheckLabel(date: state.lastCheck, result: state.lastResult, checking: state.checking))
            }
            Toggle("Check for updates automatically", isOn: $automatic)
                .onChange(of: automatic) { _, on in updater.automaticallyChecks = on }
        } else {
            LabeledContent {
                EmptyView()
            } label: {
                Text(UpdateRules.versionLabel(version: version, build: build))
                Text(updater?.state.lastResult.isEmpty == false ? updater!.state.lastResult : "Updates are off in this build")
            }
        }
    }
}
