import SwiftUI

/// The ⌘⇧C panel: search on top, history below. Keys are Maccy's and are handled in
/// `History.handle`, before the search field sees them.
struct PanelView: View {
    @ObservedObject var history: History
    @FocusState private var searchFocused: Bool
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 10) {
            search
            list
            footer
        }
        .padding(12)
        .frame(width: 400)
        .onAppear { searchFocused = true }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Chrome.secondaryText)
            TextField("Search", text: $history.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .glassEffect(.regular, in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var list: some View {
        if history.rows.isEmpty {
            Text(verbatim: history.query.isEmpty ? "Copy something and it shows up here." : "No matches")
                .font(.system(size: 12.5))
                .foregroundStyle(Chrome.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 440)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(history.rows.enumerated()), id: \.element.id) { index, row in
                            RowView(history: history, row: row, index: index, isSelected: row.id == history.selection)
                                .id(row.id)
                                .onAppear { history.reachedEnd(of: row) }
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: 440)
                .onChange(of: history.keyboardMoves) {
                    guard let id = history.selection else { return }
                    proxy.scrollTo(id)
                }
                .onChange(of: history.query) {
                    if let first = history.rows.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ChromeTextButton(symbol: "trash", title: confirmingClear ? "Clear everything unpinned?" : "Clear",
                             help: "Delete everything that isn't pinned", isDestructive: confirmingClear) {
                if confirmingClear {
                    confirmingClear = false
                    history.clear()
                } else {
                    confirmingClear = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmingClear = false }
                }
            }
            Spacer()
            ChromeCircleButton(symbol: "power", help: "Quit Stash") { NSApp.terminate(nil) }
        }
    }
}

private struct RowView: View {
    @ObservedObject var history: History
    let row: Row
    let index: Int
    let isSelected: Bool
    @State private var tooltip: String?

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.primaryText)
                    .lineLimit(row.kind == .text ? 2 : 1)
                Text(row.lastAt, format: .relative(presentation: .named))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Chrome.secondaryText)
            }
            Spacer(minLength: 6)
            if row.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            if index < 9 {
                Text(verbatim: "⌘\(index + 1)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Chrome.secondaryText.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Chrome.overlay(0.11) : Color.clear)
        }
        .contentShape(.rect)
        .onTapGesture { history.pick(row, History.mode(for: NSEvent.modifierFlags)) }
        .onContinuousHover { phase in
            guard case .active = phase, history.hoverArmed, history.selection != row.id else { return }
            history.selection = row.id
        }
        .help(tooltip ?? "")
        .onHover { inside in
            // Load the full text only for the row under the pointer, for the tooltip.
            if inside, tooltip == nil, row.kind != .image { tooltip = history.store.fullText(row.id) }
        }
        .contextMenu {
            Button("Copy") { history.pick(row) }
            Button("Paste") { history.pick(row, .paste) }
            Button(row.pinned ? "Unpin" : "Pin") { history.togglePin(row) }
            Button("Delete", role: .destructive) { history.delete(row) }
        }
    }

    private var leading: some View {
        icon.frame(width: 48, height: 36)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.kind {
        case .image:
            if let hash = row.imageHash, let image = history.thumbnail(hash) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                IconTile(symbol: "photo", hue: 2, size: 28)
            }
        case .file:
            IconTile(symbol: "doc.fill", hue: 5, size: 28)
        case .text:
            if let app = row.app, let icon = history.icon(for: app) {
                Image(nsImage: icon).frame(width: 28, height: 28)
            } else {
                IconTile(symbol: "text.alignleft", hue: 8, size: 28)
            }
        }
    }
}
