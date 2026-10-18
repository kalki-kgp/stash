import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global shortcut that opens Stash: a key code plus Carbon modifiers, kept in defaults.
struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey))
    private static let defaultsKey = "openShortcut"

    static var saved: Shortcut {
        get {
            UserDefaults.standard.data(forKey: defaultsKey)
                .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A key press made while recording, or nil if it can't be a global shortcut: without ⌘, ⌥ or ⌃
    /// it would take over ordinary typing, so only F-keys may stand alone.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = Int(event.keyCode)
        guard Self.functionKeys[code] != nil || !flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: UInt32(code), modifiers: UInt32(modifiers))
    }

    /// As macOS writes shortcuts in menus: ⌃⌥⇧⌘ then the key, as the current keyboard layout labels it.
    var display: String {
        var symbols = ""
        if modifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols + keyName
    }

    private var keyName: String {
        let code = Int(keyCode)
        if let name = Self.functionKeys[code] ?? Self.specialKeys[code] { return name }
        return Self.character(for: keyCode) ?? "Key \(keyCode)"
    }

    /// True when macOS itself uses this combination (Spotlight, input sources, screenshots and the
    /// rest of System Settings → Keyboard Shortcuts), where a hot key would never fire.
    var isTakenBySystem: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        let relevant = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        return list.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? Int,
                  let mods = entry[kHISymbolicHotKeyModifiers as String] as? Int else { return false }
            return UInt32(code) == keyCode && UInt32(mods) & relevant == modifiers & relevant
        }
    }

    private static func character(for keyCode: UInt32) -> String? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let input = source?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(input, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = data.withUnsafeBytes { bytes in
                UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode),
                               UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            }
            let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            if status == noErr, !text.isEmpty { return text.uppercased() }
        }
        return nil
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]
}

/// The shortcut setting as the settings window shows it: the current combination, whether a new one
/// is being recorded, and why the last one was turned down.
final class ShortcutSetting: ObservableObject {
    @Published private(set) var current = Shortcut.saved
    @Published private(set) var isRecording = false
    @Published private(set) var problem: String?
    /// Registers a shortcut globally; false if another app holds it.
    var register: ((Shortcut) -> Bool)?
    /// Lets go of the global shortcut while recording, so pressing it reaches the recorder.
    var suspend: (() -> Void)?
    var onChange: (() -> Void)?
    private var monitor: Any?

    func startRecording() {
        guard !isRecording else { return }
        problem = nil
        isRecording = true
        suspend?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.record(event)
            return nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        _ = register?(current)
    }

    func reset() {
        problem = nil
        apply(.standard)
    }

    /// Esc cancels; anything else that can be a shortcut is tried.
    private func record(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            problem = nil
            stopRecording()
            return
        }
        guard let shortcut = Shortcut(event: event) else {
            problem = "Add ⌘, ⌥ or ⌃ so it doesn't get in the way of typing."
            return
        }
        stopRecording()
        apply(shortcut)
    }

    /// Takes a new shortcut if macOS and other apps leave it free; otherwise keeps the current one.
    func apply(_ shortcut: Shortcut) {
        if shortcut.isTakenBySystem {
            problem = "macOS uses \(shortcut.display). Pick another."
            return
        }
        guard register?(shortcut) ?? false else {
            problem = "Another app uses \(shortcut.display). Pick another."
            _ = register?(current)
            return
        }
        problem = nil
        if shortcut != current {
            current = shortcut
            Shortcut.saved = shortcut
            onChange?()
        }
    }
}

/// The capsule that shows the shortcut and records a new one when clicked.
struct ShortcutRecorder: View {
    @ObservedObject var setting: ShortcutSetting

    var body: some View {
        HStack(spacing: 6) {
            if setting.current != .standard && !setting.isRecording {
                ChromeCircleButton(symbol: "arrow.counterclockwise", help: "Back to \(Shortcut.standard.display)") {
                    setting.reset()
                }
            }
            ChromeTextButton(symbol: setting.isRecording ? "record.circle" : "keyboard",
                             title: setting.isRecording ? "Press keys…" : setting.current.display,
                             help: setting.isRecording ? "Press the new shortcut, or Esc to cancel" : "Record a new shortcut") {
                setting.isRecording ? setting.stopRecording() : setting.startRecording()
            }
        }
    }
}
