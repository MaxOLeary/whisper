import AppKit
import SwiftUI

// MARK: - Store: the one bridge between the AppKit brain and the SwiftUI window

/// `App` (main.swift) writes to this on the main thread; views only read it
/// and call back through the closures. Keeps SwiftUI out of the pipeline.
final class AppStore: ObservableObject {
    enum HotkeyCapture { case record, cleanup, pasteLast }

    @Published var state: RecordState = .idle
    @Published var page: Page = .home
    @Published var micName = "System default"
    @Published var micSymbol = "laptopcomputer"
    @Published var recordHotkey = "alt+space"
    @Published var cleanupHotkey = "cmd+alt+shift+space"
    @Published var pasteLastHotkey = "ropt+p"
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

/// AppKit puts the traffic lights in the window corner after every layout.
/// This window puts them back inside the sidebar plate, off the fillet.
final class SettingsChromeWindow: NSWindow {
    private var placing = false

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        guard !placing else { return }
        placing = true
        insetTrafficLights()
        placing = false
    }

    func insetTrafficLights() {
        guard let close = standardWindowButton(.closeButton),
              let mini = standardWindowButton(.miniaturizeButton),
              let box = close.superview else { return }
        standardWindowButton(.zoomButton)?.isHidden = true
        let left: CGFloat = 28
        let top: CGFloat = 20
        let gap: CGFloat = 8
        let y = box.bounds.height - top - close.frame.height
        let closeAt = NSPoint(x: left, y: y)
        let miniAt = NSPoint(x: left + close.frame.width + gap, y: y)
        if abs(close.frame.origin.x - closeAt.x) > 0.5 || abs(close.frame.origin.y - closeAt.y) > 0.5 {
            close.setFrameOrigin(closeAt)
        }
        if abs(mini.frame.origin.x - miniAt.x) > 0.5 || abs(mini.frame.origin.y - miniAt.y) > 0.5 {
            mini.setFrameOrigin(miniAt)
        }
    }
}

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
        // The host stays the content view. A glass container around it lifts
        // the plates over the type and the lens smears every label.
        let w = SettingsChromeWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.title = ""
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.toolbarStyle = .unified
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.titlebarSeparatorStyle = .none
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.zoomButton)?.isHidden = true   // red + yellow only, like the screenshot
        w.setContentSize(NSSize(width: 900, height: 620))
        w.minSize = NSSize(width: 720, height: 480)
        w.center()
        w.setFrameAutosaveName("SettingsWindow")
        super.init(window: w)
        w.delegate = self
        // No full-window plate. A plate is an edge, and the point is that the
        // desktop shows through between the floating pieces.
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
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
    func rememberedApp() -> NSRunningApplication? {
        guard let prev = previousApp,
              prev.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return prev
    }

    /// Used as the stats `app` when Whisper itself is frontmost at paste time.
    func recordedAppName() -> String {
        guard let prev = rememberedApp() else { return "" }
        return prev.localizedName ?? prev.bundleIdentifier ?? ""
    }

    /// Bring the window up on a page. Accessory apps are not "active", so
    /// activate first or the window comes up behind whatever is focused.
    func show(page: Page) {
        store.page = page
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        (window as? SettingsChromeWindow)?.insetTrafficLights()
    }
}

// MARK: - Root: sidebar + page

struct SettingsRoot: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Sidebar()
                .frame(width: 220)
                .frame(maxHeight: .infinity)
            page(store.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(ClearGlass(radius: 22))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 10)
        .ignoresSafeArea()
        .font(WhisperType.text(14))
        .toolbar { micToolbar }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
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
        .font(WhisperType.text(14))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            GeometryReader { geo in
                ClearGlass(radius: geo.size.height / 2)
            }
        }
    }
}

/// Libron for the words you read. Small captions stay the system face.
enum WhisperType {
    static func text(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Libron-Bold" : "Libron-Regular", size: size)
    }
}

/// The card's plate, as a SwiftUI background. Content stays a sibling, so the
/// glass does not bend the text. A little frost and grain, still clear.
struct ClearGlass: NSViewRepresentable {
    var radius: CGFloat
    var tint: NSColor = WhisperGlass.settingsTint
    var grain: CGFloat = 0.22
    var frost: CGFloat = 0.09
    var wash: NSColor? = nil
    var rimAlpha: CGFloat = 1
    var regular: Bool = false

    func makeNSView(context: Context) -> LiquidGlassPlate {
        let plate = LiquidGlassPlate(frame: .zero)
        plate.setCornerRadius(radius)
        plate.setFinish(grain: grain, frost: frost, tint: tint, wash: wash, rimAlpha: rimAlpha, regular: regular)
        return plate
    }

    func updateNSView(_ plate: LiquidGlassPlate, context: Context) {
        plate.setCornerRadius(radius)
        plate.setFinish(grain: grain, frost: frost, tint: tint, wash: wash, rimAlpha: rimAlpha, regular: regular)
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: AppStore
    @State private var hover: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 40)
            row(.home)
            row(.configuration)
            row(.sound)
            row(.history)
            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ClearGlass(radius: 22))
    }

    private func row(_ p: Page) -> some View {
        let on = store.page == p
        return Button {
            store.page = p
        } label: {
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
                    .font(WhisperType.text(16))
                    .foregroundStyle(on ? Color.white : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? Color.accentColor : (hover == p ? Color.white.opacity(0.06) : Color.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in hover = inside ? p : (hover == p ? nil : hover) }
    }

    /// "Whisper  1.0" pill at the bottom, where the screenshot has its name + PRO.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Whisper")
                .font(WhisperType.text(16, bold: true))
                .foregroundStyle(.secondary)
            Text(App.version)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

/// Finds the enclosing scroll view and swaps in the glass knob.
private struct GlassScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> GlassScrollerInstallerView { GlassScrollerInstallerView() }
    func updateNSView(_ view: GlassScrollerInstallerView, context: Context) { view.install() }
}

private final class GlassScrollerInstallerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
    }

    func install() {
        guard let scroll = enclosingScrollView else { return }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if scroll.autohidesScrollers { scroll.autohidesScrollers = false }
        scroll.hasHorizontalScroller = false
        if !(scroll.verticalScroller is GlassScroller) {
            scroll.verticalScroller = GlassScroller(frame: scroll.verticalScroller?.frame ?? .zero)
        }
    }
}

/// Dark capsule. Drawn in `drawKnob` so a live glass view is not moved on every scroll tick.
private final class GlassScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        scrollerStyle == .overlay ? 18 : super.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle)
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) {}

    override func drawKnob() {
        let slot = rect(for: .knobSlot)
        let knob = rect(for: .knob)
        guard knob.height > 1, slot.height > 1, knob.height < slot.height - 2 else { return }
        let width = min(14, max(slot.width - 3, 10))
        var height = max(knob.height + 18, 48)
        height = min(height, slot.height - 4)
        var y = knob.midY - height / 2
        y = min(max(y, slot.minY + 2), slot.maxY - height - 2)
        let rect = NSRect(x: slot.midX - width / 2, y: y, width: width, height: height)
        let path = NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2)
        NSColor(calibratedWhite: 0.02, alpha: 0.78).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

extension View {
    /// Put this on scroll content so the installer sits inside the scroll view.
    func glassScrollKnob() -> some View {
        background(GlassScrollerInstaller())
    }

    /// Content dissolves at the viewport instead of being sliced by a hard edge.
    func softScrollEdges() -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                Rectangle().fill(Color.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
            }
        }
    }
}

// MARK: - Shared chrome (pages live in UI/*View.swift)

/// Shared page frame: title row where the screenshot has "All time ⌃" /
/// search, then the content column with the same 28pt gutters.
struct PageScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(WhisperType.text(22, bold: true))
                .foregroundStyle(.primary)
                .padding(.horizontal, 28)
                .padding(.top, 48)
            ScrollView {
                content()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassScrollKnob()
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.visible)
            .softScrollEdges()
        }
        .background(Color.clear)
    }
}

struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
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
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
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
                    .font(WhisperType.text(15))
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
