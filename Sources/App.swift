import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct StashApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// A borderless panel that takes typing without activating Stash, so the app you were in
/// stays frontmost and ⌘V goes straight to it.
final class GlassPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = Store()
    private lazy var history = History(store: store)
    private lazy var watcher = Watcher(store: store) { [weak self] in
        guard let self, self.panel.isVisible else { return }
        self.history.reload()
    }
    private var statusItem: NSStatusItem!
    private var panel: GlassPanel!
    private var panelHost: NSView!
    private var hotKey: HotKey?
    private static let panelMargin: CGFloat = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "StashStatusItem"
        let image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Stash")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)

        history.onPick = { [weak self] in self?.hidePanel() }
        history.skipCapture = { [weak self] in self?.watcher.skipCurrent() }
        buildPanel()
        watcher.start()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.togglePanel(atCursor: true)
        }

        if !UserDefaults.standard.bool(forKey: "importedMaccy") && store.isEmpty {
            DispatchQueue.global(qos: .utility).async { [store] in
                _ = MaccyImport.run(into: store)
                DispatchQueue.main.async {
                    UserDefaults.standard.set(true, forKey: "importedMaccy")
                    if self.panel.isVisible { self.history.reload() }
                }
            }
        }

        if ProcessInfo.processInfo.environment["STASH_OPEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPanel(atCursor: false) }
        }
    }

    private func buildPanel() {
        panel = GlassPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own edge and shadow; a window shadow would trace the square bounds.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hidePanel() }

        let root = PanelView(history: history)
            .background(WindowGlass())
            .buttonBorderShape(.capsule)
            .padding(Self.panelMargin)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panelHost = host
    }

    @objc private func statusClicked() { togglePanel(atCursor: false) }

    private func togglePanel(atCursor: Bool) {
        panel.isVisible ? hidePanel() : showPanel(atCursor: atCursor)
    }

    private func showPanel(atCursor: Bool) {
        history.reload()
        panelHost.layoutSubtreeIfNeeded()
        let size = panelHost.fittingSize
        let m = Self.panelMargin
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!).visibleFrame

        var origin: NSPoint
        if !atCursor, let button = statusItem.button, let window = button.window, window.occlusionState.contains(.visible) {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 + m - size.height)
        } else {
            // The panel's top-left corner sits at the pointer, like Maccy's popup.
            origin = NSPoint(x: mouse.x - m, y: mouse.y + m - size.height)
        }
        origin.x = min(max(origin.x, screen.minX + 8 - m), screen.maxX - size.width + m - 8)
        origin.y = min(max(origin.y, screen.minY + 8 - m), screen.maxY - size.height + m)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        statusItem.button?.highlight(true)
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        statusItem.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.history.release()
        })
    }

    /// Clicking anywhere else takes key focus from the panel, which closes it.
    func windowDidResignKey(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["STASH_OPEN"] == nil else { return }
        hidePanel()
    }
}
