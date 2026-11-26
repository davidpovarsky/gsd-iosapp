import SwiftUI
import GSDModel
import GSDSnapshot

/// Capture in two steps (spec 4.3): a text field (dictation, Scribble, or keyboard), then four
/// labeled quadrant buttons preselected by `CaptureParser.parse`. Add queues a `capture` command.
struct CaptureView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var chosen: Quadrant?
    @State private var saveFailed = false

    private var overLimit: Bool { WatchCommandPlan.captureOverLimit(text) }
    private var parsed: ParsedCapture { CaptureParser.parse(text) }
    private var quadrant: Quadrant { chosen ?? Quadrant(urgent: parsed.urgent, important: parsed.important) }

    var body: some View {
        NavigationStack {
            List {
                TextField("New task", text: $text)
                    .accessibilityIdentifier("watch-capture-field")

                if overLimit {
                    // Hold the draft rather than let the phone cut it after the fact.
                    Text("Titles are limited to \(FieldLimits.titleRange.upperBound) characters. Shorten it to add.")
                        .font(.footnote).foregroundStyle(.red)
                }

                if !parsed.title.isEmpty {
                    Section("Quadrant") {
                        ForEach(Quadrant.allCases, id: \.self) { q in
                            Button { chosen = q } label: {
                                HStack {
                                    Text(q.title)
                                    Spacer()
                                    if q == quadrant { Image(systemName: "checkmark") }
                                }
                            }
                            .accessibilityLabel(q.title)
                            .accessibilityAddTraits(q == quadrant ? .isSelected : [])
                        }
                    }
                    Button("Add") {
                        if model.capture(text: text, quadrant: quadrant) {
                            dismiss()
                        } else {
                            saveFailed = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(overLimit)
                }
                if saveFailed {
                    Text("Couldn't save to GSD. Please try again.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("watch-capture-error")
                }
            }
            .navigationTitle("New task")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
