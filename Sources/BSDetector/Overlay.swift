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

// MARK: - Overlay: a click-through evidence layer over the call window

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
            Particle(emoji: ["💩", "💩", "🐂", "🚩"].randomElement()!,
                     angle: Double(i) / 30 * 2 * .pi + .random(in: -0.15...0.15), reach: .random(in: 1.0...1.9),
                     orbit: .random(in: 0.6...1.4) * (Bool.random() ? 1 : -1), tumble: .random(in: -3...3), size: .random(in: 26...52))
        }
    }
    static let duration = 5.5

    @Published private(set) var bursts: [Burst] = []
    @Published private(set) var faces: [Speaker: CGRect] = [:]
    @Published private(set) var target: CallWindow? = nil
    @Published private(set) var listening = false
    @Published private(set) var signal: LiveSignal?
    @Published private(set) var signals: [Speaker: LiveSignal] = [:]
    @Published private(set) var signalDates: [Speaker: Date] = [:]
    @Published private(set) var settling = false
    @Published private(set) var flaggedLedger = FlaggedClaimLedger()
    var flaggedClaims: [FlaggedClaim] { flaggedLedger.records }
    var hasDemoFlags: Bool { flaggedClaims.contains { $0.isDemo } }
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

    func setListening(_ listening: Bool) {
        self.listening = listening
        scanning = listening
        if !listening { signal = nil; signals = [:]; signalDates = [:]; settling = false; resetFlaggedClaims() }
        follow()
    }

    func recordFlaggedClaim(_ record: FlaggedClaim) {
        flaggedLedger.add(record)
        follow()
    }

    func resetFlaggedClaims() {
        flaggedLedger.reset()
        bursts = []
        if signal?.isDemo == true { signal = nil }
        for speaker in Speaker.allCases where signals[speaker]?.isDemo == true {
            signals[speaker] = nil; signalDates[speaker] = nil
        }
        follow()
    }

    func clearPresentation() {
        flaggedLedger.reset(); bursts = []; signal = nil; signals = [:]
        signalDates = [:]; settling = false
        follow()
    }

    func updateSignal(_ signal: LiveSignal) {
        self.signal = signal
        signals[signal.speaker] = signal
        signalDates[signal.speaker] = Date()
        settling = true
        let updated = signalDates[signal.speaker]
        Task {
            try? await Task.sleep(for: .seconds(9))
            guard signalDates[signal.speaker] == updated else { return }
            settling = signalDates.values.contains { Date().timeIntervalSince($0) < 9 }
        }
        lastScan = .distantPast
        follow()
    }

    func burst(_ speaker: Speaker, text: String, rehearsal: Bool = false) {
        bursts.append(Burst(speaker: speaker, text: text, rehearsal: rehearsal))
        if rehearsal {
            let demo = signal.flatMap { $0.isDemo && $0.speaker == speaker ? $0 : nil }
            updateSignal(LiveSignal(speaker: speaker, phase: "Rehearsal · simulated evidence",
                                    claim: demo?.claim ?? text, outcome: demo?.outcome ?? .bs,
                                    strength: demo?.strength, sourceCount: demo?.sourceCount ?? 0,
                                    latency: demo?.latency, detail: demo?.detail ?? text, sourceURL: nil))
        } else if signal == nil {
            updateSignal(LiveSignal(speaker: speaker, phase: "Review evidence after the call", claim: text, outcome: .bs, detail: text))
        }
        lastScan = .distantPast; follow()
        let updated = signalDates[speaker]
        Task {
            try? await Task.sleep(for: .seconds(Self.duration))
            bursts.removeAll { Date().timeIntervalSince($0.start) >= Self.duration }
            if rehearsal && !listening && signalDates[speaker] == updated {
                signal = nil; signals[speaker] = nil; signalDates[speaker] = nil; settling = false
                follow()
            }
        }
    }

    /// Track the call window's position and, about once a second, where the faces are.
    private func follow() {
        guard let t = target, let w = CallWindow.all().first(where: { $0.id == t.id }) else {
            if scanning, let found = CallWindow.findCall(), found.id != target?.id { attach(found); return }   // Meet reopened
            if target != nil { target = nil; found = []; faces = [:] }   // clear a vanished call window
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
        panel.order(.above, relativeTo: Int(w.id))   // windows covering Meet still cover the overlay
        guard (scanning || signal != nil || !bursts.isEmpty), !busy, Date().timeIntervalSince(lastScan) > 1 else { return }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var reduced: Bool { reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var animated: Bool {
        !reduced && (overlay.settling || !overlay.bursts.isEmpty || overlay.signals.values.contains { $0.outcome == .checking })
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { timeline in
                    Canvas { ctx, size in
                        var safe = ctx
                        // Meet's microphone/camera/hang-up controls always stay clear.
                        safe.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - 120))))
                        for speaker in Speaker.allCases {
                            let records = overlay.flaggedClaims.filter { $0.speaker == speaker }
                            // A demo is its own scene, never added to the live count.
                            let real = records.filter { !$0.isDemo }
                            let displayed = records.last?.isDemo == true ? records.filter { $0.isDemo } : real
                            guard !displayed.isEmpty, overlay.target != nil || displayed[0].isDemo else { continue }
                            let face = overlay.faces[speaker] ?? Faces.fallback(speaker)
                            let frame = CGRect(x: face.minX * size.width, y: face.minY * size.height,
                                               width: face.width * size.width, height: face.height * size.height)
                            BSOverlay.draw(records: displayed, face: frame, size: size, date: timeline.date, reduced: reduced, ctx: safe)
                        }
                        for speaker in Speaker.allCases {
                            guard let signal = overlay.signals[speaker],
                                  let date = overlay.signalDates[speaker] else { continue }
                            let age = timeline.date.timeIntervalSince(date)
                            guard signal.outcome == .checking || age < 9 else { continue }
                            let face = overlay.faces[speaker] ?? Faces.fallback(speaker)
                            let frame = CGRect(x: face.minX * size.width, y: face.minY * size.height,
                                               width: face.width * size.width, height: face.height * size.height)
                            Self.drawReticle(signal, face: frame, age: reduced ? 0 : age, reduced: reduced, ctx: safe)
                        }
                        for b in overlay.bursts {
                            let t = timeline.date.timeIntervalSince(b.start)
                            guard t >= 0, t < Overlay.duration, b.rehearsal || overlay.target != nil else { continue }
                            let face = (b.rehearsal && overlay.target == nil ? nil : overlay.faces[b.speaker]) ?? Faces.fallback(b.speaker)
                            let frame = CGRect(x: face.minX * size.width, y: face.minY * size.height,
                                               width: face.width * size.width, height: face.height * size.height)
                            Self.draw(b, face: frame, t: reduced ? 0.5 : t, ctx: safe, size: size, reduced: reduced)
                        }
                    }
                }
                if geometry.size.height >= 280 && (overlay.listening || overlay.signal != nil || !overlay.bursts.isEmpty) {
                    LiveHUD(signal: overlay.signal, listening: overlay.listening)
                        .padding(.top, geometry.size.height > 400 ? 82 : 18)
                        .padding(.trailing, 18)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Peripheral brackets and one searching arc leave the face unobscured.
    static func drawReticle(_ signal: LiveSignal, face: CGRect, age: Double, reduced: Bool, ctx: GraphicsContext) {
        let rect = face.insetBy(dx: -18, dy: -20)
        let checking = signal.outcome == .checking
        let fade = checking || reduced ? 1.0 : min(1, max(0, (9 - age) / 1.5))
        let length = min(22, rect.width * 0.17)
        var corners = Path()
        for (point, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
            (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)
        ] {
            corners.move(to: CGPoint(x: point.x, y: point.y + dy * length))
            corners.addLine(to: point)
            corners.addLine(to: CGPoint(x: point.x + dx * length, y: point.y))
        }
        var g = ctx
        g.opacity = fade * 0.90
        g.stroke(corners, with: .color(signal.color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

        if checking {
            var arc = Path()
            let angle = reduced ? -55 : age * 65 - 90
            arc.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: max(rect.width, rect.height) * 0.58,
                       startAngle: .degrees(angle), endAngle: .degrees(angle + 48), clockwise: false)
            g.opacity = 0.50
            g.stroke(arc, with: .color(signal.color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            if !reduced {
                var scan = Path()
                let y = rect.minY + (sin(age * 1.1) + 1) / 2 * rect.height
                scan.move(to: CGPoint(x: rect.minX - 4, y: y)); scan.addLine(to: CGPoint(x: rect.minX + 2, y: y))
                scan.move(to: CGPoint(x: rect.maxX - 2, y: y)); scan.addLine(to: CGPoint(x: rect.maxX + 4, y: y))
                g.stroke(scan, with: .color(signal.color), lineWidth: 2)
            }
        }

        let label = checking ? "CHECKING" : signal.title.uppercased()
        let text = Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(signal.color)
        let box = CGRect(x: rect.minX, y: max(6, rect.minY - 19), width: checking ? 65 : 152, height: 16)
        g.opacity = fade
        g.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(HUDPalette.ink.opacity(0.85)))
        g.draw(text, at: CGPoint(x: box.minX + 7, y: box.midY), anchor: .leading)
    }

    /// The playful effect is reserved for an explicit rehearsal.
    static func draw(_ b: Overlay.Burst, face f: CGRect, t: Double, ctx: GraphicsContext, size: CGSize, reduced: Bool = false) {
        guard b.rehearsal else { return }
        let c = CGPoint(x: f.midX, y: f.midY), radius = max(f.width, f.height) * 0.7 + 24
        let fall = max(0, t - (Overlay.duration - 1.3)), fade = 1 - fall / 1.3
        let pop = 1 - pow(1 - min(1, t / 0.45), 3)

        for p in reduced ? [] : b.particles {
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
        stamp.scaleBy(x: s, y: s)
        stamp.draw(Text("REHEARSAL · CLAIM FLAGGED").font(.system(size: 14, weight: .bold)).foregroundStyle(HUDPalette.coral), at: .zero)
    }
}
