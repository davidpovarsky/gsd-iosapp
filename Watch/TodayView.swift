import SwiftUI
import GSDModel
import GSDSnapshot

/// The home screen (spec 4.1). With picks: rows in rank order, each with a complete control. With
/// none: "Pick up to three for today" and the first three suggestions, each with "Add to today".
/// `TopThree` decides everything; this view draws it. Carry-over and Tidy stay on the iPhone.
struct TodayView: View {
    @Environment(WatchModel.self) private var model
    /// Whether this page is the one on screen, so only it answers a tapped reminder.
    let active: Bool
    @State private var capturePresentation: CaptureView.Presentation?

    var body: some View {
        let today = model.today()
        let origin = model.actionLease
        NavigationStack {
          ScrollViewReader { proxy in
            List {
                if !model.hasSnapshot {
                    Text("Open GSD on your iPhone to load your tasks.")
                        .foregroundStyle(.secondary)
                } else if !today.picks.isEmpty {
                    Section {
                        ForEach(Array(today.picks.enumerated()), id: \.element.id) { index, task in
                            PickRow(task: task, origin: origin, label: today.rowLabel(at: index))
                        }
                    } header: {
                        Text("Today").accessibilityLabel(today.sectionLabel)
                    }
                } else if today.suggestions.isEmpty {
                    Text("Nothing to pick from yet")
                        .foregroundStyle(.secondary)
                } else {
                    Section("Pick up to three for today") {
                        ForEach(today.suggestions) { task in
                            Button { model.addToToday(task, origin: origin) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title)
                                    Text("Add to today").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel("Add \(task.title) to today")
                        }
                    }
                }

                let pendingCount = model.lists().pendingCount
                if pendingCount > 0 || model.hasSnapshot || model.quarantinedCount > 0 {
                    Section { WatchFooter(pending: pendingCount) }
                }
            }
            .navigationTitle("Today")
            .safeAreaInset(edge: .bottom) { WatchUndoBar() }
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        capturePresentation = .init(origin: model.actionLease)
                    } label: { Label("Add task", systemImage: "plus") }
                }
            }
            .onChange(of: model.openedTaskID, initial: true) { _, _ in openTask(proxy, today: today) }
            .onChange(of: active) { _, _ in openTask(proxy, today: today) }
          }
        }
        .sheet(item: $capturePresentation) { presentation in
            CaptureView(origin: presentation.origin)
        }
    }

    private func openTask(_ proxy: ScrollViewProxy, today: WatchToday) {
        guard active, let id = model.openedTaskID, today.picks.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id, anchor: .center)
        model.consumeOpenedTask()
    }
}

private struct PickRow: View {
    @Environment(WatchModel.self) private var model
    let task: WatchTask
    let origin: WatchModel.ActionLease?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
            if let due = task.dueDate {
                Text(due.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(task.dueDate.map { String(localized: "\(label), due \($0.formatted(date: .abbreviated, time: .omitted))") } ?? label)
        .swipeActions(edge: .leading) {
            Button { model.complete(task, origin: origin) } label: { Label("Complete", systemImage: "checkmark") }
                .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button { model.removeFromToday(task, origin: origin) } label: { Label("Remove from today", systemImage: "minus.circle") }
        }
    }
}
