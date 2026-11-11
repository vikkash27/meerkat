import AVFoundation
import CoreGraphics

/// The live call: transcript lines, claim checks and the BS scoreboard.
@available(macOS 26.0, *)
@MainActor
final class Call: ObservableObject {
    struct Check: Identifiable {
        let id = UUID()
        let claim: String
        var outcome = Outcome.checking
        var verdict: Verdict?
        var defense: Defense?
        var error: String?
        var phase = "Queued"
        var sourceCount = 0
        var startedAt = Date()
    }
    struct Line: Identifiable {
        let id = UUID()
        let speaker: Speaker
        let text: String
        let at: Date
        var checks: [Check] = []
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var live: [Speaker: String] = [:]   // volatile, still being recognised
    @Published private(set) var score: [Speaker: Int] = [:]
    @Published private(set) var listening = false
    @Published var status = "Not listening"
    var onBS: ((Speaker, Check, _ rehearsal: Bool) -> Void)?
    var onSignal: ((LiveSignal) -> Void)?

    private var audio: CallAudio?
    private var ears: [Transcriber] = []
    private var seen = Set<String>()     // speaker + claim, per session
    private var session = 0              // bumped on start/stop; late async work from an old session is dropped
    @Published private(set) var busy = false   // a start or stop is in flight
    /// With headphones the mic only hears you. Without them it also hears the other person, so drop near-copies of their lines.
    var headphones = true
    private var startFailure: String?    // a capture/transcription error that landed while start() was still running
    private var sessionStart = Date.distantPast
    private struct PendingCheck { let line: Line; let context: String; let session: Int }
    private var pendingChecks: [PendingCheck] = []
    private var checkTasks: [UUID: Task<Void, Never>] = [:]

    func start() async {
        guard !listening, !busy else { return }
        busy = true; defer { busy = false }
        session += 1; seen = []; startFailure = nil; sessionStart = Date()
        let current = session
        status = "Starting…"
        do {
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw BSError("Allow Microphone for BS Detector in System Settings.") }
            status = "Loading speech model…"
            let locale = try await Transcriber.locale()
            let failed: @MainActor (Error) -> Void = { [weak self] error in
                Task { await self?.died(current, "Transcription stopped: \(error.localizedDescription)") }
            }
            let me = try await Transcriber(.me, locale: locale, onText: { [weak self] in self?.heard(.me, $0, final: $1) }, onError: failed)
            ears = [me]   // so a failure below still tears it down
            let them = try await Transcriber(.them, locale: locale, onText: { [weak self] in self?.heard(.them, $0, final: $1) }, onError: failed)
            let audio = CallAudio()
            audio.onBuffer = { speaker, buffer in (speaker == .me ? me : them).feed(buffer) }
            audio.onStop = { [weak self] error in Task { @MainActor in await self?.died(current, "Capture stopped: \(error.localizedDescription)") } }
            self.audio = audio; ears = [me, them]
            try await audio.start()
            if let startFailure { throw BSError(startFailure) }
            listening = true
            status = OpenAI.key == nil || Parallel.key == nil ? "Listening · set OpenAI + Parallel keys to fact-check" : "Listening"
        } catch {
            await teardown()
            status = error.localizedDescription
        }
    }

    /// Capture or transcription died. Mid-start, let start() fail; afterwards, stop and say why.
    private func died(_ which: Int, _ message: String) async {
        guard session == which else { return }
        if busy { startFailure = message; return }
        await stop()
        status = message
    }

    func stop() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        await teardown()
    }

    private func teardown() async {
        session += 1
        pendingChecks.removeAll()
        for task in checkTasks.values { task.cancel() }
        checkTasks.removeAll()
        let (audio, ears) = (self.audio, self.ears)
        self.audio = nil; self.ears = []
        listening = false
        for l in lines.indices { for c in lines[l].checks.indices where lines[l].checks[c].outcome == .checking {
            lines[l].checks[c].outcome = .failed; lines[l].checks[c].error = "Stopped before the verdict."
        } }
        await audio?.stop()
        for ear in ears { await ear.finish() }
        live = [:]
        status = "Not listening"
    }

    func heard(_ speaker: Speaker, _ raw: String, final: Bool) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard final else { live[speaker] = text; return }
        print("\(speaker.rawValue): \(text)")
        live[speaker] = nil
        guard text.count > 1, listening else { return }
        let line = Line(speaker: speaker, text: text, at: Date())
        guard speaker == .me, !headphones else { add(line); return }
        // Speakers: wait for their copy of the same audio, then drop ours if it's an echo (lands within ~3s).
        let current = session
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard session == current else { return }
            let theirs = lines.filter { $0.speaker == .them && abs($0.at.timeIntervalSince(line.at)) < 3 }.map(\.text).joined(separator: " ")
            if !Self.isEcho(line.text, of: theirs) { add(line) }
        }
    }

    /// An echo repeats their words almost exactly. A reply that changes a number or adds a "not" is real speech.
    nonisolated static func isEcho(_ mine: String, of theirs: String) -> Bool {
        let a = FactCheck.normalize(mine).split(separator: " "), b = Set(FactCheck.normalize(theirs).split(separator: " "))
        guard !a.isEmpty, !b.isEmpty else { return false }
        let novel = a.filter { !b.contains($0) }
        if novel.contains(where: { $0.contains(where: \.isNumber) || ["not", "no", "never", "isn", "wasn", "didn", "doesn", "wrong", "actually"].contains(String($0)) }) { return false }
        return Double(a.count - novel.count) / Double(a.count) >= (a.count < 4 ? 1 : 0.8)
    }

    private func add(_ line: Line) {
        let context = lines.filter { $0.at <= line.at && $0.at >= sessionStart }.suffix(6).map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
        lines.insert(line, at: lines.firstIndex { $0.at > line.at } ?? lines.endIndex)
        guard OpenAI.key != nil, Parallel.key != nil else { return }
        guard pendingChecks.count < 10 else {
            status = "Listening · check queue full; latest line saved for review"
            return
        }
        pendingChecks.append(PendingCheck(line: line, context: context, session: session))
        pumpChecks()
    }

    /// Two sentences at a time bounds the two independent web searches each can start.
    private func pumpChecks() {
        guard listening, !busy else { return }
        while checkTasks.count < 2, !pendingChecks.isEmpty {
            let work = pendingChecks.removeFirst(), taskID = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                defer { checkTasks[taskID] = nil; pumpChecks() }
                let line = work.line, current = work.session
                guard session == current, !Task.isCancelled else { return }
                do {
                    let claims = try await FactCheck.claims(in: line.text, speaker: line.speaker, context: work.context)
                    guard session == current, !Task.isCancelled else { return }
                    for claim in claims where seen.insert(line.speaker.rawValue + FactCheck.normalize(claim)).inserted {
                        let check = Check(claim: claim)
                        if let l = lines.firstIndex(where: { $0.id == line.id }) { lines[l].checks.append(check) }
                        await judge(check, on: line, session: current)
                        guard session == current, !Task.isCancelled else { return }
                    }
                } catch {
                    if session == current, !Task.isCancelled {
                        status = error.localizedDescription
                        onSignal?(LiveSignal(speaker: line.speaker, phase: "Check unavailable", claim: line.text, outcome: .failed))
                    }
                }
            }
            checkTasks[taskID] = task
        }
    }

    private func judge(_ check: Check, on line: Line, session current: Int) async {
        let started = Date()
        update(line.id, check.id) { $0.startedAt = started; $0.phase = "Searching the web" }
        do {
            let (verdict, defense) = try await FactCheck.judge(check.claim, said: line.text) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.session == current else { return }
                    guard self.lines.first(where: { $0.id == line.id })?.checks.first(where: { $0.id == check.id })?.outcome == .checking else { return }
                    self.update(line.id, check.id) { $0.phase = progress.phase; $0.sourceCount = progress.sourceCount }
                    self.onSignal?(LiveSignal(speaker: line.speaker, phase: progress.phase, claim: check.claim, outcome: .checking, sourceCount: progress.sourceCount, latency: Date().timeIntervalSince(started)))
                }
            }
            guard session == current, !Task.isCancelled else { return }
            let outcome = FactCheck.outcome(verdict, defense)
            update(line.id, check.id) { $0.verdict = verdict; $0.defense = defense; $0.outcome = outcome; $0.phase = "Checked" }
            let sources = max(verdict.sourceCount ?? 0, lines.first(where: { $0.id == line.id })?.checks.first(where: { $0.id == check.id })?.sourceCount ?? 0)
            let strength: Double? = outcome == .bs ? min(verdict.confidence, defense?.confidence ?? 0) : outcome == .ok ? verdict.confidence : nil
            let detail = outcome == .overturned ? defense?.reason ?? "The evidence does not establish a contradiction." : verdict.correction
            onSignal?(LiveSignal(speaker: line.speaker, phase: "Checked", claim: check.claim, outcome: outcome, strength: strength, sourceCount: sources, latency: Date().timeIntervalSince(started), detail: detail, sourceURL: outcome == .overturned ? defense?.source : verdict.source))
            if outcome == .bs, let done = lines.first(where: { $0.id == line.id })?.checks.first(where: { $0.id == check.id }) {
                score[line.speaker, default: 0] += 1
                onBS?(line.speaker, done, false)
            }
        } catch {
            guard session == current, !Task.isCancelled else { return }
            update(line.id, check.id) { $0.outcome = .failed; $0.error = error.localizedDescription }
            seen.remove(line.speaker.rawValue + FactCheck.normalize(check.claim))   // let a repeat retry it
            onSignal?(LiveSignal(speaker: line.speaker, phase: "Check unavailable", claim: check.claim, outcome: .failed, latency: Date().timeIntervalSince(started)))
        }
    }

    private func update(_ lineID: Line.ID, _ checkID: Check.ID, _ change: (inout Check) -> Void) {
        guard let l = lines.firstIndex(where: { $0.id == lineID }),
              let c = lines[l].checks.firstIndex(where: { $0.id == checkID }) else { return }
        change(&lines[l].checks[c])
    }

    /// Rehearsal without a call or an API key.
    func fakeBS(_ speaker: Speaker) {
        var check = Check(claim: speaker == .them ? "The Great Wall of China is visible from the Moon." : "Goldfish have a three-second memory.")
        check.outcome = .bs
        check.verdict = Verdict(verdict: "false", confidence: 0.95, correction: speaker == .them ? "It isn't visible to the naked eye even from low orbit." : "Goldfish remember things for months.", source: "https://en.wikipedia.org/wiki/List_of_common_misconceptions")
        check.defense = Defense(defensible: false, confidence: 0.9, reason: "No credible source supports it.", source: nil)
        var line = Line(speaker: speaker, text: check.claim, at: Date())
        line.checks = [check]
        lines.append(line)
        score[speaker, default: 0] += 1
        onSignal?(LiveSignal(speaker: speaker, phase: "Demo signal", claim: check.claim, outcome: .bs, strength: 0.9, sourceCount: 1, latency: nil, detail: check.verdict?.correction))
        onBS?(speaker, check, true)
    }
}
