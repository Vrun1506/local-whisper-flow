import AVFoundation
import AppKit
import ApplicationServices

/// The three TCC grants this app cannot work without, plus deep links into the
/// System Settings panes that control them.
enum Permissions {

    // MARK: Microphone

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophone() async -> Bool {
        if microphoneGranted { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Input Monitoring — needed for the CGEventTap to see the hotkey

    static var inputMonitoringGranted: Bool {
        CGPreflightListenEventAccess()
    }

    /// Shows the system prompt the first time; afterwards macOS stays silent and
    /// the user has to visit Settings, so callers should fall back to `open`.
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    // MARK: Accessibility — needed to *post* the ⌘V / typed keystrokes

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: Settings deep links

    enum Pane: String {
        case microphone      = "Privacy_Microphone"
        case inputMonitoring = "Privacy_ListenEvent"
        case accessibility   = "Privacy_Accessibility"
    }

    static func openSettings(_ pane: Pane) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }

    /// True only when everything needed for a full dictate-and-paste round trip
    /// is in place.
    static var allGranted: Bool {
        microphoneGranted && inputMonitoringGranted && accessibilityGranted
    }
}
