import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// What Stash needs from macOS, re-read every second while the setup window is open so each row
/// flips as soon as the user flips the switch in System Settings.
final class Permissions: ObservableObject {
    @Published private(set) var canPaste = AXIsProcessTrusted()
    @Published private(set) var clipboard = NSPasteboard.general.accessBehavior
    @Published private(set) var login = SMAppService.mainApp.status
    @Published private(set) var maccyRunning = false
    @Published var shortcutWorked = false
    @Published private(set) var maccyImport: ImportState = Permissions.importDone ? .done(nil) : .notStarted
    /// Runs the import (in a child process) and returns the item count, or nil if access was refused.
    var runImport: (() -> Int?)?
    var onImported: (() -> Void)?

    enum ImportState: Equatable { case notStarted, running, done(Int?), blocked }

    /// Written once a full import (every format) has finished for this history.
    static var importMarker: URL { Store.directory.appendingPathComponent(".maccy-imported-v2") }
    static var importDone: Bool { FileManager.default.fileExists(atPath: importMarker.path) }
    static var maccyInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: maccyID) != nil }
    /// Set once Stash has read the clipboard on purpose; until then `.default` means "not asked yet".
    @Published private(set) var probedClipboard = false
    /// When Allow was last clicked for pasting; if access still isn't there a few seconds later the
    /// row offers to try again.
    @Published private(set) var pasteRequestedAt: Date?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    static let maccyID = "org.p0deje.Maccy"

    var clipboardAllowed: Bool {
        clipboard == .alwaysAllow || (clipboard == .default && probedClipboard)
    }

    /// Re-checks every second, the moment macOS announces an accessibility change, and whenever the
    /// user comes back to Stash from System Settings.
    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        guard observers.isEmpty else { return }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The trust value lags the notification slightly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() })
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
        observers.forEach {
            DistributedNotificationCenter.default().removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observers = []
    }

    /// True once Allow was clicked a while ago and access still hasn't arrived.
    @Published private(set) var pasteLooksStuck = false

    func refresh() {
        canPaste = AXIsProcessTrusted()
        let stuck = !canPaste && pasteRequestedAt.map { Date().timeIntervalSince($0) > 6 } == true
        if stuck != pasteLooksStuck { pasteLooksStuck = stuck }
        clipboard = NSPasteboard.general.accessBehavior
        login = SMAppService.mainApp.status
        maccyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.maccyID).isEmpty
        if canPaste { UserDefaults.standard.set(true, forKey: "accessibilityGranted") }
    }

    func allowPasting() {
        // macOS ties the Accessibility switch to one exact build. An entry left by another build or
        // another copy of Stash shows as on but does nothing, so clear any entry first; the system
        // alert then creates a fresh one for the copy that's running, and its button opens the list.
        Self.resetAccessibility()
        pasteRequestedAt = Date()
        pasteLooksStuck = false
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Reading the clipboard on purpose brings up macOS's paste-privacy alert now, while the user is
    /// looking at this window, rather than in the middle of their work.
    func allowClipboard() {
        if clipboard == .ask || clipboard == .alwaysDeny {
            Self.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")
            return
        }
        _ = NSPasteboard.general.string(forType: .string)
        probedClipboard = true
        refresh()
    }

    func setOpenAtLogin(_ on: Bool) {
        if on {
            try? SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try? SMAppService.mainApp.unregister()
        }
        refresh()
    }

    func importMaccy() {
        guard maccyImport != .running, let runImport else { return }
        // After a "Don't Allow", macOS won't ask again until the answer is cleared.
        if maccyImport == .blocked { Self.resetAppDataAccess() }
        maccyImport = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let count = runImport()
            DispatchQueue.main.async {
                if let count {
                    FileManager.default.createFile(atPath: Self.importMarker.path, contents: nil)
                    self.maccyImport = .done(count)
                    self.onImported?()
                } else {
                    self.maccyImport = .blocked
                }
            }
        }
    }

    private static func resetAppDataAccess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "SystemPolicyAppData", Bundle.main.bundleIdentifier ?? "dev.kalki.stash"]
        try? process.run()
        process.waitUntilExit()
    }

    func quitMaccy() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.maccyID).forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }

    static func resetAccessibility() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "dev.kalki.stash"]
        try? process.run()
        process.waitUntilExit()
        UserDefaults.standard.set(false, forKey: "accessibilityGranted")
    }

    private static func openSettings(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

struct OnboardingView: View {
    @ObservedObject var permissions: Permissions
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Set up Stash")
                        .font(.system(size: 20, weight: .semibold))
                    Text(verbatim: "Allow these once and Stash works in every app.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Chrome.secondaryText)
                }
            }
            .padding(.top, 18)

            ChromeCard {
                ChromeRow(title: "Paste into apps",
                          detail: permissions.pasteLooksStuck
                              ? "Still off. Click Try Again, then turn Stash on in the list."
                              : "Lets ⌥↩ paste the item into the app you're in.") {
                    IconTile(symbol: "arrow.down.doc.fill", hue: 5)
                } control: {
                    if permissions.canPaste { Granted() } else {
                        ChromeTextButton(symbol: permissions.pasteLooksStuck ? "arrow.clockwise" : "lock.open.fill",
                                         title: permissions.pasteLooksStuck ? "Try Again" : "Allow",
                                         help: "Ask macOS for Accessibility access") {
                            permissions.allowPasting()
                        }
                    }
                }
                ChromeRowDivider(inset: 50)
                ChromeRow(title: "Read the clipboard", detail: "Saves each copy as you make it.") {
                    IconTile(symbol: "doc.on.clipboard.fill", hue: 0)
                } control: {
                    if permissions.clipboardAllowed { Granted() } else {
                        ChromeTextButton(symbol: "lock.open.fill",
                                         title: permissions.clipboard == .default ? "Allow" : "Open Settings",
                                         help: "Allow Stash to read what you copy") {
                            permissions.allowClipboard()
                        }
                    }
                }
                ChromeRowDivider(inset: 50)
                ChromeRow(title: "Open at login",
                          detail: permissions.login == .requiresApproval
                              ? "Turn Stash on in Login Items to finish."
                              : "Starts with your Mac so no copy is missed.") {
                    IconTile(symbol: "power", hue: 4)
                } control: {
                    if permissions.login == .requiresApproval {
                        ChromeTextButton(symbol: "arrow.up.forward.app", title: "Approve", help: "Open Login Items") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    } else {
                        SettingsSwitch(isOn: Binding(get: { permissions.login == .enabled },
                                                     set: { permissions.setOpenAtLogin($0) }))
                    }
                }
                if Permissions.maccyInstalled {
                    ChromeRowDivider(inset: 50)
                    ChromeRow(title: "Bring over your Maccy history", detail: importDetail) {
                        IconTile(symbol: "tray.and.arrow.down.fill", hue: 2)
                    } control: {
                        switch permissions.maccyImport {
                        case .notStarted:
                            ChromeTextButton(symbol: "tray.and.arrow.down", title: "Import", help: "Copy Maccy's history into Stash") {
                                permissions.importMaccy()
                            }
                        case .running:
                            ProgressView().controlSize(.small).padding(.trailing, 10)
                        case .done:
                            Granted(label: "Imported")
                        case .blocked:
                            ChromeTextButton(symbol: "arrow.clockwise", title: "Try Again", help: "Ask macOS again") {
                                permissions.importMaccy()
                            }
                        }
                    }
                }
                if permissions.maccyRunning {
                    ChromeRowDivider(inset: 50)
                    ChromeRow(title: "Maccy is using ⌘⇧C", detail: "Quit it so the shortcut opens Stash.") {
                        IconTile(symbol: "keyboard.fill", hue: 1)
                    } control: {
                        ChromeTextButton(symbol: "xmark", title: "Quit Maccy", help: "Quit Maccy") {
                            permissions.quitMaccy()
                        }
                    }
                }
                ChromeRowDivider(inset: 50)
                ChromeRow(title: "Try it", detail: "Press ⌘⇧C to open your history.") {
                    IconTile(symbol: "command", hue: 3)
                } control: {
                    if permissions.shortcutWorked { Granted(label: "Works") } else {
                        Text(verbatim: "⌘⇧C")
                            .font(.system(size: 12.5, weight: .medium).monospaced())
                            .foregroundStyle(Chrome.secondaryText)
                            .padding(.trailing, 6)
                    }
                }
            }

            HStack {
                Spacer()
                ChromeTextButton(symbol: "checkmark", title: "Done", help: "Close setup", action: done)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: 520)
        .animation(Chrome.panelSlide, value: permissions.maccyRunning)
    }
}

extension OnboardingView {
    var importDetail: String {
        switch permissions.maccyImport {
        case .notStarted: "Copies it into Stash. Maccy's own data isn't changed."
        case .running: "Importing. If macOS asks to access data from other apps, choose Allow."
        case .done(let count?): count == 1 ? "1 item brought over." : "\(count) items brought over."
        case .done(nil): "Your Maccy history is in Stash."
        case .blocked: "macOS didn't allow access. Click Try Again, then choose Allow."
        }
    }
}

private struct Granted: View {
    var label = "Allowed"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Chrome.success)
            Text(verbatim: label).foregroundStyle(Chrome.secondaryText)
        }
        .font(.system(size: 12.5, weight: .medium))
        .padding(.trailing, 6)
    }
}
