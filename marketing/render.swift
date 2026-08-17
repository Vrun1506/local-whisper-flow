import AppKit
import Foundation

// Renders the reel's scene cards as 1080x1920 PNGs. ffmpeg has no drawtext in
// this build (no libfreetype), so text is laid out with AppKit instead.

let W = 1080.0, H = 1920.0
let margin = 96.0
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

let ink = NSColor.white
let muted = NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.75, alpha: 1)
let accent = NSColor(calibratedRed: 0.35, green: 0.60, blue: 0.98, alpha: 1)
let warm = NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.30, alpha: 1)

enum Extra {
    case none
    case hud
    case bars
    case cta
}

struct Scene {
    let name: String
    let kicker: String?
    let headline: String
    let sub: String?
    let extra: Extra
}

let scenes: [Scene] = [
    Scene(name: "01_hook", kicker: nil,
          headline: "I cancelled my\n$15/month\ndictation app.",
          sub: "and rebuilt it in a weekend", extra: .none),

    Scene(name: "02_engine", kicker: "macOS 26",
          headline: "Apple shipped a new speech engine.",
          sub: "SpeechAnalyzer — runs entirely on your Mac", extra: .none),

    Scene(name: "03_demo", kicker: "HOW IT WORKS",
          headline: "Hold right ⌥.\nSpeak. Release.",
          sub: "Text lands wherever your cursor is — in any app", extra: .hud),

    Scene(name: "04_speed", kicker: "SAME AUDIO, MY M2",
          headline: "10× faster\nthan Whisper.",
          sub: nil, extra: .bars),

    Scene(name: "05_private", kicker: nil,
          headline: "Airplane mode.\nStill works.",
          sub: "No account. No subscription.\nNo audio ever leaves your Mac.", extra: .none),

    Scene(name: "06_cta", kicker: "FREE & OPEN SOURCE",
          headline: "Comment\nGITHUB",
          sub: "macOS 26+  ·  Apple silicon", extra: .cta),
]

// MARK: Drawing helpers

func font(_ size: Double, _ weight: NSFont.Weight = .bold) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
}

func draw(_ text: String, font f: NSFont, color: NSColor, in rect: NSRect,
          align: NSTextAlignment = .left, lineSpacing: Double = 0) -> Double {
    let style = NSMutableParagraphStyle()
    style.alignment = align
    style.lineSpacing = lineSpacing
    style.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color, .paragraphStyle: style]
    let s = NSAttributedString(string: text, attributes: attrs)
    let needed = s.boundingRect(with: NSSize(width: rect.width, height: .greatestFiniteMagnitude),
                                options: [.usesLineFragmentOrigin, .usesFontLeading])
    s.draw(with: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: ceil(needed.height)),
           options: [.usesLineFragmentOrigin, .usesFontLeading])
    return ceil(needed.height)
}

func height(_ text: String, font f: NSFont, width: Double, lineSpacing: Double = 0) -> Double {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.lineBreakMode = .byWordWrapping
    let s = NSAttributedString(string: text, attributes: [.font: f, .paragraphStyle: style])
    return ceil(s.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
}

func roundedPath(_ r: NSRect, _ radius: Double) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

/// A scaled-up rendering of the app's actual overlay: blurred dark panel,
/// accent waveform bars, transcript text.
func drawHUD(at y: Double) {
    let w = W - margin * 2, h = 210.0
    let rect = NSRect(x: margin, y: y, width: w, height: h)

    NSColor(calibratedWhite: 1, alpha: 0.07).setFill()
    roundedPath(rect, 44).fill()
    NSColor(calibratedWhite: 1, alpha: 0.13).setStroke()
    let border = roundedPath(rect.insetBy(dx: 1, dy: 1), 43)
    border.lineWidth = 2
    border.stroke()

    // Waveform column, mirroring the live level meter.
    let levels: [Double] = [0.25, 0.55, 0.9, 0.6, 1.0, 0.45, 0.75, 0.35, 0.6]
    let barW = 9.0, gap = 13.0
    var x = rect.minX + 56
    accent.setFill()
    for level in levels {
        let bh = max(14.0, level * 96)
        roundedPath(NSRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh), barW / 2).fill()
        x += barW + gap
    }

    let textX = x + 34
    let textW = rect.maxX - textX - 48
    let f = font(38, .medium)
    let th = height("Hold right ⌥, speak, and release…", font: f, width: textW)
    _ = draw("Hold right ⌥, speak, and release…", font: f, color: ink,
             in: NSRect(x: textX, y: rect.midY - th / 2, width: textW, height: th))
}

/// Latency comparison, using the numbers measured by --selftest.
func drawBars(at y: Double) {
    let rows: [(String, String, Double, NSColor)] = [
        ("Apple SpeechAnalyzer", "0.4s", 0.4 / 4.2, accent),
        ("Whisper large-v3-turbo", "4.2s", 1.0, NSColor(calibratedWhite: 0.42, alpha: 1)),
    ]
    let fullW = W - margin * 2
    var cursor = y
    for (label, value, fraction, color) in rows.reversed() {
        let barH = 76.0
        NSColor(calibratedWhite: 1, alpha: 0.08).setFill()
        roundedPath(NSRect(x: margin, y: cursor, width: fullW, height: barH), barH / 2).fill()
        color.setFill()
        roundedPath(NSRect(x: margin, y: cursor, width: max(barH, fullW * fraction), height: barH), barH / 2).fill()

        let vf = font(40, .heavy)
        let vw = 200.0
        _ = draw(value, font: vf, color: ink,
                 in: NSRect(x: W - margin - vw - 34, y: cursor + barH / 2 - 26, width: vw, height: 60),
                 align: .right)

        let lf = font(32, .medium)
        _ = draw(label, font: lf, color: muted,
                 in: NSRect(x: margin + 6, y: cursor + barH + 16, width: fullW, height: 46))
        cursor += barH + 84
    }
}

func drawCTA(at y: Double) {
    let w = W - margin * 2
    let rect = NSRect(x: margin, y: y, width: w, height: 118)
    accent.setFill()
    roundedPath(rect, 30).fill()
    let f = font(40, .heavy)
    _ = draw("github.com/Vrun1506/local-whisper-flow", font: f, color: .white,
             in: NSRect(x: rect.minX, y: rect.midY - 26, width: w, height: 60), align: .center)
}

// MARK: Render

for scene in scenes {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .calibratedRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Background: deep navy with a soft accent bloom behind the headline.
    NSGradient(colors: [NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.08, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.14, alpha: 1)])?
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
    NSGradient(colors: [accent.withAlphaComponent(0.20), accent.withAlphaComponent(0.0)])?
        .draw(in: NSRect(x: -220, y: H * 0.44, width: W + 440, height: H * 0.52), relativeCenterPosition: .zero)

    // Headline block, optically centred.
    let contentW = W - margin * 2
    let headFont = font(scene.headline.count > 40 ? 92 : 116, .heavy)
    let headH = height(scene.headline, font: headFont, width: contentW, lineSpacing: 8)
    let subFont = font(40, .medium)
    let subH = scene.sub.map { height($0, font: subFont, width: contentW, lineSpacing: 6) } ?? 0

    var blockH = headH + (subH > 0 ? subH + 40 : 0)
    if scene.kicker != nil { blockH += 78 }
    switch scene.extra {
    case .hud:  blockH += 210 + 72
    case .bars: blockH += 320
    case .cta:  blockH += 118 + 56
    case .none: break
    }

    var y = (H - blockH) / 2 + blockH   // top of the block, drawing downward

    if let kicker = scene.kicker {
        y -= 52
        _ = draw(kicker.uppercased(), font: font(34, .heavy), color: warm,
                 in: NSRect(x: margin, y: y, width: contentW, height: 52))
        y -= 26
    }

    y -= headH
    _ = draw(scene.headline, font: headFont, color: ink,
             in: NSRect(x: margin, y: y, width: contentW, height: headH), lineSpacing: 8)

    if let sub = scene.sub {
        y -= 40 + subH
        _ = draw(sub, font: subFont, color: muted,
                 in: NSRect(x: margin, y: y, width: contentW, height: subH), lineSpacing: 6)
    }

    switch scene.extra {
    case .hud:  y -= 72 + 210;  drawHUD(at: y)
    case .bars: y -= 320;       drawBars(at: y)
    case .cta:  y -= 56 + 118;  drawCTA(at: y)
    case .none: break
    }

    // Persistent footer so the platform is unmissable even on a muted watch.
    _ = draw("WisprLocal  ·  for macOS", font: font(30, .semibold), color: muted,
             in: NSRect(x: margin, y: 96, width: contentW, height: 44), align: .center)

    NSGraphicsContext.restoreGraphicsState()

    let url = URL(fileURLWithPath: "\(outDir)/\(scene.name).png")
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: url)
        print("rendered \(scene.name).png")
    }
}
