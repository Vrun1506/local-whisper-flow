import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let hotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let hud = HUDWindow()
    private let history = TranscriptStore.shared

    private var engine: TranscriptionEngine?
    private var engineReady = false
    private var engineStatus = "Starting…"

    /// Guards against a second hold arriving while the previous transcript is
    /// still being decoded and pasted.
    private var isRecording = false
    private var isFinishing = false
    /// Start-up is async, so a fast release can arrive before the engine has
    /// actually begun. Release waits on this rather than finalizing an
    /// utterance that never started.
    private var beginTask: Task<Void, Never>?

    private var hotkeyRetryTimer: Timer?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        wireHotkey()

        capture.onLevel = { [weak self] level in
            // Fired on the audio thread.
            DispatchQueue.main.async { self?.hud.update(level: level) }
        }

        Task { await startUp() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.stop()
        capture.stop()
        hotkeyRetryTimer?.invalidate()
    }

    private func startUp() async {
        _ = await Permissions.requestMicrophone()

        if !Permissions.allGranted {
            presentPermissionOnboarding()
        }

        await loadEngine(Settings.shared.engine)
    }

    // MARK: Engine

    private func loadEngine(_ kind: EngineKind) async {
        engineReady = false
        engineStatus = "Preparing \(kind == .apple ? "Apple Speech" : "Whisper")…"
        refreshStatusIcon()

        if let existing = engine {
            await existing.teardown()
            engine = nil
        }

        let newEngine = kind.makeEngine()
        newEngine.onPartial = { [weak self] text in
            guard let self, self.isRecording else { return }
            self.hud.show(.listening(text: text))
        }

        do {
            var sawProgress = false
            try await newEngine.prepare { [weak self] status in
                Task { @MainActor in
                    guard let self else { return }
                    self.engineStatus = status
                    // Model downloads take minutes; surface them rather than
                    // leaving the app looking hung.
                    if status.contains("Download") || status.contains("Loading") {
                        sawProgress = true
                        self.hud.show(.working(status))
                    } else if sawProgress {
                        self.hud.hide()
                    }
                }
            }
            engine = newEngine
            engineReady = true
            engineStatus = "Ready"
            if sawProgress { hud.flash("\(newEngine.displayName) ready — hold right ⌥ to dictate") }
        } catch {
            engineStatus = error.localizedDescription
            hud.flash(error.localizedDescription, isError: true, duration: 5)
            SoundCue.error()
        }

        refreshStatusIcon()
    }

    // MARK: Hotkey

    private func wireHotkey() {
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] longEnough in self?.endRecording(longEnough: longEnough) }
        attemptHotkeyStart()
    }

    private func attemptHotkeyStart() {
        guard !hotkey.isRunning else { return }
        if hotkey.start() {
            hotkeyRetryTimer?.invalidate()
            hotkeyRetryTimer = nil
            return
        }

        // Tap creation fails when Input Monitoring hasn't been granted. Prompt
        // once, then keep retrying so granting it takes effect without needing
        // a relaunch.
        Permissions.requestInputMonitoring()
        guard hotkeyRetryTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.attemptHotkeyStart() }
        }
        hotkeyRetryTimer = timer
    }

    // MARK: Recording

    private func beginRecording() {
        guard !isRecording, !isFinishing else { return }

        guard let engine, engineReady else {
            hud.flash(engineStatus.isEmpty ? "Engine not ready yet" : engineStatus, isError: true)
            SoundCue.error()
            return
        }
        guard Permissions.microphoneGranted else {
            // The Microphone pane has no "+" button — an app only appears there
            // once it has asked. So ask, rather than sending the user to a pane
            // that may not even list us yet.
            hud.flash("Microphone access needed — approve the prompt", isError: true, duration: 4)
            SoundCue.error()
            Task {
                if await Permissions.requestMicrophone() {
                    hud.flash("Microphone enabled — hold right ⌥ to dictate")
                } else {
                    Permissions.openSettings(.microphone)
                }
            }
            return
        }

        isRecording = true
        hud.show(.listening(text: ""))
        SoundCue.start()

        beginTask = Task {
            do {
                try await engine.beginUtterance()
                // Bail out if the key was already released while we were
                // setting up; starting the mic now would leave it running.
                guard isRecording else {
                    await engine.cancelUtterance()
                    return
                }
                try capture.start(outputFormat: engine.audioFormat) { buffer in
                    engine.feed(buffer)
                }
            } catch {
                isRecording = false
                capture.stop()
                await engine.cancelUtterance()
                hud.flash(error.localizedDescription, isError: true, duration: 4)
                SoundCue.error()
            }
        }
    }

    private func endRecording(longEnough: Bool) {
        guard isRecording, let engine else { return }
        isRecording = false
        capture.stop()

        guard longEnough else {
            // A brush against the key, not an intent to dictate.
            hud.hide()
            Task {
                await beginTask?.value
                beginTask = nil
                await engine.cancelUtterance()
            }
            return
        }

        isFinishing = true
        SoundCue.stop()
        hud.show(.working("Transcribing…"))
        refreshStatusIcon()

        Task {
            defer {
                isFinishing = false
                refreshStatusIcon()
            }
            // Make sure the utterance actually started before finalizing it.
            await beginTask?.value
            beginTask = nil
            do {
                let raw = try await engine.finishUtterance()
                let text = Settings.shared.removeFillers ? TranscriptCleaner.clean(raw) : raw
                guard !text.isEmpty else {
                    hud.flash("No speech detected")
                    return
                }

                history.add(text)
                let result = await TextInjector.deliver(text, using: Settings.shared.outputMode)

                switch result {
                case .delivered:
                    hud.hide()
                case .blockedBySecureInput:
                    hud.flash("Secure input is active — copied to clipboard instead", isError: true, duration: 4)
                case .notPermitted:
                    hud.flash("Accessibility access is off — copied to clipboard instead", isError: true, duration: 4)
                    Permissions.openSettings(.accessibility)
                }
            } catch {
                hud.flash(error.localizedDescription, isError: true, duration: 4)
                SoundCue.error()
            }
        }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusIcon()
    }

    private func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        if isRecording {
            symbol = "mic.fill"
        } else if isFinishing {
            symbol = "waveform"
        } else if !engineReady {
            symbol = "mic.slash"
        } else {
            symbol = "mic"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "WisprLocal")
        // Must stay a template image for contentTintColor to have any effect.
        button.image?.isTemplate = true
        button.contentTintColor = isRecording ? .systemRed : nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "Hold right ⌥ to dictate", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let status = NSMenuItem(title: engineReady ? "Engine: \(engine?.displayName ?? "—")" : engineStatus,
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())
        menu.addItem(engineMenu())
        menu.addItem(outputMenu())

        let fillers = NSMenuItem(title: "Remove filler words", action: #selector(toggleFillers), keyEquivalent: "")
        fillers.target = self
        fillers.state = Settings.shared.removeFillers ? .on : .off
        fillers.toolTip = "Strips um, uh, erm and stutters. Leaves meaningful words alone."
        menu.addItem(fillers)

        let sounds = NSMenuItem(title: "Sound cues", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = Settings.shared.playSounds ? .on : .off
        menu.addItem(sounds)

        menu.addItem(.separator())
        menu.addItem(permissionsMenu())
        menu.addItem(historyMenu())

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit WisprLocal", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func engineMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        // Only offer engines this macOS version can actually run.
        for kind in EngineKind.available {
            let child = NSMenuItem(title: kind.displayName, action: #selector(selectEngine(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = kind.rawValue
            child.state = (Settings.shared.engine == kind) ? .on : .off
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    private func outputMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Insert text by", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for mode in OutputMode.allCases {
            let child = NSMenuItem(title: mode.displayName, action: #selector(selectOutput(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = mode.rawValue
            child.state = (Settings.shared.outputMode == mode) ? .on : .off
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    private func permissionsMenu() -> NSMenuItem {
        let allGood = Permissions.allGranted
        let item = NSMenuItem(title: allGood ? "Permissions ✅" : "Permissions ⚠️", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let rows: [(String, Bool, Permissions.Pane)] = [
            ("Microphone", Permissions.microphoneGranted, .microphone),
            ("Input Monitoring (hotkey)", Permissions.inputMonitoringGranted, .inputMonitoring),
            ("Accessibility (paste)", Permissions.accessibilityGranted, .accessibility),
        ]
        for (name, granted, pane) in rows {
            let child = NSMenuItem(title: "\(granted ? "✅" : "❌")  \(name)",
                                   action: #selector(openPermissionPane(_:)), keyEquivalent: "")
            child.target = self
            child.representedObject = pane.rawValue
            submenu.addItem(child)
        }
        item.submenu = submenu
        return item
    }

    private func historyMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Recent dictations", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if history.transcripts.isEmpty {
            let empty = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for transcript in history.transcripts.prefix(15) {
                let preview = transcript.text.count > 60
                    ? String(transcript.text.prefix(60)) + "…"
                    : transcript.text
                let child = NSMenuItem(title: preview, action: #selector(copyTranscript(_:)), keyEquivalent: "")
                child.target = self
                child.representedObject = transcript.text
                child.toolTip = transcript.text
                submenu.addItem(child)
            }
            submenu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear history", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }

        item.submenu = submenu
        return item
    }

    // MARK: Actions

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = EngineKind(rawValue: raw),
              kind != Settings.shared.engine else { return }
        Settings.shared.engine = kind
        Task { await loadEngine(kind) }
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = OutputMode(rawValue: raw) else { return }
        Settings.shared.outputMode = mode
    }

    @objc private func toggleSounds() {
        Settings.shared.playSounds.toggle()
    }

    @objc private func toggleFillers() {
        Settings.shared.removeFillers.toggle()
    }

    @objc private func openPermissionPane(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pane = Permissions.Pane(rawValue: raw) else { return }
        switch pane {
        case .accessibility:   Permissions.requestAccessibility()
        case .inputMonitoring: Permissions.requestInputMonitoring()
        case .microphone:      break
        }
        Permissions.openSettings(pane)
    }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        TextInjector.copyToClipboard(text)
    }

    @objc private func clearHistory() {
        history.clear()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.flash("Could not change login item: \(error.localizedDescription)", isError: true, duration: 4)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Onboarding

    private func presentPermissionOnboarding() {
        let alert = NSAlert()
        alert.messageText = "WisprLocal needs three permissions"
        alert.informativeText = """
        • Microphone — to hear you
        • Input Monitoring — to notice the right ⌥ key
        • Accessibility — to paste into other apps

        Add WisprLocal in each pane, then come back. \
        Input Monitoring only takes effect after the app restarts.
        """
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Permissions.requestInputMonitoring()
            Permissions.openSettings(.inputMonitoring)
        case .alertSecondButtonReturn:
            Permissions.requestAccessibility()
            Permissions.openSettings(.accessibility)
        default:
            break
        }
    }
}
