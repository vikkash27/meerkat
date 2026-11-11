import AppKit
import SwiftUI

// MARK: - Meerkat

enum Mood { case idle, thinking, watching, done, error
    var color: Color { switch self { case .idle: .gray; case .thinking: .purple; case .watching: .cyan; case .done: .green; case .error: .red } }
}

/// One meerkat head on an 18×18 grid (y up). `template` draws a flat white glyph with cut-out
/// face, like a menu-bar icon; otherwise it's the coloured character.
func drawMeerkat(_ ctx: GraphicsContext, scale s: CGFloat, template: Bool, look: CGFloat = 0, blink: Bool = false) {
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x * s, y: (18 - y - h) * s, width: w * s, height: h * s)) }
    var c = ctx
    let fur = template ? Color.black : Color(red: 0.87, green: 0.70, blue: 0.48)
    let dark = template ? Color.black : Color(red: 0.30, green: 0.20, blue: 0.13)
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (18 - y) * s) }
    // Teardrop head: wide brow tapering to a pointed snout (the round head read as a monkey).
    var head = Path()
    head.move(to: p(9, 15.6))
    head.addCurve(to: p(13.6, 10.6), control1: p(12.2, 15.6), control2: p(13.6, 13.6))
    head.addCurve(to: p(9, 1.2), control1: p(13.6, 6.8), control2: p(10.6, 2.2))
    head.addCurve(to: p(4.4, 10.6), control1: p(7.4, 2.2), control2: p(4.4, 6.8))
    head.addCurve(to: p(9, 15.6), control1: p(4.4, 13.6), control2: p(5.8, 15.6))
    // small ears set low on the sides
    c.fill(r(2.9, 10.0, 2.6, 2.6).union(r(12.5, 10.0, 2.6, 2.6)), with: .color(template ? fur : dark.opacity(0.8)))
    c.fill(head, with: .color(fur))
    if !template { c.fill(r(6.6, 1.8, 4.8, 7.0), with: .color(Color(red: 0.97, green: 0.88, blue: 0.74))) }  // pale muzzle
    // dark eye masks + nose tip: cut out for the glyph, dark brown for the character
    if template { c.blendMode = .clear }
    c.fill(r(5.4, 8.4, 3.2, 3.8).union(r(9.4, 8.4, 3.2, 3.8)), with: .color(dark))
    c.fill(r(8.0, 1.2, 2.0, 1.6), with: .color(dark))
    c.blendMode = .normal
    // eyes (sparkles inside the masks)
    let eye = template ? Color.black : Color.white
    let h: CGFloat = blink ? 0.4 : 1.6
    c.fill(r(6.4 + look, 9.9, 1.2, h).union(r(10.4 + look, 9.9, 1.2, h)), with: .color(eye))
}

struct MeerkatFace: View {
    var mood: Mood
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { t in
            let s = t.date.timeIntervalSinceReferenceDate
            let look = mood == .watching || mood == .thinking ? sin(s * 2) * 0.5 : 0
            let blink = s.truncatingRemainder(dividingBy: 4) > 3.85
            let breathe = 1 + sin(s * 2.4) * 0.02
            // Sentry pose: body, tail, hanging paws, feet on the window edge, then the head on top.
            Canvas { ctx, _ in
                let fur = Color(red: 0.87, green: 0.70, blue: 0.48), dark = Color(red: 0.62, green: 0.45, blue: 0.28)
                var tail = Path(); tail.move(to: CGPoint(x: 32, y: 50)); tail.addQuadCurve(to: CGPoint(x: 43, y: 63), control: CGPoint(x: 44, y: 50))
                ctx.stroke(tail, with: .color(dark), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: 12, y: 28, width: 22, height: 34)), with: .color(fur))
                ctx.fill(Path(ellipseIn: CGRect(x: 16, y: 35, width: 14, height: 25)), with: .color(Color(red: 0.97, green: 0.88, blue: 0.74)))
                ctx.fill(Path(ellipseIn: CGRect(x: 15, y: 37, width: 6, height: 12)).union(Path(ellipseIn: CGRect(x: 25, y: 37, width: 6, height: 12))), with: .color(dark))
                ctx.fill(Path(ellipseIn: CGRect(x: 12, y: 59, width: 9, height: 5)).union(Path(ellipseIn: CGRect(x: 25, y: 59, width: 9, height: 5))), with: .color(dark))
                var head = ctx; head.translateBy(x: 4, y: 0)
                drawMeerkat(head, scale: 2.1, template: false, look: look, blink: blink)
            }
            .frame(width: 46, height: 64)
            .scaleEffect(x: 1 / breathe, y: breathe, anchor: .bottom)
            .overlay(alignment: .topTrailing) {  // status light
                Circle().fill(mood.color).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .opacity(mood == .thinking ? 0.4 + 0.6 * abs(sin(s * 6)) : 1)
                    .offset(x: -6, y: 4)
            }
        }
        .frame(width: 46, height: 64)
    }
}

@MainActor
func menuBarMeerkat() -> NSImage {
    let image = ImageRenderer(content: Canvas { ctx, _ in drawMeerkat(ctx, scale: 1, template: true) }.frame(width: 18, height: 18))
    image.scale = 2
    let ns = image.nsImage ?? NSImage()
    ns.isTemplate = true
    return ns
}

// MARK: - One agent bound to one window

@MainActor
final class Agent: ObservableObject, Identifiable {
    let id = UUID()
    @Published var target: Target
    @Published var mood: Mood = .idle
    @Published var status = ""
    @Published var instruction = ""
    @Published var plan: Plan?
    @Published var expanded = true
    var loop: Task<Void, Never>?
    init(target: Target) { self.target = target }

    // ponytail: fixed 4s poll with 2 consecutive hits at p ≥ 0.8. Add backoff or change detection if cost matters.
    static let interval: Duration = .seconds(4), threshold = 0.8

    func start() {
        loop?.cancel()
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        mood = .thinking; status = "Thinking…"; expanded = true
        loop = Task {
            do {
                let plan = try await OpenAI.plan(text, window: target.label)
                self.plan = plan
                if plan.condition.isEmpty { try await fire(plan); return }
                mood = .watching; status = plan.summary; expanded = false
                var hits = 0
                while !Task.isCancelled {
                    let jpeg = try await target.snapshot()
                    let p = try await OpenAI.probability(plan.condition, window: target.label, jpeg: jpeg)
                    hits = p >= Self.threshold ? hits + 1 : 0
                    status = "\(plan.summary) · \(Int(p * 100))%"
                    if hits >= 2 {
                        try await fire(plan)
                        guard plan.repeat else { return }
                        // Wait for the condition to clear before it can fire again.
                        while !Task.isCancelled, try await OpenAI.probability(plan.condition, window: target.label, jpeg: target.snapshot()) >= 0.5 {
                            try await Task.sleep(for: Self.interval)
                        }
                        hits = 0; mood = .watching
                    }
                    try await Task.sleep(for: Self.interval)
                }
            } catch is CancellationError {
            } catch {
                mood = .error; status = error.localizedDescription; expanded = true
            }
        }
    }

    private func fire(_ plan: Plan) async throws {
        try await Hands.perform(plan, on: target)
        NSSound(named: "Glass")?.play()
        mood = .done; expanded = true
        status = plan.action == .notify ? plan.value : "Done: \(plan.action == .keys ? "pressed \(plan.value)" : "typed text")"
    }

    func stop() { loop?.cancel(); loop = nil }
}

struct AgentView: View {
    @ObservedObject var agent: Agent
    var remove: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if agent.expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if agent.plan == nil && agent.mood != .thinking {
                        Text("What should I do in \(agent.target.app)?").font(.caption).foregroundStyle(.secondary)
                        TextField("e.g. when the download finishes, press cmd+q", text: $agent.instruction, axis: .vertical)
                            .textFieldStyle(.plain).focused($focused).lineLimit(1...3)
                            .onSubmit { agent.start() }
                            .onAppear { focused = true }
                    } else {
                        Text(agent.status).font(.callout).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Edit") { agent.stop(); agent.plan = nil; agent.mood = .idle }
                            if agent.mood == .done || agent.mood == .error { Button("Retry") { agent.start() } }
                            Spacer()
                            Button("Remove", role: .destructive, action: remove)
                        }.buttonStyle(.borderless).font(.caption)
                    }
                }
                .padding(10).frame(width: 260, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            MeerkatFace(mood: agent.mood)
                .onTapGesture { agent.expanded.toggle() }
                .contextMenu { Button("Remove", action: remove) }
                .help(agent.status)
        }
        .padding(4)
        .fixedSize()
    }
}

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; hidesOnDeactivate = false
    }
}

// MARK: - Menu bar + drag source

/// Sits on top of the menu-bar button: press and drag the icon to carry a meerkat onto a window; a plain click opens the menu.
final class DragMeerkat: NSView {
    var onDrop: ((NSPoint) -> Void)?
    var onClick: (() -> Void)?
    private var down = NSPoint.zero, dragging = false
    private lazy var ghost: KeyPanel = {
        let p = KeyPanel(); p.level = .statusBar; p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView: MeerkatFace(mood: .watching))
        p.setContentSize(NSSize(width: 46, height: 64)); return p
    }()
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with e: NSEvent) { onClick?() }
    override func mouseDown(with e: NSEvent) { down = NSEvent.mouseLocation; dragging = false }
    override func mouseDragged(with e: NSEvent) {
        let p = NSEvent.mouseLocation
        guard dragging || hypot(p.x - down.x, p.y - down.y) > 4 else { return }
        if !dragging { dragging = true; NSCursor.closedHand.push() }
        ghost.setFrameOrigin(NSPoint(x: p.x - 23, y: p.y - 32))  // feet just under the cursor
        ghost.orderFrontRegardless()
    }
    override func mouseUp(with e: NSEvent) {
        guard dragging else { onClick?(); return }
        dragging = false; NSCursor.pop(); ghost.orderOut(nil)
        let p = NSEvent.mouseLocation
        DispatchQueue.main.async { self.onDrop?(p) }
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var agents: [UUID: (Agent, KeyPanel)] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let button = item.button else { return }
        button.image = menuBarMeerkat()
        button.toolTip = "Drag me onto a window"
        let drag = DragMeerkat(frame: button.bounds)
        drag.autoresizingMask = [.width, .height]
        drag.onDrop = { [weak self] in self?.dropped(at: $0) }
        drag.onClick = { [weak self] in self?.showMenu() }
        button.addSubview(drag)

        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        if !Hands.trusted { Hands.askForAccess() }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { self.follow() } }
    }

    func showMenu() {
        let m = NSMenu()
        m.addItem(withTitle: OpenAI.key == nil ? "Set OpenAI Key…" : "Change OpenAI Key…", action: #selector(setKey), keyEquivalent: "").target = self
        if !Hands.trusted { m.addItem(withTitle: "Allow Accessibility (for keystrokes)…", action: #selector(askAX), keyEquivalent: "").target = self }
        if !agents.isEmpty { m.addItem(withTitle: "Remove All Agents", action: #selector(removeAll), keyEquivalent: "").target = self }
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Meercat", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: (item.button?.bounds.height ?? 0) + 4), in: item.button)
    }

    @objc func askAX() { Hands.askForAccess() }
    @objc func removeAll() { agents.keys.forEach(remove) }
    @objc func setKey() {
        let a = NSAlert(); a.messageText = "OpenAI API key"; a.informativeText = "Stored in your Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); a.accessoryView = field
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty { Keychain.save(field.stringValue.trimmingCharacters(in: .whitespaces)) }
    }

    func dropped(at p: NSPoint) {
        guard let target = Target.at(p) else { NSSound.beep(); return }
        // One agent per window: dropping again replaces it.
        agents.filter { $0.value.0.target.id == target.id }.keys.forEach(remove)
        let agent = Agent(target: target), panel = KeyPanel()
        let id = agent.id
        panel.contentView = NSHostingView(rootView: AgentView(agent: agent, remove: { [weak self] in self?.remove(id) }))
        agents[id] = (agent, panel)
        if OpenAI.key == nil { agent.mood = .error; agent.status = "Set your OpenAI key: right-click the menu bar icon." }
        follow()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func remove(_ id: UUID) {
        guard let (agent, panel) = agents.removeValue(forKey: id) else { return }
        agent.stop(); panel.close()
    }

    /// Keep each meerkat perched on the top-right of its window, hidden when the window is.
    func follow() {
        guard !agents.isEmpty else { return }
        let windows = Dictionary(Target.all().map { ($0.id, $0) }) { a, _ in a }
        for (agent, panel) in agents.values {
            guard let w = windows[agent.target.id] else { if panel.isVisible { panel.orderOut(nil) }; continue }
            if agent.target != w { agent.target = w }
            let size = panel.contentView?.fittingSize ?? .zero
            let f = w.frame
            // Feet on the top edge (padding is 4pt); if the window touches the top of the screen, sit just inside it.
            let top = (NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main)?.visibleFrame.maxY ?? f.maxY
            let origin = NSPoint(x: f.maxX - size.width - 12, y: min(f.maxY - 6, top - size.height))
            if panel.frame.size != size || panel.frame.origin != origin { panel.setFrame(NSRect(origin: origin, size: size), display: true) }
            if !panel.isVisible || !panel.isKeyWindow { panel.order(.above, relativeTo: Int(w.id)) }
        }
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") {
    assert(Hands.parse("cmd+s")! == (1, .maskCommand))
    assert(Hands.parse("cmd+shift+t")! == (17, [.maskCommand, .maskShift]))
    assert(Hands.parse("return")! == (36, []))
    assert(Hands.parse("q")!.0 == 12 && Hands.parse("m")!.0 == 46 && Hands.parse("`")!.0 == 50)
    assert(Hands.parse("hyper+x") == nil && Hands.parse("cmd+F13") == nil)
    print("selftest ok"); exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
