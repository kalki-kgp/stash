import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

@main
struct StashApp {
    static func main() {
        ImageWorker.runIfRequested()
        Capture.readsImages = false
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
    var onKey: ((NSEvent) -> Bool)?
    var onMouseMoved: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown where onKey?(event) == true: return
        case .mouseMoved: onMouseMoved?()
        default: break
        }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
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
    /// True while the close animation runs, so reopening mid-fade isn't undone by its completion.
    private var hiding = false
    private var panelSize: NSSize?
    private static let panelMargin: CGFloat = 24

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "StashStatusItem"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusIcon()

        history.onPick = { [weak self] in self?.hidePanel() }
        history.skipCapture = { [weak self] in self?.watcher.skipCurrent() }
        buildPanel()
        // Lay the panel out once now, so the first ⌘⇧C doesn't pay for building the view tree.
        history.reload()
        panelHost.layoutSubtreeIfNeeded()
        panelSize = panelHost.fittingSize
        watcher.start()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.togglePanel(atCursor: true)
        }

        // Once per history: the marker lives next to the database, so a fresh history imports again.
        let marker = Store.directory.appendingPathComponent(".maccy-imported")
        if !FileManager.default.fileExists(atPath: marker.path) {
            DispatchQueue.global(qos: .utility).async { [store] in
                if store.isEmpty { ImageWorker.importMaccy() }
                FileManager.default.createFile(atPath: marker.path, contents: nil)
                DispatchQueue.main.async { [weak self] in
                    if self?.panel.isVisible == true { self?.history.reload() }
                }
            }
        }

        #if STASH_TEST
        TestHook.install(app: self, history: history, watcher: watcher)
        #endif
    }

    /// An image copied from Stash is only promised to the pasteboard; hand over the real data before
    /// quitting so it can still be pasted afterwards.
    func applicationWillTerminate(_ notification: Notification) {
        ImageProvider.resolveBeforeQuit()
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
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hidePanel() }
        panel.onKey = { [weak self] event in self?.history.handle(event) ?? false }
        panel.onMouseMoved = { [weak self] in self?.history.hoverArmed = true }

        let root = PanelView(history: history)
            .background(WindowGlass())
            .buttonBorderShape(.capsule)
            .padding(Self.panelMargin)
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panelHost = host
    }

    // MARK: Menu bar icon

    /// Click opens the panel; ⌥-click pauses capture, ⌥⇧-click skips the next copy (both Maccy's);
    /// right-click opens the menu.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            showMenu()
        } else if flags.contains(.option) && flags.contains(.shift) {
            watcher.ignoreNext = true
        } else if flags.contains(.option) {
            watcher.isPaused.toggle()
            updateStatusIcon()
        } else {
            togglePanel(atCursor: false)
        }
    }

    private func updateStatusIcon() {
        let name = watcher.isPaused ? "list.clipboard.fill" : "list.clipboard"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Stash")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = watcher.isPaused
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Open Stash", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let pause = menu.addItem(withTitle: watcher.isPaused ? "Resume Saving Copies" : "Pause Saving Copies",
                                 action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Stash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    /// The menu is attached only while it's open, so a left click keeps opening the panel.
    func menuDidClose(_ menu: NSMenu) { statusItem.menu = nil }

    @objc private func openFromMenu() { DispatchQueue.main.async { self.showPanel(atCursor: false) } }

    @objc private func togglePause() {
        watcher.isPaused.toggle()
        updateStatusIcon()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: Panel

    private func togglePanel(atCursor: Bool) {
        panel.isVisible && !hiding ? hidePanel() : showPanel(atCursor: atCursor)
    }

    func showPanel(atCursor: Bool) {
        hiding = false
        history.prepare()
        // The panel's size never changes, so it's measured once.
        if panelSize == nil {
            panelHost.layoutSubtreeIfNeeded()
            panelSize = panelHost.fittingSize
        }
        let size = panelSize!
        let m = Self.panelMargin
        let mouse = NSEvent.mouseLocation
        let screen = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame

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

        // Shown at once, like a menu: a fade-in reads as lag on something opened from the keyboard.
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        focusSearch()
        statusItem.button?.highlight(true)
    }

    /// Puts the cursor in the search field every time the panel opens, not just the first.
    private func focusSearch() {
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            for sub in view.subviews { if let found = field(in: sub) { return found } }
            return nil
        }
        if searchField == nil { searchField = field(in: panelHost) }
        if let searchField { panel.makeFirstResponder(searchField) }
    }
    private weak var searchField: NSTextField?

    func hidePanel() {
        guard panel.isVisible, !hiding else { return }
        hiding = true
        statusItem.button?.highlight(false)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hiding else { return }
            self.hiding = false
            self.panel.orderOut(nil)
            self.history.release()
        })
    }

    var isPanelVisible: Bool { panel.isVisible }
    var panelWindow: NSWindow { panel }

    /// Clicking anywhere else takes key focus from the panel, which closes it.
    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    #if STASH_TEST
    /// What ⌘⇧C does, timed: writes how long the panel took to open to the dump.
    func togglePanelForTest() {
        let start = DispatchTime.now().uptimeNanoseconds
        togglePanel(atCursor: true)
        panel.displayIfNeeded()
        lastOpenMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
    var lastOpenMs = 0.0
    #endif

    var hotKeyRegistered: Bool { hotKey?.isRegistered ?? false }
}
