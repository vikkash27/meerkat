import AppKit
import ScreenCaptureKit
import SwiftUI
import Vision

// MARK: - The call window (Google Meet in a browser, or the Meet app)

struct CallWindow: Equatable {
    let id: CGWindowID, app: String, title: String, bounds: CGRect   // bounds: top-left origin, global
    var label: String { title.isEmpty ? app : "\(app) — \(title)" }
    /// AppKit (bottom-left origin) frame.
    var frame: NSRect { NSRect(x: bounds.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - bounds.maxY, width: bounds.width, height: bounds.height) }

    static func all() -> [CallWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { i in
            guard i[kCGWindowOwnerPID as String] as? pid_t != getpid(), i[kCGWindowLayer as String] as? Int == 0,
                  let raw = i[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: raw),
                  b.width > 200, b.height > 150, let id = i[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return CallWindow(id: id, app: i[kCGWindowOwnerName as String] as? String ?? "App", title: i[kCGWindowName as String] as? String ?? "", bounds: b)
        }
    }

    /// Meet tabs are titled "Meet – abc-defg-hij" (or "Meet - …").
    static func findCall() -> CallWindow? {
        all().first { $0.title.hasPrefix("Meet – ") || $0.title.hasPrefix("Meet - ") || $0.title.contains("meet.google.com") }
    }

    func capture() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let w = content.windows.first(where: { $0.windowID == id }) else { throw BSError("Call window is gone.") }
        let config = SCStreamConfiguration()
        let scale = min(1, 1280 / max(w.frame.width, w.frame.height))
        config.width = Int(w.frame.width * scale); config.height = Int(w.frame.height * scale)
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: config)
    }
}

// MARK: - Faces: who is where in the call window

enum Faces {
    /// Normalised rects, top-left origin. Ignores tiny faces (thumbnails, posters).
    static func detect(_ image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).filter { $0.confidence > 0.5 && $0.boundingBox.width > 0.03 }.map {
            let b = $0.boundingBox
            return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
        }
    }

    /// Two-person Meet: the big tile is them, your self-view is the small one. `swap` fixes equal-size tiled layouts.
    static func assign(_ faces: [CGRect], swap: Bool) -> [Speaker: CGRect] {
        let sorted = faces.sorted { $0.width * $0.height > $1.width * $1.height }
        if sorted.count == 1, let f = sorted.first, f.midX > 0.6, f.midY > 0.55, f.width * f.height < 0.03 {
            return [swap ? .them : .me: f]   // their camera is off; only your self-view is showing
        }
        var out: [Speaker: CGRect] = [:]
        if sorted.count > 0 { out[swap ? .me : .them] = sorted[0] }
        if sorted.count > 1 { out[swap ? .them : .me] = sorted[1] }
        return out
    }

    /// Where to aim when no face is visible: centre of the window for them, Meet's self-view corner for you.
    static func fallback(_ speaker: Speaker) -> CGRect {
        speaker == .them ? CGRect(x: 0.38, y: 0.3, width: 0.24, height: 0.3) : CGRect(x: 0.76, y: 0.66, width: 0.14, height: 0.18)
    }
}

// MARK: - Overlay: a click-through layer over the call window where the 💩 flies

@MainActor
final class Overlay: ObservableObject {
    struct Particle { let emoji: String, angle, reach, orbit, tumble, size: Double }
    struct Burst: Identifiable {
        let speaker: Speaker
        let text: String
        var rehearsal = false
        let id = UUID()
        var start = Date()
        let particles: [Particle] = (0..<30).map { i in
            Particle(emoji: ["💩", "💩", "💩", "💩", "🐂", "🚩", "🤥"].randomElement()!,
                     angle: Double(i) / 30 * 2 * .pi + .random(in: -0.15...0.15), reach: .random(in: 1.0...1.9),
                     orbit: .random(in: 0.6...1.4) * (Bool.random() ? 1 : -1), tumble: .random(in: -3...3), size: .random(in: 26...52))
        }
    }
    static let duration = 5.5

    @Published private(set) var bursts: [Burst] = []
    @Published private(set) var faces: [Speaker: CGRect] = [:]
    @Published private(set) var target: CallWindow? = nil
    var swap = false { didSet { faces = Faces.assign(found, swap: swap) } }
    var scanning = false   // keep faces fresh while listening
    private var found: [CGRect] = []
    private var lastScan = Date.distantPast, busy = false
    private let panel: NSPanel

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: OverlayView(overlay: self))
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in MainActor.assumeIsolated { self.follow() } }
    }

    func attach(_ window: CallWindow?) { target = window; found = []; faces = [:]; follow() }

    func burst(_ speaker: Speaker, text: String, rehearsal: Bool = false) {
        bursts.append(Burst(speaker: speaker, text: text, rehearsal: rehearsal))
        lastScan = .distantPast; follow()
        NSSound(named: "Basso")?.play()
        Task { try? await Task.sleep(for: .seconds(Self.duration)); bursts.removeAll { Date().timeIntervalSince($0.start) >= Self.duration } }
    }

    /// Track the call window's position and, about once a second, where the faces are.
    private func follow() {
        guard let t = target, let w = CallWindow.all().first(where: { $0.id == t.id }) else {
            if scanning, let found = CallWindow.findCall(), found.id != target?.id { attach(found); return }   // Meet reopened
            // Rehearsal with no call window: burst over the screen. Real bursts wait for the call window.
            if bursts.contains(where: \.rehearsal), let screen = NSScreen.main?.frame {
                if panel.frame != screen { panel.setFrame(screen, display: true) }
                panel.level = .floating; panel.orderFrontRegardless()
            } else { panel.orderOut(nil) }
            return
        }
        panel.level = .normal
        if target != w { target = w }
        if panel.frame != w.frame { panel.setFrame(w.frame, display: true) }
        panel.order(.above, relativeTo: Int(w.id))   // just above the call window, so windows covering Meet still cover the 💩
        guard (scanning || !bursts.isEmpty), !busy, Date().timeIntervalSince(lastScan) > 1 else { return }
        busy = true; lastScan = Date()
        Task {
            defer { busy = false }
            guard let image = try? await w.capture() else { return }
            let detected = await Task.detached { Faces.detect(image) }.value
            guard target?.id == w.id else { return }   // window switched mid-scan
            found = detected
            faces = Faces.assign(found, swap: swap)
        }
    }
}

struct OverlayView: View {
    @ObservedObject var overlay: Overlay
    var body: some View {
        TimelineView(.animation(paused: overlay.bursts.isEmpty)) { timeline in
            Canvas { ctx, size in
                for b in overlay.bursts {
                    let t = timeline.date.timeIntervalSince(b.start)
                    guard t >= 0, t < Overlay.duration else { continue }
                    guard b.rehearsal || overlay.target != nil else { continue }
                    let face = (b.rehearsal && overlay.target == nil ? nil : overlay.faces[b.speaker]) ?? Faces.fallback(b.speaker)
                    Self.draw(b, face: CGRect(x: face.minX * size.width, y: face.minY * size.height, width: face.width * size.width, height: face.height * size.height), t: t, ctx: ctx, size: size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 0–0.45s burst out, then orbit the head, last 1.3s fall and fade.
    static func draw(_ b: Overlay.Burst, face f: CGRect, t: Double, ctx: GraphicsContext, size: CGSize) {
        let c = CGPoint(x: f.midX, y: f.midY), radius = max(f.width, f.height) * 0.7 + 24
        let fall = max(0, t - (Overlay.duration - 1.3)), fade = 1 - fall / 1.3
        let pop = 1 - pow(1 - min(1, t / 0.45), 3)

        var ring = ctx
        ring.opacity = fade * (0.55 + 0.35 * sin(t * 10))
        ring.stroke(Path(ellipseIn: f.insetBy(dx: -f.width * 0.25, dy: -f.height * 0.3)), with: .color(.red), lineWidth: 6)

        for p in b.particles {
            let a = p.angle + p.orbit * max(0, t - 0.45)
            let r = radius * p.reach * pop + sin(t * 3 + p.angle) * 6
            var g = ctx
            g.opacity = fade
            g.translateBy(x: c.x + cos(a) * r, y: c.y + sin(a) * r * 0.85 + 900 * fall * fall)
            g.rotate(by: .radians(p.tumble * t))
            g.scaleBy(x: max(0.01, pop), y: max(0.01, pop))
            g.draw(Text(p.emoji).font(.system(size: p.size)), at: .zero)
        }

        let stampIn = min(1, t / 0.25), s = 1.8 - 0.8 * stampIn
        var stamp = ctx
        stamp.opacity = fade * stampIn
        stamp.translateBy(x: min(max(c.x, 170), size.width - 170), y: max(50, f.minY - radius * 0.6))
        stamp.rotate(by: .degrees(-8)); stamp.scaleBy(x: s, y: s)
        stamp.draw(Text("BULLSH💩T!").font(.system(size: 46, weight: .black, design: .rounded)).foregroundStyle(.red), at: .zero)

        guard !b.text.isEmpty else { return }
        let note = ctx.resolve(Text("🧐 Actually: \(b.text)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
        let m = note.measure(in: CGSize(width: 340, height: 300))
        let box = CGRect(x: min(max(10, c.x - m.width / 2 - 12), size.width - m.width - 34),
                         y: min(size.height - m.height - 30, f.maxY + radius * 0.55), width: m.width + 24, height: m.height + 16)
        var card = ctx
        card.opacity = fade * min(1, max(0, (t - 0.4) / 0.3))
        card.fill(Path(roundedRect: box, cornerRadius: 12), with: .color(.black.opacity(0.78)))
        card.draw(note, in: box.insetBy(dx: 12, dy: 8))
    }
}
