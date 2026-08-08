import AppKit
import CoreGraphics

/// Watches for the push-to-talk key being held down anywhere in the system.
///
/// We tap `flagsChanged` rather than `keyDown` because the trigger is a bare
/// modifier. `NSEvent.ModifierFlags` cannot tell left ⌥ from right ⌥, but the
/// `keyboardEventKeycode` field of a flagsChanged CGEvent carries the physical
/// key, which can.
///
/// The tap is `.listenOnly` on purpose: events pass straight through, so right ⌥
/// keeps composing accented characters as normal. Holding it *alone* types
/// nothing, which is exactly why it makes a good dictation key.
final class HotkeyMonitor {

    /// kVK_RightOption. Left ⌥ is 58, which we deliberately ignore.
    private static let rightOptionKeyCode: Int64 = 61

    /// Below this, treat the press as a brush against the key rather than an
    /// intent to dictate. Prevents stray empty pastes.
    private static let minimumHold: TimeInterval = 0.25

    var onPress: (() -> Void)?
    /// `heldLongEnough` is false for accidental taps; the app should discard
    /// whatever it captured instead of transcribing it.
    var onRelease: ((_ heldLongEnough: Bool) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var pressedAt: Date?

    var isRunning: Bool { eventTap != nil }

    // MARK: Lifecycle

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = (1 << CGEventType.flagsChanged.rawValue)

        // `refcon` carries self into the C callback. Unretained because the
        // monitor outlives the tap in every path that matters (AppDelegate owns
        // both, and stop() runs before deinit).
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false   // almost always missing Input Monitoring permission
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        isDown = false
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables a tap that takes too long to return, or during certain
        // user input. Re-arm rather than silently going deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }

        guard type == .flagsChanged else { return }
        guard event.getIntegerValueField(.keyboardEventKeycode) == Self.rightOptionKeyCode else { return }

        let optionIsDown = event.flags.contains(.maskAlternate)

        if optionIsDown, !isDown {
            isDown = true
            pressedAt = Date()
            DispatchQueue.main.async { [weak self] in self?.onPress?() }
        } else if !optionIsDown, isDown {
            isDown = false
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            let longEnough = held >= Self.minimumHold
            DispatchQueue.main.async { [weak self] in self?.onRelease?(longEnough) }
        }
    }
}
