import AppKit
import SwiftUI

// MARK: - Store: the one bridge between the AppKit brain and the SwiftUI window

/// `App` (main.swift) writes to this on the main thread; views only read it
/// and call back through the closures. Keeps SwiftUI out of the pipeline.
final class AppStore: ObservableObject {
    enum HotkeyCapture { case record, cleanup }

    @Published var state: RecordState = .idle
    @Published var page: Page = .home
    @Published var micName = "System default"
    @Published var micSymbol = "laptopcomputer"
    @Published var recordHotkey = "alt+space"
    @Published var cleanupHotkey = "cmd+alt+shift+space"
    @Published var audioDevice = ""
    @Published var mics: [String] = []
    @Published var language = "en"
    @Published var minSeconds = 0.35
    @Published var cleanupPrompt = ""
    @Published var sounds = true
    @Published var startSound = "Tink"
    @Published var stopSound = "Pop"
    @Published var musicDuringTake = "off"
    @Published var launchAtLogin = false
    @Published var engineName = "parakeet"
    @Published var modelMissing = false
    @Published var hotkeyCapture: HotkeyCapture? = nil
    @Published var history: [Transcript] = []
    @Published var stats: [Stats.Take] = []

    var toggleRecording: () -> Void = {}
    var save: ([String: Any]) -> Void = { _ in }
    var refresh: () -> Void = {}
    var captureHotkey: (HotkeyCapture) -> Void = { _ in }
    var openItem: (String) -> Void = { _ in }
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
    var downloadModel: () -> Void = {}
    var playSound: (String) -> Void = { _ in }
}

enum Page: String, CaseIterable, Identifiable, Hashable {
    case home, configuration, sound, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .configuration: "Configuration"
        case .sound: "Sound"
        case .history: "History"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .configuration: "gearshape.fill"
        case .sound: "speaker.wave.2.fill"
        case .history: "clock.arrow.circlepath"
        }
    }
    /// Icon tile color, matching the screenshot: orange house, gray gears and
    /// speaker, purple history.
    var tint: Color {
        switch self {
        case .home: Color(red: 0.98, green: 0.45, blue: 0.20)
        case .configuration, .sound: Color(white: 0.42)
        case .history: Color(red: 0.55, green: 0.40, blue: 0.95)
        }
    }
}

// MARK: - Window

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: AppStore
    /// Whoever was in front when the window opened. Opening the window makes
    /// Whisper the active app, and paste() posts ⌘V to the active app, so on
    /// close we hand focus straight back or every later take would paste
    /// into our own window.
    private var previousApp: NSRunningApplication?

    init(store: AppStore) {
        self.store = store
        let host = NSHostingController(rootView: SettingsRoot().environmentObject(store))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.title = "Whisper"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.zoomButton)?.isHidden = true   // red + yellow only, like the screenshot
        w.setContentSize(NSSize(width: 900, height: 620))
        w.minSize = NSSize(width: 720, height: 480)
        w.center()
        w.setFrameAutosaveName("SettingsWindow")
        super.init(window: w)
        w.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        store.hotkeyCapture = nil
        if let prev = previousApp, prev.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            prev.activate()
        }
        previousApp = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// App that was in front when this window opened, if it is still not us.
    /// Used as the stats `app` when Whisper itself is frontmost at paste time.
    func recordedAppName() -> String {
        guard let prev = previousApp,
              prev.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return "" }
        return prev.localizedName ?? prev.bundleIdentifier ?? ""
    }

    /// Bring the window up on a page. Accessory apps are not "active", so
    /// activate first or the window comes up behind whatever is focused.
    func show(page: Page) {
        store.page = page
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root: sidebar + page

struct SettingsRoot: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 260)
        } detail: {
            page(store.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .toolbar {
                    micToolbar
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private func page(_ p: Page) -> some View {
        switch p {
        case .home: HomeView()
        case .configuration: ConfigurationView()
        case .sound: SoundView()
        case .history: HistoryView()
        }
    }

    /// System toolbar glass is a fixed-height clip. Hide it and draw a capsule
    /// that sizes to the mic name, or "MacBook Air Microphone" gets its caps cut.
    @ToolbarContentBuilder
    private var micToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) {
                MicChip(name: store.micName, symbol: store.micSymbol)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) {
                MicChip(name: store.micName, symbol: store.micSymbol)
            }
        }
    }
}

/// Mic name + glyph in a capsule that hugs the text, used in the toolbar.
private struct MicChip: View {
    let name: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .lineLimit(1)
            Image(systemName: symbol)
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(MicChipBackground())
    }
}

private struct MicChipBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        List(selection: $store.page) {
            Section {
                row(.home)
            }
            Section {
                row(.configuration)
                row(.sound)
            }
            Section {
                row(.history)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private func row(_ p: Page) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(p.tint)
                    .frame(width: 28, height: 28)
                Image(systemName: p.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(p.title)
                .font(.system(size: 15, weight: .medium))
        }
        .padding(.vertical, 5)
        .tag(p)
    }

    /// "Whisper  1.0" pill at the bottom, where the screenshot has its name + PRO.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Whisper")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(App.version)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

// MARK: - Shared chrome (pages live in UI/*View.swift)

/// Shared page frame: title row where the screenshot has "All time ⌃" /
/// search, then the content column with the same 28pt gutters.
struct PageScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                content()
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

/// Titled rounded card used by Configuration and Sound.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct SettingsDivider: View {
    var body: some View {
        Divider().padding(.leading, 14)
    }
}
