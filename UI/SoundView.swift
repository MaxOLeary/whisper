import AppKit
import SwiftUI

// MARK: - Sound page

struct SoundView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        PageScaffold(title: "Sound") {
            SettingsGroup(title: "Sounds") {
                SettingsRow(title: "Sounds") {
                    Toggle("", isOn: Binding(
                        get: { store.sounds },
                        set: { store.save(["sounds": $0]) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                SettingsDivider()
                SettingsRow(title: "Start sound") {
                    soundPicker(value: store.startSound, key: "startSound")
                }
                SettingsDivider()
                SettingsRow(title: "Stop sound") {
                    soundPicker(value: store.stopSound, key: "stopSound")
                }
            }
            SettingsGroup(title: "Music") {
                SettingsRow(title: "While dictating",
                            subtitle: "Turns the speakers down so music stays out of the take. Skipped with wired headphones and in meetings.") {
                    Picker("", selection: Binding(
                        get: { store.musicDuringTake },
                        set: { store.save(["musicDuringTake": $0]) }
                    )) {
                        Text("Keep playing").tag("off")
                        Text("Lower").tag("lower")
                        Text("Mute").tag("mute")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
        }
        .onAppear { store.refresh() }
    }

    private func soundPicker(value: String, key: String) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { value },
                set: { store.save([key: $0]) }
            )) {
                Text("None").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            Button {
                store.playSound(value)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .disabled(value.isEmpty)
            .help("Play")
        }
    }

    /// System sounds plus whatever config.json already names, so a hand-typed
    /// name still shows up in the picker.
    private var names: [String] {
        var n = Self.systemSounds
        for extra in [store.startSound, store.stopSound] where !extra.isEmpty && !n.contains(extra) {
            n.append(extra)
        }
        return n.sorted()
    }

    static let systemSounds: [String] = {
        let dir = "/System/Library/Sounds"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let found = files.compactMap { name -> String? in
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext == "aiff" || ext == "aif" || ext == "caf" else { return nil }
            return (name as NSString).deletingPathExtension
        }
        if !found.isEmpty { return found.sorted() }
        return ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
                "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    }()
}
