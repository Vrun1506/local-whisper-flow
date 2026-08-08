import AppKit

/// The floating overlay shown while dictating.
///
/// Everything about this window is arranged so that it *cannot* take focus. If
/// it ever became key, the app you were typing in would lose its insertion
/// point and the transcript would have nowhere to land. Three things guarantee
/// that: `.nonactivatingPanel`, `canBecomeKey == false`, and the app running
/// with `.accessory` activation policy.
final class HUDWindow {

    enum State {
        case listening(text: String)
        case working(String)
        case message(String, isError: Bool)
    }

    private let panel: NSPanel
    private let blurView = NSVisualEffectView()
    private let barsView = WaveformView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    // Geometry. The panel grows downward-anchored as text wraps, so the bottom
    // edge stays put and new lines push the top upward — steadier to read than
    // a box that jumps around mid-sentence.
    private static let minWidth: CGFloat = 440
    private static let maxWidth: CGFloat = 760
    private static let minHeight: CGFloat = 78
    private static let horizontalPadding: CGFloat = 20
    private static let gutterWidth: CGFloat = 76      // waveform / spinner column
    private static let gutterGap: CGFloat = 16
    private static let verticalPadding: CGFloat = 22
    /// Beyond this the overlay would dominate the screen, so older words are
    /// dropped from the front instead.
    private static let maxLines = 8

    /// Current panel size; recomputed per update as the text grows.
    private var size = NSSize(width: HUDWindow.minWidth, height: HUDWindow.minHeight)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: HUDWindow.minWidth,
                                                            height: HUDWindow.minHeight)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Never intercept clicks: the overlay sits over whatever you're working
        // in and must stay completely inert.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]

        buildContent()
    }

    // MARK: Construction

    private func buildContent() {
        let content = NSView(frame: NSRect(origin: .zero, size: size))

        blurView.frame = content.bounds
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = 18
        blurView.layer?.cornerCurve = .continuous
        blurView.layer?.masksToBounds = true
        content.addSubview(blurView)

        barsView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(barsView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        content.addSubview(spinner)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0            // grow instead of truncating
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(label)

        NSLayoutConstraint.activate([
            barsView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            barsView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            barsView.widthAnchor.constraint(equalToConstant: 76),
            barsView.heightAnchor.constraint(equalToConstant: 34),

            spinner.centerXAnchor.constraint(equalTo: barsView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),

            label.leadingAnchor.constraint(equalTo: barsView.trailingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        panel.contentView = content
    }

    // MARK: Presentation

    func show(_ state: State) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        switch state {
        case let .listening(text):
            barsView.isHidden = false
            barsView.isAnimating = true
            spinner.stopAnimation(nil)
            label.stringValue = text.isEmpty ? "Listening…" : text
            label.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor

        case let .working(text):
            barsView.isAnimating = false
            barsView.isHidden = true
            spinner.startAnimation(nil)
            label.stringValue = text
            label.textColor = .secondaryLabelColor

        case let .message(text, isError):
            barsView.isAnimating = false
            barsView.isHidden = true
            spinner.stopAnimation(nil)
            label.stringValue = text
            label.textColor = isError ? .systemRed : .secondaryLabelColor
        }

        resizeToFitText()
        reposition()
        // orderFrontRegardless, never makeKeyAndOrderFront — the latter is
        // precisely what would steal the insertion point.
        panel.orderFrontRegardless()
    }

    // MARK: Sizing

    /// Wraps the text and grows the panel to fit it, trimming from the front
    /// once it would get taller than `maxLines`. Trimming the front rather than
    /// the back is deliberate: while dictating, the words you just said matter
    /// more than the ones from thirty seconds ago.
    private func resizeToFitText() {
        let width = preferredWidth()
        let textWidth = width - (Self.horizontalPadding * 2) - Self.gutterWidth - Self.gutterGap
        let maxTextHeight = lineHeight * CGFloat(Self.maxLines)

        let fitted = trimmedToFit(label.stringValue, width: textWidth, maxHeight: maxTextHeight)
        if fitted != label.stringValue {
            label.stringValue = fitted
        }

        let textHeight = measuredHeight(of: fitted, width: textWidth)
        let height = max(Self.minHeight, ceil(textHeight) + Self.verticalPadding * 2)
        size = NSSize(width: width, height: height)
    }

    /// Wider on big displays so long sentences need fewer lines, but never so
    /// wide that the eye has to travel across the whole screen.
    private func preferredWidth() -> CGFloat {
        guard let screenWidth = currentScreen()?.visibleFrame.width else { return Self.minWidth }
        return min(Self.maxWidth, max(Self.minWidth, screenWidth * 0.5))
    }

    private var lineHeight: CGFloat {
        let font = label.font ?? .systemFont(ofSize: 14, weight: .medium)
        return ceil(font.ascender - font.descender + font.leading)
    }

    private func measuredHeight(of text: String, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return lineHeight }
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font ?? .systemFont(ofSize: 14)]
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return max(lineHeight, bounds.height)
    }

    private func trimmedToFit(_ text: String, width: CGFloat, maxHeight: CGFloat) -> String {
        guard measuredHeight(of: text, width: width) > maxHeight else { return text }

        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // Drop whole words from the front until it fits. Utterances are short
        // enough that this stays cheap even at partial-result frequency.
        while words.count > 1 {
            words.removeFirst()
            let candidate = "… " + words.joined(separator: " ")
            if measuredHeight(of: candidate, width: width) <= maxHeight {
                return candidate
            }
        }
        return text
    }

    /// Shows a transient message that dismisses itself.
    func flash(_ text: String, isError: Bool = false, duration: TimeInterval = 2.2) {
        show(.message(text, isError: isError))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        barsView.isAnimating = false
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    func update(level: Float) {
        barsView.push(level: level)
    }

    /// Panel geometry and the text actually on screen after any trimming.
    /// Used by `--demo-hud` to verify wrapping without eyeballing it.
    var debugState: (frame: NSRect, displayedText: String) {
        (panel.frame, label.stringValue)
    }

    private func currentScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Bottom-centre of whichever screen the pointer is on, so it follows you
    /// across a multi-monitor setup. The bottom edge is the anchor, so a panel
    /// that grew taller extends upward rather than shifting under your gaze.
    private func reposition() {
        guard let frame = currentScreen()?.visibleFrame else { return }

        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 130
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

// MARK: - Waveform

/// A scrolling bar-graph of recent microphone levels.
private final class WaveformView: NSView {

    private static let barCount = 13

    private var levels = [CGFloat](repeating: 0, count: barCount)
    /// Rendered heights, eased toward `levels` so the bars glide rather than
    /// snapping between audio buffers (which arrive only ~12 times a second).
    private var displayed = [CGFloat](repeating: 0, count: barCount)
    private var timer: Timer?
    private var pendingLevel: CGFloat = 0

    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            isAnimating ? startTimer() : stopTimer()
        }
    }

    override var wantsUpdateLayer: Bool { false }

    func push(level: Float) {
        pendingLevel = CGFloat(max(0, min(1, level)))
    }

    private func startTimer() {
        levels = [CGFloat](repeating: 0, count: Self.barCount)
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // .common keeps it running while menus are open or the user is dragging.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        pendingLevel = 0
        displayed = [CGFloat](repeating: 0, count: Self.barCount)
        needsDisplay = true
    }

    private func tick() {
        levels.removeFirst()
        levels.append(pendingLevel)
        for i in displayed.indices {
            displayed[i] += (levels[i] - displayed[i]) * 0.45
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let barWidth: CGFloat = 3
        let spacing = (bounds.width - CGFloat(Self.barCount) * barWidth) / CGFloat(Self.barCount - 1)
        let minHeight: CGFloat = 3

        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)

        for (index, level) in displayed.enumerated() {
            let height = max(minHeight, level * bounds.height)
            let x = CGFloat(index) * (barWidth + spacing)
            let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        }
        context.fillPath()
    }

    deinit {
        timer?.invalidate()
    }
}
