import SwiftUI

/// Granola-style side panel: live transcript, with every fact-check hanging off the line that triggered it.
@available(macOS 26.0, *)
struct TranscriptView: View {
    @ObservedObject var call: Call
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(call.listening ? .red : .secondary).frame(width: 8, height: 8)
                Text(call.status).font(.callout).lineLimit(2)
                Spacer()
                ForEach(Speaker.allCases, id: \.self) { s in
                    Text("\(s.rawValue) 💩\(call.score[s] ?? 0)").font(.callout.monospacedDigit().bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(s.tint.opacity(0.15), in: Capsule())
                }
            }
            .padding(12)
            HStack {
                Button(call.listening ? "Stop Listening" : "Start Listening", action: toggle)
                    .disabled(call.busy)
                Spacer()
            }.padding(.horizontal, 12).padding(.bottom, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if call.lines.isEmpty && call.live.isEmpty {
                            Text(call.listening ? "Listening for speech. Claims get checked against the web; BS gets 💩." : "Open a Meet call or click Start Listening, then talk. Claims get checked against the web; BS gets 💩.")
                                .foregroundStyle(.secondary).padding(.top, 40)
                        }
                        ForEach(call.lines) { LineView(line: $0) }
                        ForEach(Speaker.allCases, id: \.self) { s in
                            if let text = call.live[s], !text.isEmpty {
                                Text("\(s.rawValue): \(text)").italic().foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(12)
                }
                .onChange(of: call.lines.count + call.lines.reduce(0) { $0 + $1.checks.count }) { proxy.scrollTo("end") }
                .onChange(of: call.live.values.joined()) { proxy.scrollTo("end") }
            }
        }
        .frame(minWidth: 340, minHeight: 420)
    }
}

extension Speaker {
    var tint: Color { self == .me ? .blue : .orange }
}

@available(macOS 26.0, *)
private struct LineView: View {
    let line: Call.Line
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.speaker.rawValue).font(.caption.bold()).foregroundStyle(line.speaker.tint)
            Text(line.text).textSelection(.enabled)
            ForEach(line.checks) { CheckView(check: $0) }
        }
    }
}

@available(macOS 26.0, *)
private struct CheckView: View {
    let check: Call.Check
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(icon) \(title)").font(.callout.bold())
            Text(check.claim).font(.callout).foregroundStyle(.secondary)
            if let v = check.verdict, check.outcome != .ok { Text("Prosecutor: \(v.correction)").font(.caption) }
            if let d = check.defense { Text("Defense: \(d.reason)").font(.caption) }
            if let e = check.error { Text(e).font(.caption).foregroundStyle(.red) }
            if let s = check.verdict?.source, let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                Link(url.host() ?? s, destination: url).font(.caption)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch check.outcome { case .checking: "🔎"; case .bs: "💩"; case .ok: "✅"; case .unsure: "🤷"; case .overturned: "⚖️"; case .failed: "⚠️" }
    }
    private var title: String {
        switch check.outcome {
        case .checking: "Checking…"
        case .bs: "BULLSHIT"
        case .ok: "Checks out"
        case .unsure: "Can't verify"
        case .overturned: "Flagged, but the defense won"
        case .failed: "Check failed"
        }
    }
    private var tint: Color {
        switch check.outcome { case .bs: .red; case .ok: .green; case .overturned: .yellow; default: .gray }
    }
}
