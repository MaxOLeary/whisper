import AppKit
import SwiftUI

// MARK: - History page: search, day groups, copyable cards

struct HistoryView: View {
    @EnvironmentObject var store: AppStore
    @State private var query = ""

    private var groups: [History.DayGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let takes = q.isEmpty ? store.history : store.history.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return History.group(takes)
    }

    var body: some View {
        let groups = self.groups
        return VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 10)
            if store.history.isEmpty {
                empty("No takes yet. Press \(History.keycaps(store.recordHotkey)) to dictate.")
            } else if groups.isEmpty {
                empty("No takes match “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { g in
                            Text(g.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 16)
                                .padding(.bottom, 2)
                                .padding(.leading, 4)
                            ForEach(g.takes) { t in
                                TakeCard(take: t, file: History.file(for: t, in: App.dictationDir))
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Rounded search box in the title row, like the screenshot.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(ClearGlass(radius: 10))
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One take. Click copies the full text and flashes "Copied". Hover shows the
/// time and a copy glyph on the right. Right-click: Copy, Reveal in Finder.
struct TakeCard: View {
    let take: Transcript
    let file: URL
    @State private var hover = false
    @State private var copied = false
    @State private var copyGen = 0

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(take.text)
                .font(.system(size: 14))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if copied {
                    Text("Copied")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if hover {
                    Text(History.timeFmt.string(from: take.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 18)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(shape.fill(Color.white.opacity(hover ? 0.06 : 0)))
        .background(ClearGlass(radius: 14))
        .contentShape(shape)
        .onHover { hover = $0 }
        .onTapGesture { copy() }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(take.text, forType: .string)
        copyGen += 1
        let gen = copyGen
        withAnimation(.easeOut(duration: 0.12)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard gen == copyGen else { return }
            withAnimation(.easeIn(duration: 0.2)) { copied = false }
        }
    }
}
