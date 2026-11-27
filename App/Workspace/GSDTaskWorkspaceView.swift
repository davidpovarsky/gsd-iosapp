import SwiftUI
import GSDModel
import GSDStore
import GSDHanlinAgent
import TaskVisualizationKit

/// Every view is a projection of the existing store; no card owns a second task value.
struct GSDTaskWorkspaceView: View {
    let store: TaskStore
    var request = GSDTaskWorkspaceRequest()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(SessionStore.self) private var session
    @State private var editor: WorkspaceEditor?
    @State private var presentationSession = GSDTaskWorkspacePresentationSession(
        store: GSDTaskWorkspacePresentationDefaults.store)

    var body: some View {
        TaskWorkspaceView(
            snapshot: snapshot,
            initialPresentation: TaskWorkspacePresentation(rawValue: request.presentation.rawValue) ?? .graph,
            presentationState: presentationSession.binding,
            onAction: perform
        )
        .overlay {
            if !store.hasLoadedTasks {
                ProgressView(String(localized: "Loading tasks…"))
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(item: $editor) { target in
            switch target {
            case .task(let request):
                TaskEditorView(request: request, compactPresenter: sizeClass == .compact)
                    .environment(store)
            case .saved(let target):
                SavedEditorView(target: target).environment(store)
            }
        }
        .task(id: presentationConnection) {
            let observedSession = session
            presentationSession.connect(identityOwner: ObjectIdentifier(observedSession),
                                        rootTaskIDs: request.taskIDs) { [weak observedSession] in
                guard let observedSession else { return nil }
                return GSDTaskWorkspacePresentationAccount.validated(
                    isSignedIn: observedSession.isSignedIn,
                    userID: observedSession.currentUserID,
                    inProgress: observedSession.inProgress,
                    hasPendingAccountSwitch: observedSession.pendingAccountSwitch != nil)
            }
        }
        .onDisappear { presentationSession.disconnect() }
    }

    private var presentationConnection: GSDTaskWorkspacePresentationConnection {
        .init(identity: ObjectIdentifier(session),
              rootTaskIDs: GSDTaskWorkspacePresentationScope.canonicalRoots(request.taskIDs))
    }

    private var snapshot: TaskWorkspaceSnapshot {
        let allTasks = store.tasks
        let graph = DependencyGraph(tasks: allTasks)
        let visible = request.visibleTasks(in: allTasks)
        let tasks = visible.map { task in
            VisualTask(
                id: task.id, title: task.title,
                subtitle: task.isSaved ? String(localized: "Saved prerequisite") : task.description,
                laneID: task.isSaved ? "saved-reference" : task.quadrant.rawValue,
                isCompleted: task.completed, isBlocked: graph.isBlocked(task.id),
                isReadOnly: task.isSaved, dueDate: task.dueDate,
                estimatedMinutes: task.estimatedMinutes, dependencyIDs: task.dependencies,
                subtaskCount: task.subtasks.count,
                completedSubtaskCount: task.subtasks.filter(\.completed).count)
        }
        var lanes = Quadrant.allCases.map {
            VisualTaskLane(id: $0.rawValue, title: $0.title, tone: tone(for: $0))
        }
        if visible.contains(where: \.isSaved) {
            lanes.append(.init(id: "saved-reference", title: String(localized: "Saved references")))
        }
        return TaskWorkspaceSnapshot(
            title: request.title ?? String(localized: "Task workspace"),
            tasks: tasks, lanes: lanes, warnings: warnings(allTasks: allTasks, visible: visible))
    }

    private func warnings(allTasks: [GSDModel.Task], visible: [GSDModel.Task]) -> [String] {
        let existingIDs = Set(allTasks.map(\.id))
        var warnings: [String] = []
        if request.taskIDs?.contains(where: { !existingIDs.contains($0) }) == true {
            warnings.append(String(localized: "Some selected tasks are no longer available."))
        }
        if visible.contains(where: { $0.dependencies.contains(where: { !existingIDs.contains($0) }) }) {
            warnings.append(String(localized: "Some prerequisites are no longer available. Open the task to review its dependencies."))
        }
        if visible.contains(where: \.isSaved) {
            warnings.append(String(localized: "Saved prerequisites still block their dependents. Open them to return them to the matrix."))
        }
        return warnings
    }

    @MainActor
    private func perform(_ action: TaskWorkspaceAction) async throws {
        let commands = GSDTaskWorkspaceMutations(store: store)
        switch action {
        case .openTask(let id):
            guard let task = try await store.fetchTask(id: id) else {
                throw GSDTaskWorkspaceError.missingTask
            }
            editor = task.isSaved ? .saved(.returnToMatrix(task)) : .task(.edit(task))
        case .createTask:
            editor = .task(.new(.notUrgentImportant, prefill: nil))
        case .setCompleted(let id, let completed):
            try await commands.setCompleted(id: id, completed: completed)
        case .moveTask(let id, let laneID):
            guard let quadrant = Quadrant(rawValue: laneID) else {
                throw GSDTaskWorkspaceError.invalidLane
            }
            try await commands.moveTask(id: id, quadrant: quadrant)
        case .setDueDate(let id, let date):
            try await commands.setDueDate(id: id, date: date)
        case .setPlannedDate:
            throw GSDTaskWorkspaceError.unsupportedPlannedDate
        case .addDependency(let prerequisiteID, let dependentID):
            try await commands.addDependency(prerequisiteID: prerequisiteID, dependentID: dependentID)
        case .removeDependency(let prerequisiteID, let dependentID):
            try await commands.removeDependency(prerequisiteID: prerequisiteID, dependentID: dependentID)
        }
    }

    private func tone(for quadrant: Quadrant) -> TaskVisualTone {
        switch quadrant {
        case .urgentImportant: .red
        case .notUrgentImportant: .blue
        case .urgentNotImportant: .orange
        case .notUrgentNotImportant: .green
        }
    }
}

private enum WorkspaceEditor: Identifiable {
    case task(EditorRequest)
    case saved(SavedEditorTarget)

    var id: String {
        switch self {
        case .task(let request): "task-\(request.id)"
        case .saved(let target): "saved-\(target.id)"
        }
    }
}

struct GSDWorkspaceSheet: Identifiable {
    let id = UUID()
    var request = GSDTaskWorkspaceRequest()
}

struct GSDTaskWorkspaceSheet: View {
    let store: TaskStore
    let request: GSDTaskWorkspaceRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GSDTaskWorkspaceView(store: store, request: request)
                .navigationTitle(String(localized: "Task workspace"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Close")) { dismiss() }
                    }
                }
        }
    }
}


@MainActor
private enum GSDTaskWorkspacePresentationDefaults {
    // Existing App-Group UI preferences; HarnessLaunch supplies its reset, isolated suite.
    static let store = GSDTaskWorkspacePresentationStore(defaults: .shared)
}

private struct GSDTaskWorkspacePresentationConnection: Hashable {
    let identity: ObjectIdentifier
    let rootTaskIDs: [String]?
}
