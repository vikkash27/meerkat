import AppKit
import SwiftUI

/// Optional context for resolving company references during a call.
@available(macOS 26.0, *)
struct SpeakerContextView: View {
    @ObservedObject var call: Call
    let onDone: () -> Void

    init(call: Call, onDone: @escaping () -> Void) {
        self.call = call
        self.onDone = onDone
    }

    private var isEmpty: Bool {
        call.speakerName.isEmpty && call.companyName.isEmpty &&
        call.companyWebsite.isEmpty && call.speakerNotes.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speaker context")
                .font(.system(size: 21, weight: .semibold))

            Text("Add the speaker and startup so “we” and “our company” resolve correctly. Company claims are checked on the web.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                field("Name", text: $call.speakerName, prompt: "Speaker’s name")
                field("Startup", text: $call.companyName, prompt: "Company name")
                field("Website", text: $call.companyWebsite, prompt: "https://example.com")
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Notes").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("Optional").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)

                TextEditor(text: $call.speakerNotes)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 70)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                    .accessibilityLabel("Notes")
            }

            HStack(spacing: 10) {
                Text("Kept in this session")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") {
                    call.speakerName = ""
                    call.companyName = ""
                    call.companyWebsite = ""
                    call.speakerNotes = ""
                }
                .buttonStyle(.borderless)
                .disabled(isEmpty)

                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 390, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            TextField(label, text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .accessibilityLabel(label)
        }
    }
}
