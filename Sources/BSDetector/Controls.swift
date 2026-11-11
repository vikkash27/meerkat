import AppKit
import CoreGraphics
import SwiftUI

/// Visible controls for the companion. Opening this view never starts capture.
@available(macOS 26.0, *)
struct ControlsView: View {
    @ObservedObject var call: Call
    @ObservedObject var overlay: Overlay
    let onToggle: () -> Void
    let onTest: () -> Void
    let onTranscript: () -> Void
    let onQuit: () -> Void
    let onRefresh: () -> Void
    let onSelect: (CGWindowID) -> Void
    let onSwap: () -> Void
    let onHeadphones: () -> Void
    let onOpenAIKey: () -> Void
    let onParallelKey: () -> Void

    @State private var available: [CallWindow] = []
    @State private var openAIReady = OpenAI.key != nil
    @State private var parallelReady = Parallel.key != nil

    init(call: Call, overlay: Overlay,
         onToggle: @escaping () -> Void, onTest: @escaping () -> Void,
         onTranscript: @escaping () -> Void, onQuit: @escaping () -> Void,
         onRefresh: @escaping () -> Void, onSelect: @escaping (CGWindowID) -> Void,
         onSwap: @escaping () -> Void, onHeadphones: @escaping () -> Void,
         onOpenAIKey: @escaping () -> Void, onParallelKey: @escaping () -> Void) {
        self.call = call; self.overlay = overlay
        self.onToggle = onToggle; self.onTest = onTest; self.onTranscript = onTranscript
        self.onQuit = onQuit; self.onRefresh = onRefresh; self.onSelect = onSelect
        self.onSwap = onSwap; self.onHeadphones = onHeadphones
        self.onOpenAIKey = onOpenAIKey; self.onParallelKey = onParallelKey
    }

    private var selection: Binding<CGWindowID?> {
        Binding(get: { available.contains(where: { $0.id == overlay.target?.id }) ? overlay.target?.id : nil },
                set: { if let id = $0 { onSelect(id) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                HUDMeerkatIcon().frame(width: 31, height: 31)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meerkat").font(.system(size: 21, weight: .semibold))
                    Text("Your call companion").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(call.listening ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(call.listening ? "Listening" : "Ready").font(.system(size: 11, weight: .medium))
                }
            }

            Text(call.status).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)

            Button(action: onToggle) {
                Label(call.busy ? "Please wait…" : call.listening ? "Stop listening" : "Start listening",
                      systemImage: call.listening ? "stop.fill" : "waveform")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 25)
            }
            .buttonStyle(.borderedProminent).tint(call.listening ? .orange : .accentColor)
            .disabled(call.busy)

            HStack(spacing: 8) {
                Button(action: onTest) {
                    HStack(spacing: 6) {
                        Text("Test overlay")
                        Text("DEMO").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
                Button("Show transcript", systemImage: "text.alignleft", action: onTranscript)
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.regular)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Call window").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        available = CallWindow.all(); onRefresh()
                    }.buttonStyle(.borderless).font(.system(size: 10))
                }
                Picker("Call window", selection: selection) {
                    Text(available.isEmpty ? "No Meet window found" : "Choose a call window").tag(nil as CGWindowID?)
                    ForEach(available, id: \.id) { window in
                        Text(window.label).tag(Optional(window.id))
                    }
                }.labelsHidden().frame(maxWidth: .infinity)
                HStack {
                    Toggle("Using headphones", isOn: Binding(get: { call.headphones }, set: { _ in onHeadphones() }))
                        .toggleStyle(.checkbox).font(.system(size: 11))
                    Spacer()
                    Button("Swap faces", systemImage: "arrow.left.arrow.right", action: onSwap)
                        .buttonStyle(.borderless).font(.system(size: 10))
                }
            }

            Toggle("Also check me (solo test)", isOn: $call.checkMe)
                .toggleStyle(.checkbox).font(.system(size: 11))

            HStack(spacing: 8) {
                connection("OpenAI", ready: openAIReady) { onOpenAIKey(); openAIReady = OpenAI.key != nil }
                connection("Parallel", ready: parallelReady) { onParallelKey(); parallelReady = Parallel.key != nil }
            }

            HStack {
                Text("Checks claims, not people.").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Meerkat", systemImage: "power", action: onQuit)
                    .buttonStyle(.bordered).font(.system(size: 11, weight: .medium))
            }
        }
        .padding(20)
        .frame(width: 390, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { available = CallWindow.all(); openAIReady = OpenAI.key != nil; parallelReady = Parallel.key != nil }
    }

    private func connection(_ name: String, ready: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: ready ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(ready ? Color.green : Color.secondary)
                Text(name).fontWeight(.medium)
                Spacer(minLength: 2)
                Text(ready ? "Ready" : "Add key").foregroundStyle(.secondary)
            }.font(.system(size: 10)).frame(maxWidth: .infinity)
        }.buttonStyle(.bordered)
    }
}
