import AppKit
import SwiftUI

/// One completed flagged claim. Its stable check ID prevents repeated events
/// from increasing the count; simulated records have their own history.
struct FlaggedClaim: Identifiable, Equatable {
    let id: UUID
    let speaker: Speaker
    let claim: String
    let correction: String
    let sourceURL: String?
    let isDemo: Bool

    init(id: UUID, speaker: Speaker, claim: String, correction: String,
         sourceURL: String? = nil, isDemo: Bool = false) {
        self.id = id; self.speaker = speaker; self.claim = claim
        self.correction = correction; self.isDemo = isDemo
        if !isDemo, let sourceURL, let url = URL(string: sourceURL),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil {
            self.sourceURL = url.absoluteString
        } else { self.sourceURL = nil }
    }

    var domain: String? {
        guard let sourceURL, let host = URL(string: sourceURL)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Value-only ledger: safe to exercise from the CLI without creating a panel,
/// starting a capture session, or mixing a rehearsal with a live call.
struct FlaggedClaimLedger {
    private(set) var records: [FlaggedClaim] = []

    mutating func add(_ record: FlaggedClaim) {
        guard record.isDemo || record.sourceURL != nil else { return }
        if let index = records.firstIndex(where: { $0.id == record.id && $0.isDemo == record.isDemo }) {
            records[index] = record
        } else { records.append(record) }
    }

    mutating func reset() { records = [] }
    func count(for speaker: Speaker, isDemo: Bool = false) -> Int {
        records.filter { $0.speaker == speaker && $0.isDemo == isDemo }.count
    }
    func crownCount(for speaker: Speaker, isDemo: Bool = false) -> Int {
        min(10, count(for: speaker, isDemo: isDemo))
    }
    /// Newest first. Real rap sheets contain linked evidence; demo rows say so.
    func last4(for speaker: Speaker, isDemo: Bool = false) -> [FlaggedClaim] {
        Array(records.filter { $0.speaker == speaker && $0.isDemo == isDemo && (isDemo || $0.domain != nil) }.suffix(4).reversed())
    }
}

/// The reference's playful scene, with a count rather than a lie probability.
enum BSOverlay {
    static func draw(records: [FlaggedClaim], face: CGRect, size: CGSize,
                     date: Date, reduced: Bool, ctx: GraphicsContext) {
        guard !records.isEmpty, size.width > 240, size.height > 260 else { return }
        let count = records.count
        let demo = records[0].isDemo
        let safe = CGRect(x: 12, y: 78, width: size.width - 24, height: max(0, size.height - 210))
        guard safe.height > 70 else { return }
        let color = count >= 12 ? HUDPalette.coral : HUDPalette.amber
        let time = reduced ? 0 : date.timeIntervalSinceReferenceDate

        drawCrown(count: count, face: face, safe: safe, time: time, reduced: reduced, ctx: ctx)

        let meterHeight = min(174, max(98, face.height * 0.72), safe.height - 22)
        let right = face.maxX + 24
        let x = right + 122 < safe.maxX ? right : max(safe.minX, face.minX - 46)
        let hudBottom: CGFloat = size.height > 400 ? 222 : 158
        let minimumY = x > size.width - 350 ? max(safe.minY + 20, hudBottom + 8) : safe.minY + 20
        let y = min(max(face.minY + 12, minimumY), safe.maxY - meterHeight - 18)
        let meter = CGRect(x: x, y: y, width: 22, height: meterHeight)
        drawMeter(count: count, demo: demo, rect: meter, color: color,
                  time: time, reduced: reduced, safe: safe, ctx: ctx)

        // Source-free real results never enter the sourced rap sheet.
        let receipts = Array(records.filter { $0.isDemo || $0.domain != nil }.suffix(4).reversed())
        guard !receipts.isEmpty else { return }
        let width = min(252, max(180, size.width * 0.29))
        let height = CGFloat(36 + receipts.count * 42)
        let leftSpace = face.minX - safe.minX
        let rightSpace = safe.maxX - face.maxX
        // Put receipts outside the face. On tight layouts, omit the sheet;
        // the count and crown still fit without covering the speaker.
        guard max(leftSpace, rightSpace) >= width + 12 else { return }
        let sheetX = leftSpace >= width + 12 ? safe.minX : safe.maxX - width
        let sheetTop = sheetX > size.width - 350 ? max(safe.minY + 130, hudBottom + 8) : safe.minY + 130
        let sheetY = min(max(face.midY + 20, sheetTop), safe.maxY - height)
        guard sheetY >= safe.minY else { return }
        drawSheet(receipts, total: count, demo: demo,
                  box: CGRect(x: sheetX, y: sheetY, width: width, height: height), ctx: ctx)
    }

    private static func drawCrown(count: Int, face: CGRect, safe: CGRect, time: Double,
                                  reduced: Bool, ctx: GraphicsContext) {
        let visible = min(10, count)
        let desiredGlyph = min(39, max(22, face.width * 0.20))
        let capacities = visible <= 6 ? [3, 2, 1] : [4, 3, 2, 1]
        var pending = visible
        var rows = 0
        for capacity in capacities where pending > 0 { rows += 1; pending -= capacity }
        let headroom = face.minY - safe.minY
        guard headroom > 18 else { return }
        let glyph = min(desiredGlyph, headroom / (CGFloat(rows) * 0.67 + 1))
        let crownHeight = CGFloat(rows) * glyph * 0.66 + glyph * 0.45
        let baseY = face.minY - glyph * 0.24
        let centerX = min(max(face.midX, safe.minX + glyph * 2), safe.maxX - glyph * 2)
        var remaining = visible
        for row in 0..<rows {
            let items = min(capacities[row], remaining)
            remaining -= items
            for index in 0..<items {
                let x = centerX + (CGFloat(index) - CGFloat(items - 1) / 2) * glyph * 0.81
                let y = baseY - CGFloat(row) * glyph * 0.67
                var g = ctx
                g.addFilter(.shadow(color: .black.opacity(0.34), radius: 3, x: 0, y: 3))
                g.draw(Text("💩").font(.system(size: glyph)), at: CGPoint(x: x, y: y))
            }
        }
        if count > 10 {
            let extra = Text("+\(count - 10)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            ctx.draw(extra, at: CGPoint(x: centerX + glyph * 1.9, y: baseY - crownHeight / 2))
        }
        if !reduced {
            // Three bounded wisps, no full-window particles or flashing.
            for index in 0..<3 {
                var wisp = Path()
                let x = centerX + CGFloat(index - 1) * 13
                let top = max(safe.minY, baseY - crownHeight - 15)
                wisp.move(to: CGPoint(x: x, y: top + 15))
                wisp.addCurve(to: CGPoint(x: x + sin(time * 0.8 + Double(index)) * 4, y: top),
                              control1: CGPoint(x: x - 5, y: top + 10), control2: CGPoint(x: x + 5, y: top + 5))
                ctx.stroke(wisp, with: .color(HUDPalette.amber.opacity(0.20)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
    }

    private static func drawMeter(count: Int, demo: Bool, rect: CGRect, color: Color,
                                  time: Double, reduced: Bool, safe: CGRect, ctx: GraphicsContext) {
        let outline = Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 14)
        ctx.fill(outline, with: .color(HUDPalette.ink.opacity(0.94)))
        ctx.stroke(outline, with: .color(.white.opacity(0.19)), lineWidth: 1)
        let tube = rect.insetBy(dx: 3, dy: 4)
        let fill = min(1, Double(count) / 12)
        let level = tube.maxY - tube.height * fill
        var liquid = Path()
        liquid.move(to: CGPoint(x: tube.minX, y: level))
        liquid.addQuadCurve(to: CGPoint(x: tube.maxX, y: level),
                            control: CGPoint(x: tube.midX, y: level + (reduced ? 0 : sin(time * 1.6) * 3)))
        liquid.addLine(to: CGPoint(x: tube.maxX, y: tube.maxY))
        liquid.addLine(to: CGPoint(x: tube.minX, y: tube.maxY)); liquid.closeSubpath()
        var g = ctx
        g.clip(to: Path(roundedRect: tube, cornerRadius: 8))
        g.fill(liquid, with: .linearGradient(Gradient(colors: [color, Color(red: 0.46, green: 0.24, blue: 0.08)]),
                                           startPoint: CGPoint(x: tube.minX, y: level), endPoint: CGPoint(x: tube.maxX, y: tube.maxY)))
        for i in 1..<5 {
            var tick = Path(); let y = tube.minY + tube.height * CGFloat(i) / 5
            tick.move(to: CGPoint(x: tube.maxX - 3, y: y)); tick.addLine(to: CGPoint(x: tube.maxX, y: y))
            g.stroke(tick, with: .color(.white.opacity(0.32)), lineWidth: 1)
        }
        if !reduced && fill > 0.12 {
            for i in 0..<3 {
                let progress = (time * 0.15 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let y = tube.maxY - progress * tube.height * fill
                g.stroke(Path(ellipseIn: CGRect(x: tube.midX - 2 + Double(i % 2) * 3, y: y, width: 2, height: 3)),
                         with: .color(.white.opacity(0.24)), lineWidth: 0.7)
            }
        }
        ctx.draw(Text("\(count)").font(.system(size: 20, weight: .heavy)).foregroundStyle(.white),
                 at: CGPoint(x: rect.midX, y: rect.minY - 17))
        let label = count >= 12 ? "FULL OF 💩" : count >= 4 ? "FIBBER" : "GETTING MESSY"
        let badgeWidth: CGFloat = count >= 4 ? 100 : 112
        let badgeX = min(max(rect.maxX + 10, safe.minX), safe.maxX - badgeWidth)
        let badge = CGRect(x: badgeX, y: rect.minY + rect.height * 0.47, width: badgeWidth, height: 19)
        ctx.fill(Path(roundedRect: badge, cornerRadius: 9), with: .color(HUDPalette.ink.opacity(0.94)))
        ctx.draw(Text(label).font(.system(size: 8, weight: .bold)).foregroundStyle(color),
                 at: CGPoint(x: badge.midX, y: badge.midY))
        ctx.draw(Text(demo ? "DEMO FLAGS" : "FLAGGED CLAIMS").font(.system(size: 7, weight: .semibold)).foregroundStyle(HUDPalette.secondary),
                 at: CGPoint(x: rect.midX, y: rect.maxY + 14))
    }

    private static func drawSheet(_ records: [FlaggedClaim], total: Int, demo: Bool,
                                  box: CGRect, ctx: GraphicsContext) {
        var g = ctx
        g.addFilter(.shadow(color: .black.opacity(0.28), radius: 9, x: 0, y: 4))
        g.fill(Path(roundedRect: box, cornerRadius: 14), with: .color(HUDPalette.ink.opacity(0.96)))
        g.draw(Text(demo ? "DEMO RAP SHEET" : "RAP SHEET").font(.system(size: 8, weight: .bold)).foregroundStyle(HUDPalette.secondary),
               at: CGPoint(x: box.minX + 12, y: box.minY + 15), anchor: .leading)
        g.draw(Text("\(total) 💩").font(.system(size: 9, weight: .semibold)).foregroundStyle(HUDPalette.amber),
               at: CGPoint(x: box.maxX - 12, y: box.minY + 15), anchor: .trailing)
        for (index, record) in records.enumerated() {
            let y = box.minY + 33 + CGFloat(index) * 42
            let available = CGSize(width: box.width - 35, height: 13)
            g.draw(Text("💩").font(.system(size: 10)), at: CGPoint(x: box.minX + 14, y: y + 1))
            let claim = clipped(record.claim, limit: 44)
            let correction = clipped(record.correction, limit: 48)
            g.draw(g.resolve(Text(claim).font(.system(size: 10)).strikethrough(color: HUDPalette.coral).foregroundStyle(HUDPalette.secondary)),
                   in: CGRect(origin: CGPoint(x: box.minX + 25, y: y - 5), size: available))
            g.draw(g.resolve(Text(correction).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)),
                   in: CGRect(origin: CGPoint(x: box.minX + 25, y: y + 8), size: available))
            g.draw(Text(record.isDemo ? "Simulated evidence" : clipped(record.domain ?? "", limit: 34)).font(.system(size: 8)).foregroundStyle(HUDPalette.amber),
                   at: CGPoint(x: box.minX + 25, y: y + 27), anchor: .leading)
        }
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }
}
