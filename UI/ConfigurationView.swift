import AppKit
import SwiftUI

// MARK: - Configuration page

struct ConfigurationView: View {
    @EnvironmentObject var store: AppStore
    @State private var prompt = ""
    @State private var promptReady = false

    var body: some View {
        PageScaffold(title: "Configuration") {
            shortcuts
            micAndLanguage
            cleanup
            files
            launch
            if store.engineName == "whisper" && store.modelMissing {
                download
            }
        }
        .onAppear {
            prompt = store.cleanupPrompt
            promptReady = true
            store.refresh()
        }
        .onDisappear { store.hotkeyCapture = nil }
        .onChange(of: store.cleanupPrompt) { _, new in
            if promptReady, new != prompt { prompt = new }
        }
        .onChange(of: prompt) { _, new in
            if promptReady, new != store.cleanupPrompt {
                store.save(["cleanupPrompt": new])
            }
        }
    }

    private var shortcuts: some View {
        SettingsGroup(title: "Shortcuts") {
            SettingsRow(title: "Record") {
                HotkeyRecorder(field: .record, hotkey: store.recordHotkey)
            }
            SettingsDivider()
            SettingsRow(title: "Cleanup") {
                HotkeyRecorder(field: .cleanup, hotkey: store.cleanupHotkey)
            }
        }
    }

    private var micAndLanguage: some View {
        SettingsGroup(title: "Input") {
            SettingsRow(title: "Microphone") {
                Picker("", selection: micBinding) {
                    Text("System default").tag("")
                    ForEach(micOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            SettingsDivider()
            SettingsRow(title: "Language") {
                Picker("", selection: langBinding) {
                    ForEach(Self.languages, id: \.code) { Text($0.label).tag($0.code) }
                    if !Self.languages.contains(where: { $0.code == store.language }) {
                        Text(store.language).tag(store.language)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            SettingsDivider()
            SettingsRow(title: "Ignore taps shorter than") {
                Stepper(value: minBinding, in: 0...5, step: 0.05) {
                    Text(String(format: "%.2f s", store.minSeconds))
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
        }
    }

    private var cleanup: some View {
        SettingsGroup(title: "Cleanup prompt") {
            TextEditor(text: $prompt)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(10)
        }
    }

    private var files: some View {
        SettingsGroup(title: "Files") {
            fileRow("replacements.txt", "replacements")
            SettingsDivider()
            fileRow(".env", "env")
            SettingsDivider()
            fileRow("Config folder", "configDir")
            SettingsDivider()
            fileRow("Dictation folder", "dictation")
        }
    }

    private func fileRow(_ title: String, _ id: String) -> some View {
        SettingsRow(title: title) {
            Button("Open") { store.openItem(id) }
        }
    }

    private var launch: some View {
        SettingsGroup(title: "General") {
            SettingsRow(title: "Launch at login") {
                Toggle("", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { store.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private var download: some View {
        SettingsGroup(title: "Whisper fallback") {
            SettingsRow(title: "Model file missing", subtitle: "About 150 MB, one time.") {
                Button("Download") { store.downloadModel() }
            }
        }
    }

    /// Include the configured name even if that device is unplugged, so the
    /// Picker never has a selection with no tag (that resets to System default
    /// and saves over audioDevice).
    private var micOptions: [String] {
        var m = store.mics
        let a = store.audioDevice.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty, a != "0", !m.contains(a) { m.append(a) }
        return m
    }

    private var micBinding: Binding<String> {
        Binding(
            get: {
                let a = store.audioDevice.trimmingCharacters(in: .whitespaces)
                return (a.isEmpty || a == "0") ? "" : a
            },
            set: { store.save(["audioDevice": $0]) }
        )
    }

    private var langBinding: Binding<String> {
        Binding(
            get: { store.language },
            set: { store.save(["language": $0]) }
        )
    }

    private var minBinding: Binding<Double> {
        Binding(
            get: { store.minSeconds },
            set: { store.save(["minSeconds": ($0 * 100).rounded() / 100]) }
        )
    }

    static let languages: [(label: String, code: String)] = [
        ("Auto", "auto"),
        ("English", "en"),
        ("Spanish", "es"),
        ("French", "fr"),
        ("German", "de"),
        ("Italian", "it"),
        ("Portuguese", "pt"),
        ("Dutch", "nl"),
        ("Japanese", "ja"),
        ("Chinese", "zh"),
        ("Korean", "ko"),
        ("Russian", "ru"),
    ]
}

/// Click to capture the next chord. Esc cancels. Keycaps match the History empty state.
struct HotkeyRecorder: View {
    @EnvironmentObject var store: AppStore
    let field: AppStore.HotkeyCapture
    let hotkey: String

    private var capturing: Bool { store.hotkeyCapture == field }

    var body: some View {
        Button { store.captureHotkey(field) } label: {
            HStack(spacing: 6) {
                if capturing {
                    Text("Press shortcut")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("esc")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ClearGlass(radius: 5))
                } else {
                    KeycapsView(hotkey: hotkey)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(capturing ? Color.accentColor : Color.primary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help(capturing ? "Press a shortcut, or Escape to cancel" : "Click to change")
    }
}

struct KeycapsView: View {
    let hotkey: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(History.keycaps(hotkey).split(separator: " ").map(String.init), id: \.self) { cap in
                Text(cap)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(ClearGlass(radius: 5))
            }
        }
    }
}
