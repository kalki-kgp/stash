// Visual tokens and building blocks for the panel chrome, its popovers
// and the settings window.

import AppKit
import SwiftUI

enum Chrome {
    static let windowCornerRadius: CGFloat = 26

    static let iconFont: Font = .system(size: 12, weight: .semibold)
    static let inlineIconFont: Font = .system(size: 11, weight: .semibold)
    static let chevronFont: Font = .system(size: 8, weight: .bold)
    static let capsuleContentHeight: CGFloat = 28
    static let capsuleVerticalPadding: CGFloat = 2
    static let capsuleHorizontalPadding: CGFloat = 12
    static var capsuleHeight: CGFloat { capsuleContentHeight + capsuleVerticalPadding * 2 }

    static let cardCornerRadius: CGFloat = 16
    static let sectionSpacing: CGFloat = 20
    static let sectionHeaderSpacing: CGFloat = 10
    static let contentHorizontalPadding: CGFloat = 16
    static let rowControlTrailingPadding: CGFloat = 10

    static func overlay(_ opacity: Double) -> Color { primaryText.opacity(opacity) }

    static let primaryText = Color(nsColor: .labelColor)
    static let secondaryText = Color(nsColor: .secondaryLabelColor)
    static let accent = Color(nsColor: .controlAccentColor)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let glassTint = Color.clear

    static var hover: Animation { .easeOut(duration: 0.1) }
    static var panelSlide: Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.32, dampingFraction: 0.9)
    }

    /// The section tile hues the settings sidebar uses.
    static let tileHues: [Color] = [
        Color(red: 0.345, green: 0.337, blue: 0.839),
        Color(red: 1.000, green: 0.584, blue: 0.000),
        Color(red: 0.188, green: 0.690, blue: 0.780),
        Color(red: 0.686, green: 0.322, blue: 0.871),
        Color(red: 0.204, green: 0.780, blue: 0.349),
        Color(red: 0.040, green: 0.478, blue: 1.000),
        Color(red: 0.925, green: 0.282, blue: 0.600),
        Color(red: 0.800, green: 0.565, blue: 0.145),
        Color(red: 0.353, green: 0.400, blue: 0.459),
    ]
}

// MARK: - Surfaces

extension View {
    func chromeGlassCapsule() -> some View {
        glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)).interactive(), in: Capsule(style: .continuous))
    }

    func chromeGlassCircle() -> some View {
        glassEffect(.regular.tint(Chrome.glassTint.opacity(0.3)).interactive(), in: Circle())
    }
}

/// One Liquid Glass surface for a whole window or panel, clipped to its 26pt radius, with a
/// legibility scrim. The window's background is clear, so this shape is all there is.
struct WindowGlass: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.windowCornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        shape
            .fill(.clear)
            .glassEffect(in: shape)
            .overlay { shape.fill(isDark ? Color.black : Color.white).opacity(isDark ? 0.26 : 0.18) }
            .allowsHitTesting(false)
    }
}

/// Window chrome: a clear, full-size-content titled window
/// whose native traffic lights are pinned inside the rounded corner.

enum WindowChrome {
    static let trafficLightDiameter: CGFloat = 14
    static let trafficLightPitch: CGFloat = 23
    static let trafficLightLeading: CGFloat = 18
    static let trafficLightTop: CGFloat = 16
    static let titlebarHeight: CGFloat = 46

    static func configure(_ window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // A focused window draws a separator under the title bar that cuts through the rounded corner.
        window.titlebarSeparatorStyle = .none
        // Tahoe rounds a toolbar window's corners to the large radius and a bare titled window's
        // to a small one; the empty toolbar makes the system outline follow the 26pt glass.
        window.toolbar = NSToolbar(identifier: "stash.chrome")
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.invalidateShadow()
    }

    /// Pins the native buttons with constraints, since the title bar's own layout pass resets frames.
    static func placeTrafficLights(on window: NSWindow) {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        // Reach the title bar down far enough that the moved buttons still receive clicks.
        if let container = titlebar.superview, let themeFrame = container.superview, container.frame.height < titlebarHeight {
            var fitted = container.frame
            if !themeFrame.isFlipped { fitted.origin.y = fitted.maxY - titlebarHeight }
            fitted.size.height = titlebarHeight
            container.frame = fitted
        }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type), button.translatesAutoresizingMaskIntoConstraints else { continue }
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor,
                                                constant: trafficLightLeading + CGFloat(index) * trafficLightPitch),
                button.topAnchor.constraint(equalTo: titlebar.topAnchor, constant: trafficLightTop),
                button.widthAnchor.constraint(equalToConstant: trafficLightDiameter),
                button.heightAnchor.constraint(equalToConstant: trafficLightDiameter),
            ])
        }
        titlebar.layoutSubtreeIfNeeded()
    }
}

// MARK: - Chrome controls

struct ChromeCircleButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Chrome.iconFont)
                .foregroundStyle(Chrome.primaryText.opacity(isHovering ? 1 : 0.92))
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .chromeGlassCircle()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

struct ChromeTextButton: View {
    let symbol: String
    let title: String
    let help: String
    var isEnabled = true
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(Chrome.inlineIconFont)
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .help(help)
        .accessibilityLabel(Text(help))
    }

    private var foreground: Color {
        guard isEnabled else { return Chrome.primaryText.opacity(0.32) }
        if isDestructive { return Chrome.danger.opacity(isHovering ? 1 : 0.92) }
        return Chrome.primaryText.opacity(isHovering ? 1 : 0.92)
    }
}

/// A text button shaped like a chrome capsule that opens a popover.
struct ChromeTextMenu<Content: View>: View {
    let symbol: String
    let title: String
    let help: String
    @ViewBuilder var content: Content

    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(Chrome.inlineIconFont)
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(Chrome.chevronFont).foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .padding(.vertical, Chrome.capsuleVerticalPadding)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .help(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu { content }
        }
    }
}

struct PopoverSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Chrome.secondaryText)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A glass capsule showing the current choice; clicking it opens the choices in a native popover.
struct GlassPickerButton<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value
    var placeholder = "—"

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        let title = options.first { $0.value == selection }?.title ?? placeholder
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(Chrome.chevronFont).foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleContentHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .chromeGlassCapsule()
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    PopoverItem(option.title, isChecked: option.value == selection) {
                        selection = option.value
                    }
                }
            }
        }
    }
}

// MARK: - Popovers

struct PopoverMenu<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(6)
            .frame(minWidth: 190, maxWidth: 320, alignment: .leading)
    }
}

struct PopoverItem: View {
    let title: String
    var isChecked: Bool?
    let action: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isHovering = false

    init(_ title: String, isChecked: Bool? = nil, action: @escaping () -> Void) {
        self.title = title
        self.isChecked = isChecked
        self.action = action
    }

    var body: some View {
        Button {
            dismiss()
            Task { @MainActor in action() }
        } label: {
            HStack(spacing: 8) {
                if let isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(isChecked ? 1 : 0)
                        .frame(width: 14)
                }
                Text(verbatim: title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 16)
            }
            .foregroundStyle(Chrome.primaryText)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Chrome.overlay(0.1) : Color.clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Chrome.hover) { isHovering = hovering } }
    }
}

// MARK: - Cards

struct ChromeCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Chrome.cardCornerRadius, style: .continuous)
                    .fill(Chrome.overlay(0.05))
            )
    }
}

struct ChromeSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionHeaderSpacing) {
            HStack {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let trailing { trailing }
            }
            .padding(.horizontal, 4)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChromeRow<Leading: View, Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 13))
                    .foregroundStyle(Chrome.primaryText)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Chrome.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.leading, 12)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
    }
}

extension ChromeRow where Leading == EmptyView {
    init(title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.leading = EmptyView()
        self.control = control()
    }
}

struct ChromeRowDivider: View {
    var inset: CGFloat = 16
    var body: some View { Divider().padding(.leading, inset) }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

extension AnyTransition {
    static var softAppear: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 4)).animation(.smooth(duration: 0.32)),
            removal: .opacity.animation(.easeOut(duration: 0.12))
        )
    }
}
