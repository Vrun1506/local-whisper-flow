import AppKit

// Headless engine check; see SelfTest. Handled before any UI is created.
//
// Deliberately driven by a semaphore rather than `await` at top level: an async
// main would make this file an async context, and NSApplication.run() blocking
// inside the main-actor task is a fragile arrangement to rely on.
if CommandLine.arguments.contains("--selftest") {
    let index = CommandLine.arguments.firstIndex(of: "--selftest")!
    let sample = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : SelfTest.defaultSample

    // Line-buffer so progress is visible when the output is piped.
    setvbuf(stdout, nil, _IOLBF, 0)

    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var status: Int32 = 1
    Task.detached {
        status = await SelfTest.run(samplePath: sample)
        done.signal()
    }
    done.wait()
    exit(status)
}

// Prints the three TCC grants and exits. Must live in this binary rather than a
// helper script: permissions are keyed to the app's signed identity, so only the
// app itself can report on them accurately.
if CommandLine.arguments.contains("--permissions") {
    let rows: [(String, Bool, String)] = [
        ("Microphone", Permissions.microphoneGranted, "hearing you"),
        ("Input Monitoring", Permissions.inputMonitoringGranted, "noticing the right ⌥ key"),
        ("Accessibility", Permissions.accessibilityGranted, "pasting into other apps"),
    ]
    print("WisprLocal permissions\n")
    for (name, granted, why) in rows {
        print("  \(granted ? "✅" : "❌")  \(name.padding(toLength: 18, withPad: " ", startingAt: 0)) — \(why)")
    }
    if Permissions.allGranted {
        print("\nAll set. Hold right ⌥ anywhere to dictate.")
    } else {
        print("""

        Missing grants: System Settings › Privacy & Security › <pane>
        Add ~/Applications/WisprLocal.app  (⌘⇧G in the file picker).
        Input Monitoring needs an app restart to take effect.
        """)
    }
    exit(Permissions.allGranted ? 0 : 1)
}

// Displays the overlay with progressively longer text and reports how it
// resizes, so wrapping can be checked without granting any permissions.
if CommandLine.arguments.contains("--demo-hud") {
    setvbuf(stdout, nil, _IOLBF, 0)
    let demoApp = NSApplication.shared
    demoApp.setActivationPolicy(.accessory)

    let hud = MainActor.assumeIsolated { HUDWindow() }
    let script = [
        "Listening…",
        "Hi, my name is Varun.",
        "Hi, my name is Varun, and I am testing whether the overlay wraps text properly.",
        "Hi, my name is Varun, and I am testing whether the overlay wraps text properly when I keep talking for a while without stopping, which is exactly the case that used to run off the side of the screen.",
        "Hi, my name is Varun, and I am testing whether the overlay wraps text properly when I keep talking for a while without stopping, which is exactly the case that used to run off the side of the screen. This sentence keeps going well past the point where the panel should stop growing and start dropping the oldest words from the front instead, so that the newest words stay visible no matter how long I speak for.",
    ]

    // A genuinely long dictation, to exercise the front-trimming path.
    let rambling = script[4] + " " + (1...6).map {
        "And here is continuation number \($0), padding this out so the overlay has to stop growing and begin dropping the oldest words."
    }.joined(separator: " ")
    let fullScript = script + [rambling]

    var step = 0
    Timer.scheduledTimer(withTimeInterval: 1.6, repeats: true) { timer in
        MainActor.assumeIsolated {
            guard step < fullScript.count else {
                timer.invalidate()
                hud.hide()
                print("\ndone")
                exit(0)
            }
            let text = fullScript[step]
            hud.show(.listening(text: text))
            hud.update(level: 0.6)
            let state = hud.debugState
            print("""
                step \(step + 1): \(text.count) chars in
                  panel  \(Int(state.frame.width)) × \(Int(state.frame.height))  at y=\(Int(state.frame.minY))
                  shows  \(state.displayedText.count) chars\(state.displayedText.hasPrefix("… ") ? "  (trimmed from front)" : "")
                """)
            step += 1
        }
    }
    demoApp.run()
}

let app = NSApplication.shared

// .accessory keeps the app out of the Dock and the ⌘-Tab switcher, and — the
// part that actually matters — stops it from ever becoming the active app when
// the HUD appears. Whatever you were typing in keeps its insertion point.
app.setActivationPolicy(.accessory)

// Top-level code already runs on the main thread; this states that for the
// compiler's benefit.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
