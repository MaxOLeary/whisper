import AppKit
import SwiftUI

// MARK: - Home: range picker, stat tiles, Get started

struct HomeView: View {
    @EnvironmentObject var store: AppStore
    @State private var range: Stats.Range = .all

    private var snap: Stats.Snapshot {
        Stats.snapshot(stats: store.stats, history: store.history, range: range)
    }

    private var isTranscribing: Bool {
        if case .transcribing = store.state { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                rangeMenu
                tiles
                getStarted
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .onAppear { store.refresh() }
    }

    /// Title is the range picker, same slot Configuration uses for "Configuration".
    private var rangeMenu: some View {
        Menu {
            ForEach(Stats.Range.allCases, id: \.self) { r in
                Button(r.title) { range = r }
            }
        } label: {
            HStack(spacing: 6) {
                Text(range.title)
                    .font(.system(size: 20, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.leading, -8)
    }

    private var tiles: some View {
        let s = snap
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                   GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(title: "Average speed", value: "\(s.averageSpeed)", unit: "wpm",
                     symbol: "bolt.fill", tint: Color(red: 0.98, green: 0.45, blue: 0.20))
            StatTile(title: "Words", value: s.words.formatted(), unit: nil,
                     symbol: "text.alignleft", tint: Color(red: 0.20, green: 0.55, blue: 0.95))
            StatTile(title: "Apps used", value: "\(s.appsUsed)", unit: nil,
                     symbol: "square.grid.2x2.fill", tint: Color(red: 0.55, green: 0.40, blue: 0.95))
            StatTile(title: "Time saved", value: Stats.formatTimeSaved(minutes: s.timeSavedMinutes), unit: nil,
                     symbol: "clock.fill", tint: Color(red: 0.20, green: 0.70, blue: 0.45))
        }
    }

    private var getStarted: some View {
        SettingsGroup(title: "Get started") {
            Button {
                store.toggleRecording()
            } label: {
                GetStartedRow(title: "Start recording", symbol: "mic.fill", tint: Page.home.tint) {
                    KeycapsView(hotkey: store.recordHotkey)
                }
            }
            .buttonStyle(.plain)
            .disabled(isTranscribing)
            SettingsDivider()
            navRow("Customize your shortcuts", page: .configuration)
            SettingsDivider()
            navRow("Pick your sounds", page: .sound)
            SettingsDivider()
            navRow("Browse your history", page: .history)
        }
    }

    private func navRow(_ title: String, page: Page) -> some View {
        Button { store.page = page } label: {
            GetStartedRow(title: title, symbol: page.symbol, tint: page.tint) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String?
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint)
                        .frame(width: 28, height: 28)
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                if let unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ClearGlass(radius: 14))
    }
}

struct GetStartedRow<Trailing: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder var trailing: () -> Trailing
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(tint)
                    .frame(width: 28, height: 28)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(hover ? Color.primary.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}
