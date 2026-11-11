import AppKit
import SwiftUI

/// Live evidence about a claim. Strength is a sourced evidence score in 0...1,
/// never a probability that a person is lying. Unknown strength stays unknown.
struct LiveSignal: Equatable {
    let speaker: Speaker
    let phase: String
    let claim: String
    let outcome: Outcome
    let strength: Double?
    let sourceCount: Int
    let latency: Double?
    let detail: String?
    let sourceURL: String?

    init(speaker: Speaker, phase: String, claim: String, outcome: Outcome,
         strength: Double? = nil, sourceCount: Int = 0,
         latency: Double? = nil, detail: String? = nil, sourceURL: String? = nil) {
        self.speaker = speaker; self.phase = phase; self.claim = claim; self.outcome = outcome
        self.strength = strength.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.sourceCount = max(0, sourceCount)
        self.latency = latency.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.detail = detail
        if let raw = sourceURL, let url = URL(string: raw),
           ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil {
            self.sourceURL = url.absoluteString
        } else { self.sourceURL = nil }
    }

    var isDemo: Bool { phase.lowercased().contains("rehearsal") || phase.lowercased().hasPrefix("demo") }
    var sourceDomain: String? {
        guard !isDemo, let sourceURL, let host = URL(string: sourceURL)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    var displayPhase: String {
        switch phase.lowercased() {
        case "searching": return "Parallel searching"
        case "reviewing": return "Reviewing sources"
        case "deciding": return "Comparing evidence"
        default: return phase.isEmpty ? title : phase
        }
    }

    var color: Color {
        switch outcome {
        case .checking: return HUDPalette.cyan
        case .ok: return HUDPalette.mint
        case .bs: return HUDPalette.coral
        case .overturned: return HUDPalette.amber
        case .unsure, .failed: return HUDPalette.slate
        }
    }

    var title: String {
        switch outcome {
        case .checking: return "Checking claim"
        case .ok: return "Evidence supports claim"
        case .bs: return "Claim flagged"
        case .overturned: return "Evidence is mixed"
        case .unsure: return "Not verified"
        case .failed: return "Check interrupted"
        }
    }

    var symbol: String {
        switch outcome {
        case .checking: return "viewfinder"
        case .ok: return "checkmark.seal.fill"
        case .bs: return "flag.fill"
        case .overturned: return "arrow.triangle.branch"
        case .unsure: return "questionmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    var shortText: String {
        let correction = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = outcome == .checking || correction.isEmpty ? claim : correction
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 100 ? String(flat.prefix(99)) + "…" : flat
    }
}

enum HUDPalette {
    static let ink = Color(red: 0.045, green: 0.065, blue: 0.085)
    static let cyan = Color(red: 0.56, green: 0.86, blue: 0.94)
    static let mint = Color(red: 0.54, green: 0.89, blue: 0.73)
    static let coral = Color(red: 1.0, green: 0.59, blue: 0.49)
    static let amber = Color(red: 0.98, green: 0.78, blue: 0.43)
    static let slate = Color(red: 0.65, green: 0.72, blue: 0.78)
    static let secondary = Color(red: 0.74, green: 0.80, blue: 0.83)
}

/// A silent, glanceable receipt. The call stays the main event.
struct LiveHUD: View {
    let signal: LiveSignal?
    let listening: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { signal?.color ?? HUDPalette.mint }
    private var moving: Bool {
        signal?.outcome == .checking && !reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                HUDMeerkatIcon().frame(width: 20, height: 20)
                Text("meerkat").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if signal?.outcome == .checking && signal?.isDemo != true {
                    Text("Parallel").font(.system(size: 9, weight: .medium))
                        .foregroundStyle(HUDPalette.secondary)
                }
                Circle().fill(signal?.isDemo == true ? HUDPalette.amber : listening ? HUDPalette.mint : HUDPalette.slate).frame(width: 4, height: 4)
                Text(signal?.isDemo == true ? "DEMO" : listening ? "LIVE" : "RECEIPT")
                    .font(.system(size: 9, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(HUDPalette.secondary)
            }

            if let signal {
                HStack(spacing: 6) {
                    Image(systemName: signal.symbol).font(.system(size: 11, weight: .semibold))
                    Text(signal.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(signal.speaker.rawValue).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(HUDPalette.secondary)
                }
                .foregroundStyle(tint)
                Text(signal.shortText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(1).truncationMode(.tail)
                evidenceRow(signal)
                HStack(spacing: 5) {
                    if let domain = signal.sourceDomain, signal.outcome != .checking {
                        Image(systemName: "link").foregroundStyle(tint)
                        Text(domain).lineLimit(1).truncationMode(.middle)
                    } else {
                        if signal.outcome == .checking && !signal.isDemo {
                            Image(systemName: "globe").foregroundStyle(HUDPalette.cyan)
                        }
                        Text(signal.displayPhase).lineLimit(1)
                    }
                    Spacer(minLength: 3)
                    if let latency = signal.latency {
                        Text(String(format: "%.1fs", latency)).monospacedDigit()
                    }
                    Text("·")
                    Text(signal.sourceCount == 1 ? "1 source" : "\(signal.sourceCount) sources").monospacedDigit()
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(HUDPalette.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").foregroundStyle(HUDPalette.mint)
                    Text(listening ? "Listening for factual claims" : "Ready for the call")
                        .foregroundStyle(.white)
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 320, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 15)
                .fill(HUDPalette.ink.opacity(0.95))
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.8))
                        .frame(width: 34, height: 2).padding(.top, 1)
                }
        }
        .shadow(color: .black.opacity(0.30), radius: 15, x: 0, y: 5)
        .animation(reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeOut(duration: 0.22), value: signal?.outcome)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(signal.map { "Meerkat. \($0.isDemo ? "Demo. " : "")\($0.title). \($0.shortText). \($0.sourceCount) sources. \($0.sourceDomain ?? $0.displayPhase)." } ?? "Meerkat. Listening for factual claims.")
    }

    private func evidenceRow(_ signal: LiveSignal) -> some View {
        HStack(spacing: 8) {
            Text("EVIDENCE").font(.system(size: 8, weight: .semibold)).tracking(0.8)
                .foregroundStyle(HUDPalette.secondary)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving)) { timeline in
                let position = Int(timeline.date.timeIntervalSinceReferenceDate * 5) % 12
                HStack(spacing: 3) {
                    ForEach(0..<12, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(segmentColor(signal, index: index, position: position))
                            .frame(height: 5)
                    }
                }
            }
            Text(signal.strength.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(signal.strength == nil ? HUDPalette.secondary : tint)
                .frame(width: 28, alignment: .trailing)
        }
        .accessibilityLabel(signal.strength.map { "Evidence strength \(Int(($0 * 100).rounded())) percent" } ?? "Evidence strength not yet known")
    }

    private func segmentColor(_ signal: LiveSignal, index: Int, position: Int) -> Color {
        guard let strength = signal.strength else {
            // A moving neutral scan means work in progress, not a measured zero.
            return HUDPalette.slate.opacity(moving && index == position ? 0.8 : 0.20)
        }
        return index < Int((strength * 12).rounded()) ? tint : HUDPalette.slate.opacity(0.20)
    }
}

/// The incumbent sentry's tapered face, reduced to a crisp 20-point mark.
struct HUDMeerkatIcon: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 18
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: (18 - y) * scale) }
            func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x * scale, y: (18 - y - h) * scale, width: w * scale, height: h * scale))
            }
            let fur = Color(red: 0.87, green: 0.70, blue: 0.48)
            let mask = Color(red: 0.30, green: 0.20, blue: 0.13)
            var head = Path()
            head.move(to: p(9, 15.6))
            head.addCurve(to: p(13.6, 10.6), control1: p(12.2, 15.6), control2: p(13.6, 13.6))
            head.addCurve(to: p(9, 1.2), control1: p(13.6, 6.8), control2: p(10.6, 2.2))
            head.addCurve(to: p(4.4, 10.6), control1: p(7.4, 2.2), control2: p(4.4, 6.8))
            head.addCurve(to: p(9, 15.6), control1: p(4.4, 13.6), control2: p(5.8, 15.6))
            context.fill(oval(2.9, 10, 2.6, 2.6).union(oval(12.5, 10, 2.6, 2.6)), with: .color(mask))
            context.fill(head, with: .color(fur))
            context.fill(oval(6.6, 1.8, 4.8, 7), with: .color(Color(red: 0.97, green: 0.88, blue: 0.74)))
            context.fill(oval(5.4, 8.4, 3.2, 3.8).union(oval(9.4, 8.4, 3.2, 3.8)), with: .color(mask))
            context.fill(oval(8, 1.2, 2, 1.6), with: .color(mask))
            context.fill(oval(6.4, 9.9, 1.2, 1.6).union(oval(10.4, 9.9, 1.2, 1.6)), with: .color(.white))
        }
        .accessibilityHidden(true)
    }
}
