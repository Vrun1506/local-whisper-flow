import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Delivers transcribed text to whatever app currently owns the text cursor.
///
/// Both strategies require Accessibility permission, because posting synthetic
/// keyboard events into other processes is exactly what that grant controls.
enum TextInjector {

    enum Result {
        case delivered
        /// macOS refuses synthetic input while Secure Input is on (password
        /// fields, and some terminals that leave it stuck on). The text is on
        /// the clipboard instead, so nothing is lost.
        case blockedBySecureInput
        case notPermitted
    }

    /// Virtual keycode for "v" on any layout — CGEvent keycodes are physical.
    private static let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)

    static var isSecureInputActive: Bool { IsSecureEventInputEnabled() }

    @MainActor
    static func deliver(_ text: String, using mode: OutputMode) async -> Result {
        guard !text.isEmpty else { return .delivered }

        guard Permissions.accessibilityGranted else {
            copyToClipboard(text)
            return .notPermitted
        }

        if isSecureInputActive {
            copyToClipboard(text)
            return .blockedBySecureInput
        }

        // The hotkey is a modifier, so the OS may still register ⌥ as physically
        // down for a moment after release. Pasting into that window produces
        // ⌥⌘V ("paste and match style") or nothing at all.
        try? await Task.sleep(for: .milliseconds(60))

        switch mode {
        case .paste: await paste(text)
        case .type:  await type(text)
        }
        return .delivered
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Paste strategy

    @MainActor
    private static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // Restore only after the target app has had time to read the pasteboard.
        // Too eager and the paste lands on the old contents.
        try? await Task.sleep(for: .milliseconds(280))
        restore(saved, to: pasteboard)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        // Set flags explicitly rather than letting the event inherit whatever
        // modifiers the hardware currently reports.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Deep-copies the pasteboard so we can hand it back untouched.
    /// Promised-file items can't be copied this way and are silently dropped —
    /// an acceptable trade for not permanently stealing the user's clipboard.
    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }

    // MARK: Type strategy

    /// Synthesizes the characters directly. Never touches the clipboard, and
    /// works in the handful of apps that ignore synthetic ⌘V.
    @MainActor
    private static func type(_ text: String) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)

        // Chunked because a single event carrying a long string gets truncated
        // by some apps; 16 units is comfortably under every limit seen.
        for chunk in stride(from: 0, to: units.count, by: 16).map({ start in
            Array(units[start..<min(start + 16, units.count)])
        }) {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            keyDown.flags = []
            keyUp.flags = []
            chunk.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
                keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
            }

            keyDown.post(tap: .cgAnnotatedSessionEventTap)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)

            // Without a gap, fast-redrawing apps (Electron especially) drop
            // characters as they coalesce input events.
            try? await Task.sleep(for: .milliseconds(6))
        }
    }
}
