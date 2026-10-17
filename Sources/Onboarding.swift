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
    /// Set once Stash has read the clipboard on purpose; until then `.default` means "not asked yet".
    @Published private(set) var probedClipboard = false
    private var timer: Timer?

    static let maccyID = "org.p0deje.Maccy"

    var clipboardAllowed: Bool {
        clipboard == .alwaysAllow || (clipboard == .default && probedClipboard)
    }

    func startWatching() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        canPaste = AXIsProcessTrusted()
        clipboard = NSPasteboard.general.accessBehavior
        login = SMAppService.mainApp.status
        maccyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.maccyID).isEmpty
        if canPaste { UserDefaults.standard.set(true, forKey: "accessibilityGranted") }
    }

    func allowPasting() {
        // A grant from an earlier build of Stash no longer matches this one; clear it so macOS asks afresh
        // instead of showing a switch that's on but does nothing.
        if UserDefaults.standard.bool(forKey: "accessibilityGranted") {
            Self.resetAccessibility()
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            Self.openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
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
                ChromeRow(title: "Paste into apps", detail: "Lets ⌥↩ paste the item into the app you're in.") {
                    IconTile(symbol: "arrow.down.doc.fill", hue: 5)
                } control: {
                    if permissions.canPaste { Granted() } else {
                        ChromeTextButton(symbol: "lock.open.fill", title: "Allow", help: "Open the Accessibility settings") {
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
