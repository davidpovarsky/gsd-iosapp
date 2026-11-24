import Foundation
import GSDModel

/// Presentation intent only. Task values are always resolved from the live store.
public enum GSDTaskWorkspacePresentation: String, Codable, CaseIterable, Hashable, Sendable {
    case graph, board, timeline, network, table
}

public struct GSDTaskWorkspaceRequest: Codable, Hashable, Sendable {
    public var presentation: GSDTaskWorkspacePresentation
    public var title: String?
    /// nil follows all current matrix tasks; [] intentionally selects no tasks.
    public var taskIDs: [String]?

    public init(presentation: GSDTaskWorkspacePresentation = .graph,
                title: String? = nil, taskIDs: [String]? = nil) {
        self.presentation = presentation
        self.title = title
        self.taskIDs = taskIDs
    }

    public static func validated(presentation: String?, title: String?, taskIDs: [String]?,
                                 tasks: [GSDModel.Task]) throws -> Self {
        guard let mode = GSDTaskWorkspacePresentation(rawValue: presentation ?? "graph") else {
            throw GSDTaskWorkspaceError.invalidPresentation
        }
        let existingIDs = Set(tasks.map(\.id))
        var selectedIDs: [String]?
        if let taskIDs {
            guard taskIDs.allSatisfy(existingIDs.contains) else {
                throw GSDTaskWorkspaceError.missingTask
            }
            var seen = Set<String>()
            selectedIDs = taskIDs.filter { seen.insert($0).inserted }
        }
        return .init(presentation: mode, title: title, taskIDs: selectedIDs)
    }

    /// Saved prerequisites remain in the projection even though they are outside the matrix.
    /// Missing roots can disappear after an ordinary delete; the view explains that change.
    public func visibleTasks(in tasks: [GSDModel.Task]) -> [GSDModel.Task] {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pending = taskIDs ?? tasks.filter { !$0.isSaved }.map(\.id)
        var included = Set<String>()
        while let id = pending.popLast() {
            guard included.insert(id).inserted, let task = byID[id] else { continue }
            pending.append(contentsOf: task.dependencies)
        }
        return tasks.filter { included.contains($0.id) }
    }
}

public enum GSDTaskWorkspaceError: Error, LocalizedError, Equatable {
    case missingTask
    case savedRequiresReturn
    case invalidPresentation
    case invalidLane
    case unsupportedPlannedDate

    public var errorDescription: String? {
        switch self {
        case .missingTask:
            String(localized: "This task is no longer available. Refresh the workspace and try again.")
        case .savedRequiresReturn:
            String(localized: "Return this saved item to the matrix before changing it here.")
        case .invalidPresentation:
            String(localized: "This workspace view is not supported.")
        case .invalidLane:
            String(localized: "This task board column is not available.")
        case .unsupportedPlannedDate:
            String(localized: "GSD uses due dates. Change the due date instead.")
        }
    }
}
