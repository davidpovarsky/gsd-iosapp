import SwiftUI
import GSDSnapshot

/// The pieces both pages share, so a Complete on Today offers the same Undo as on Do First and
/// both say when the iPhone hasn't got a change yet.
struct WatchUndoBar: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let origin = model.actionLease
        if model.canUndo {
            Button("Undo") { model.undo(origin: origin) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Undo complete")
        }
    }
}

/// "2 changes waiting for iPhone" and when the snapshot was last updated.
struct WatchFooter: View {
    @Environment(WatchModel.self) private var model
    let pending: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if pending > 0 {
                Text(pending == 1 ? String(localized: "1 change waiting for iPhone") : String(localized: "\(pending) changes waiting for iPhone"))
            }
            if model.quarantinedCount > 0 {
                Text("Changes on hold: \(model.quarantinedCount)")
                    .accessibilityIdentifier("watch-held-changes")
                Text("These changes are kept on this Watch and have not been sent to the current account or task collection.")
            }
            if model.hasSnapshot {
                Text("Updated \(model.snapshot.generatedAt.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}
