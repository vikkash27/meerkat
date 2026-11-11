import AppKit
import AVFoundation
import Combine
import SwiftUI

@available(macOS 26.0, *)
@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let call = Call()
    let overlay = Overlay()
    var panel: NSPanel!
    var controls: NSWindow!
    var contextPanel: NSPanel?
    var watch: AnyCancellable?
    var listeningWatch: AnyCancellable?
    var userStopped = false

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.title = "💩"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 600), styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "BS Detector"; panel.isFloatingPanel = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: TranscriptView(call: call, toggle: { [weak self] in self?.toggle() }))
        if let screen = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: screen.maxX - 400, y: screen.maxY - 620)) }
        // The live HUD carries in-call signals; the transcript opens on demand for review.
        controls = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 490), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        controls.title = "Meerkat — Call Controls"
        controls.isReleasedWhenClosed = false
        controls.contentView = NSHostingView(rootView: ControlsView(
            call: call, overlay: overlay,
            onToggle: { [weak self] in self?.toggle() },
            onTest: { [weak self] in self?.test() },
            onTranscript: { [weak self] in self?.show() },
            onQuit: { NSApp.terminate(nil) },
            onRefresh: { [weak self] in
                guard let self else { return }
                if self.overlay.target == nil { self.overlay.attach(CallWindow.findCall()) }
            },
            onSelect: { [weak self] id in self?.overlay.attach(CallWindow.all().first { $0.id == id }) },
            onSwap: { [weak self] in self?.swap() },
            onHeadphones: { [weak self] in self?.headphones() },
            onOpenAIKey: { [weak self] in self?.setKey() },
            onParallelKey: { [weak self] in self?.setParallelKey() },
            onContext: { [weak self] in self?.showContext() },
            onResetOverlay: { [weak self] in self?.overlay.clearPresentation() }
        ))
        controls.center()

        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Meerkat")
        let showControlsItem = applicationMenu.addItem(withTitle: "Show Controls", action: #selector(showControls), keyEquivalent: "0")
        showControlsItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Meerkat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenControls(_:)), name: Notification.Name("dev.meercat.bsdetector.showControls"), object: nil)

        call.onBS = { [weak self] speaker, check, rehearsal in
            guard let self else { return }
            self.overlay.recordFlaggedClaim(FlaggedClaim(id: check.id, speaker: speaker, claim: check.claim,
                                                        correction: check.verdict?.correction ?? "",
                                                        sourceURL: rehearsal ? nil : check.verdict?.source, isDemo: rehearsal))
            self.overlay.burst(speaker, text: check.verdict?.correction ?? "", rehearsal: rehearsal)
        }
        call.onSignal = { [weak self] signal in self?.overlay.updateSignal(signal) }
        watch = call.$score.combineLatest(call.$listening).sink { [weak self] score, listening in
            let total = score.values.reduce(0, +)
            self?.item.button?.title = (listening ? "🔴 " : "") + "💩" + (total > 0 ? " \(total)" : "")
        }
        listeningWatch = call.$listening.removeDuplicates().sink { [weak self] listening in
            self?.overlay.setListening(listening)
            if !listening { self?.overlay.resetFlaggedClaims() }
        }
        overlay.attach(CallWindow.findCall())
        showControls()
        if ProcessInfo.processInfo.environment["BS_AUTO_START"] == "1" {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { self.autoStart() } }
            autoStart()
        }
    }

    func autoStart() {
        guard !call.listening, !call.busy else { return }
        guard let meet = CallWindow.findCall() else {
            if !userStopped { call.status = CGPreflightScreenCaptureAccess() ? "Waiting for a visible Meet window" : "Screen Recording permission needs an app restart or a fresh grant" }
            return
        }
        if userStopped { if meet.id == overlay.target?.id { return }; userStopped = false }
        overlay.attach(meet)
        overlay.resetFlaggedClaims()
        Task { await call.start(); print("status: \(call.status)") }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showControls(); return true }
    @objc func showControls() { controls.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func reopenControls(_ notification: Notification) { showControls() }
    @objc func showContext() {
        if contextPanel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 390), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Speaker context"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SpeakerContextView(call: call, onDone: { [weak self] in self?.contextPanel?.orderOut(nil) }))
            window.center()
            contextPanel = window
        }
        contextPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, on: Bool = false) -> NSMenuItem {
            let i = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); i.target = self; i.state = on ? .on : .off; return i
        }
        _ = add(call.busy ? "Starting…" : call.listening ? "Stop Listening" : "Start Listening", #selector(toggle)).isEnabled = !call.busy
        _ = add("Wearing Headphones", #selector(headphones), on: call.headphones)
        _ = add("Also Fact-check Me (rehearsal)", #selector(checkMe), on: call.checkMe)
        let windows = NSMenu()
        for w in CallWindow.all() {
            let i = windows.addItem(withTitle: String(w.label.prefix(60)), action: #selector(pick(_:)), keyEquivalent: "")
            i.target = self; i.tag = Int(w.id); i.state = w.id == overlay.target?.id ? .on : .off
        }
        menu.addItem(withTitle: "Call Window: \(overlay.target.map { String($0.label.prefix(30)) } ?? "none")", action: nil, keyEquivalent: "").submenu = windows
        _ = add("Swap Me / Them Faces", #selector(swap), on: overlay.swap)
        _ = add("Show Controls", #selector(showControls))
        _ = add("Speaker Context…", #selector(showContext))
        _ = add("Show Transcript", #selector(show))
        _ = add("Test BS Burst", #selector(test))
        menu.addItem(.separator())
        _ = add(OpenAI.key == nil ? "Set OpenAI Key…" : "Change OpenAI Key…", #selector(setKey))
        _ = add(Parallel.key == nil ? "Set Parallel Key…" : "Change Parallel Key…", #selector(setParallelKey))
        menu.addItem(withTitle: "Quit", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
    }

    @objc func headphones() { call.headphones.toggle() }
    @objc func checkMe() { call.checkMe.toggle() }
    @objc func toggle() {
        Task {
            if call.listening { userStopped = true; await call.stop(); return }
            userStopped = false
            overlay.resetFlaggedClaims()
            if overlay.target.map({ t in CallWindow.all().contains { $0.id == t.id } }) != true { overlay.attach(CallWindow.findCall()) }
            await call.start()
        }
    }
    @objc func pick(_ sender: NSMenuItem) { overlay.attach(CallWindow.all().first { $0.id == CGWindowID(sender.tag) }) }
    @objc func swap() { overlay.swap.toggle() }
    @objc func show() { panel.orderFrontRegardless() }
    @objc func test() { call.fakeBS(.them) }
    @objc func setKey() { askKey("OpenAI API key", "openai") }
    @objc func setParallelKey() { askKey("Parallel API key", "parallel") }
    func askKey(_ title: String, _ account: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = "Stored in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); a.accessoryView = field
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { Keychain.save(field.stringValue.trimmingCharacters(in: .whitespaces), account) }
    }
}

// MARK: - CLI: self-test, transcribe a file, fact-check a sentence

func selftest() {
    func check(_ ok: Bool, _ name: String) { print(ok ? "ok   \(name)" : "FAIL \(name)"); if !ok { exit(1) } }
    check(FactCheck.parse("```json\n{\"verdict\":\"false\",\"confidence\":0.9,\"correction\":\"x\"}\n```", as: Verdict.self)?.flagged == true, "parse fenced verdict")
    check(FactCheck.parse("no json here", as: Verdict.self) == nil, "reject non-json")
    let v = Verdict(verdict: "False", confidence: 0.9, correction: "", source: nil)
    check(FactCheck.outcome(v, Defense(defensible: false, confidence: 0.8, reason: "", source: nil)) == .bs, "bs needs prosecutor + failed defense")
    check(FactCheck.outcome(v, Defense(defensible: true, confidence: 0.8, reason: "", source: nil)) == .overturned, "defense can overturn")
    check(FactCheck.outcome(v, nil) == .overturned, "no defense, no flag")
    check(FactCheck.outcome(v, Defense(defensible: false, confidence: 0.2, reason: "", source: nil)) == .overturned, "unsure defense doesn't convict")
    check(FactCheck.outcome(Verdict(verdict: "false", confidence: 0.5, correction: "", source: nil), nil) == .unsure, "low confidence is not bs")
    check(FactCheck.outcome(Verdict(verdict: "true", confidence: 0.9, correction: "", source: nil), nil) == .ok, "true checks out")
    let reply = #"{"output":[{"type":"reasoning","id":"r1"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"verdict\":\"true\",\"confidence\":0.8,\"correction\":\"ok\"}","annotations":[]}]}]}"#
    let r = try? JSONDecoder().decode(OpenAI.Reply.self, from: Data(reply.utf8))
    check(FactCheck.parse(r?.text ?? "", as: Verdict.self)?.verdict == "true", "decode responses reply")
    let search = #"{"search_id":"s1","session_id":"x","results":[{"url":"https://a.com","title":"A","publish_date":null,"excerpts":["one","two"]}],"warnings":null}"#
    struct SR: Decodable { var results: [Parallel.Result] }
    let found = (try? JSONDecoder().decode(SR.self, from: Data(search.utf8)))?.results ?? []
    check(found.first?.url == "https://a.com" && Parallel.format(found).contains("one\ntwo"), "decode + format parallel results")
    let sourced = Verdict(verdict: "false", confidence: 0.9, correction: "Correction", source: "https://a.com")
    check(FactCheck.validatedVerdict(sourced, evidence: found).flagged, "fetched citation permits a verdict")
    let invalid = FactCheck.validatedVerdict(Verdict(verdict: "false", confidence: 0.9, correction: "Correction", source: "https://invented.example"), evidence: found)
    check(invalid.verdict == "unverifiable" && invalid.source == nil && !invalid.flagged, "invented citation cannot be replaced or flag a claim")
    check(FactCheck.validatedVerdict(sourced, evidence: []).verdict == "unverifiable", "no fetched evidence means unknown")
    let noDefense = FactCheck.validatedDefense(Defense(defensible: false, confidence: 0.9, reason: "", source: "https://invented.example"), evidence: found)
    check(noDefense.defensible && noDefense.confidence == 0 && FactCheck.outcome(sourced, noDefense) == .overturned, "unsourced defense cannot concede")
    for confidence in [Double.nan, Double.infinity, -0.1, 1.1] {
        let value = Verdict(verdict: "true", confidence: confidence, correction: "", source: "https://a.com")
        check(FactCheck.outcome(FactCheck.validatedVerdict(value, evidence: found), nil) == .unsure, "invalid confidence remains unknown: \(confidence)")
    }
    check(FactCheck.outcome(Verdict(verdict: "true", confidence: 0.4, correction: "", source: "https://a.com"), nil) == .unsure, "low-confidence support remains unknown")
    check(FactCheck.usableEvidence([Parallel.Result(url: "https://a.com", excerpts: [" \n "])]).isEmpty, "blank excerpts do not count as evidence")
    if #available(macOS 26.0, *) {
        check(Call.isEcho("the eiffel tower was built in 1999", of: "So the Eiffel Tower was built in 1999, right?"), "echo of them is dropped")
        check(!Call.isEcho("no way, that's completely wrong", of: "So the Eiffel Tower was built in 1999, right?"), "real reply is kept")
        check(Call.isEcho("Yeah.", of: "yeah totally") && !Call.isEcho("Yeah.", of: "no"), "short echoes")
        check(!Call.isEcho("The Eiffel Tower was built in 1889.", of: "The Eiffel Tower was built in 1999."), "correction with a new number is kept")
        check(!Call.isEcho("The Eiffel Tower was not built in 1999", of: "The Eiffel Tower was built in 1999."), "negation is kept")
    }
    let big = CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.4), small = CGRect(x: 0.8, y: 0.7, width: 0.08, height: 0.1)
    check(Faces.assign([small, big], swap: false) == [.them: big, .me: small], "big face is them")
    check(Faces.assign([small, big], swap: true) == [.me: big, .them: small], "swap")
    check(Faces.assign([], swap: false).isEmpty, "no faces")
    check(Faces.assign([small], swap: false) == [.me: small], "lone self-view is me")
    check(Faces.assign([big], swap: false) == [.them: big], "lone big face is them")
    var ledger = FlaggedClaimLedger()
    let receipt = FlaggedClaim(id: UUID(), speaker: .them, claim: "Claim", correction: "Correction", sourceURL: "https://example.com/evidence")
    ledger.add(receipt); ledger.add(receipt)
    check(ledger.count(for: .them) == 1, "duplicate flag callbacks count once")
    ledger.add(FlaggedClaim(id: UUID(), speaker: .them, claim: "Unsourced", correction: "", sourceURL: "file:///tmp/example"))
    check(ledger.count(for: .them) == 1, "unsourced flags never inflate the meter")
    for _ in 0..<13 { ledger.add(FlaggedClaim(id: UUID(), speaker: .them, claim: "Demo", correction: "Demo correction", sourceURL: "https://example.com", isDemo: true)) }
    check(ledger.count(for: .them) == 1 && ledger.count(for: .them, isDemo: true) == 13, "demo and live histories stay separate")
    check(ledger.crownCount(for: .them, isDemo: true) == 10 && ledger.last4(for: .them, isDemo: true).count == 4, "crown and rap sheet stay bounded")
    check(ledger.last4(for: .them, isDemo: true).allSatisfy { $0.sourceURL == nil }, "demo receipts have no fabricated source links")
    ledger.reset()
    check(ledger.records.isEmpty, "reset clears the overlay history")
    if #available(macOS 26.0, *) {
        check(Call.makeSpeakerContext(speakerName: " ", companyName: "", companyWebsite: "", speakerNotes: "").isEmpty, "empty profile adds no context")
        let background = Call.makeSpeakerContext(speakerName: " Founder ", companyName: " Neon ", companyWebsite: "https://neon.com", speakerNotes: String(repeating: "x", count: 8000))
        check(background.contains("Company: Neon") && background.count < 2300, "speaker context is trimmed and bounded")
        check(FactCheck.backgroundBlock(background).contains("never evidence"), "profile is labelled as unverified context")
    }
    print("selftest ok")
}

@available(macOS 26.0, *)
func transcribe(_ path: String) async throws {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let ear = try await Transcriber(.them, locale: try await Transcriber.locale()) { text, final in if final { print("final: \(text)") } }
    while file.framePosition < file.length, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) {
        try file.read(into: buf)
        ear.feed(buf)
    }
    await ear.finish()
}

func factCheck(_ sentence: String, background: String = "") async throws {
    let claims = try await FactCheck.claims(in: sentence, speaker: .them, context: background)
    print("claims: \(claims)")
    for claim in claims {
        let started = Date()
        let (v, d) = try await FactCheck.judge(claim, said: sentence, background: background)
        print("\nclaim:      \(claim)\nprosecutor: \(v)\ndefense:    \(d.map { "\($0)" } ?? "(cancelled)")\noutcome:    \(FactCheck.outcome(v, d))  [\(String(format: "%.1f", Date().timeIntervalSince(started)))s]")
    }
}

let args = CommandLine.arguments
setvbuf(stdout, nil, _IOLBF, 0)
func run(_ work: @escaping () async throws -> Void) -> Never {
    Task { do { try await work(); exit(0) } catch { print("error: \(error.localizedDescription)"); exit(1) } }
    dispatchMain()
}

if args.contains("--selftest") { selftest(); exit(0) }
if let i = args.firstIndex(of: "--check"), i + 1 < args.count {
    let context = args.firstIndex(of: "--context").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? ""
    run { try await factCheck(args[i + 1], background: context) }
}
if #available(macOS 26.0, *) {
    if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count { run { try await transcribe(args[i + 1]) } }
    let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
    try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    freopen(logDirectory.appendingPathComponent("BSDetector.log").path, "a", stdout)
    setvbuf(stdout, nil, _IOLBF, 0)
    print("Launch \(Date())")
    let app = NSApplication.shared
    let bundleID = Bundle.main.bundleIdentifier ?? "dev.meercat.bsdetector"
    if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.processIdentifier != getpid() }) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.meercat.bsdetector.showControls"), object: nil, userInfo: nil, deliverImmediately: true)
        existing.activate(options: [.activateAllWindows])
        print("Meerkat is already running; showing its controls.")
        exit(0)
    }
    let delegate = MainActor.assumeIsolated { App() }
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
} else {
    print("BS Detector needs macOS 26."); exit(1)
}
