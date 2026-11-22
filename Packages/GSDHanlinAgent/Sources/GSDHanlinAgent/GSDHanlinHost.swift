import Foundation
import GSDModel
import GSDStore
import HanlinAgentCore
import HanlinHostContracts
import HanlinPlatformContracts

/// The app must display an actual user approval before this callback returns true.
/// False is the safe default. Model-side approvals are NOT authorization to mutate GSD.
public struct GSDHanlinWriteRequest: Sendable {
    public let tool: String
    public let taskIDs: [String]
    public let description: String
    public init(tool: String, taskIDs: [String], description: String) {
        self.tool = tool; self.taskIDs = taskIDs; self.description = description
    }
}

public struct GSDHanlinArguments: Decodable, Sendable {
    public var id: String?
    public var ids: [String]?
    public var query: String?
    public var status: String?
    public var limit: Int?
    public var title: String?
    public var description: String?
    public var urgent: Bool?
    public var important: Bool?
    public var dueAt: String?
    public var clearDue: Bool?
    public var tags: [String]?
    public var estimateMinutes: Int?
    public var completed: Bool?
    public var subtaskId: String?
    public var dependencyId: String?
    public var quadrant: String?
    public var date: String?
    public var rank: Int?
    public var clear: Bool?
    public var notes: String?
}

/// A real HanlinHostIntegration over GSD's TaskStore and SQLite. All writes use the
/// same GSD services as the UI, including synchronization, reminders and recurrence.
/// No parallel task database and no model-constructed SQL are involved.
public actor GSDHanlinHost: HanlinHostIntegration {
    public nonisolated let apiVersion = HanlinAPIVersion(major: 1, minor: 1)
    public typealias WriteAuthorizer = @Sendable (GSDHanlinWriteRequest) async -> Bool
    private let store: TaskStore
    private let writeAuthorizer: WriteAuthorizer
    private var activeContext: HanlinHostContext
    private var cancelled: Set<String> = []
    private var results: [String: HanlinHostExecutionResult] = [:]

    public init(store: TaskStore, context: HanlinHostContext,
                writeAuthorizer: @escaping WriteAuthorizer = { _ in false }) {
        self.store = store; self.activeContext = context; self.writeAuthorizer = writeAuthorizer
    }

    /// Invalidate old scene/account sessions rather than allowing an AI run to mutate
    /// data after an account switch.
    public func setContext(_ context: HanlinHostContext) {
        activeContext = context
        results.removeAll()
    }

    public func context(for session: HanlinHostSession) throws -> HanlinHostContext {
        guard session.context.namespace == activeContext.namespace else { throw HanlinHostError.staleContext }
        return activeContext
    }

    public func catalog(for context: HanlinHostContext) throws -> HanlinHostCatalog {
        guard context == activeContext else { throw HanlinHostError.staleContext }
        return try GSDHanlinToolCatalog.catalog(for: context)
    }

    public func cancel(_ invocation: HanlinToolInvocationID) {
        cancelled.insert(invocation.rawValue)
    }

    public func open(_ destination: HanlinHostDestination) throws -> HanlinHostNavigationResult {
        guard destination.context == activeContext else { throw HanlinHostError.staleContext }
        // Without exact mounted-scene acknowledgement, the SDK must NOT report "presented".
        return .queued(requestID: destination.requestID, context: activeContext)
    }

    public func execute(_ invocation: HanlinHostInvocation,
                        progress: @escaping HanlinHostProgressHandler) async throws -> HanlinHostExecutionResult {
        let request = invocation.request
        if let prior = results[request.id.rawValue] { return prior }
        guard !cancelled.contains(request.id.rawValue),
              invocation.session.context == activeContext,
              request.routingTableRevision == .init(1),
              invocation.expectedRevision == nil,
              let spec = GSDHanlinToolCatalog.specs.first(where: { $0.alias == request.aliasUsed }),
              let schema = try? spec.schemaJSON() else {
            return failed(invocation, "The tool or context is no longer valid", effect: .notDispatched)
        }
        let original = invocation.originalArgumentsJSON ?? (try request.arguments.canonicalJSONData())
        do {
            try HanlinHostSchemaValidation(schemaJSON: schema).validate(argumentsJSON: original)
        } catch {
            return failed(invocation, "Invalid tool parameters", effect: .notDispatched)
        }
        let args: GSDHanlinArguments
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            args = try decoder.decode(GSDHanlinArguments.self, from: original)
        } catch {
            return failed(invocation, "Tool parameters could not be decoded", effect: .notDispatched)
        }

        if spec.writes {
            let approval = GSDHanlinWriteRequest(
                tool: spec.alias, taskIDs: args.ids ?? args.id.map { [$0] } ?? [],
                description: "\(spec.title): \(args.title ?? args.id ?? "several tasks")")
            // Explicit host consent, even if the provider/tool loop granted its own approval.
            let allowed = await writeAuthorizer(approval)
            guard allowed, activeContext == invocation.session.context,
                  !cancelled.contains(request.id.rawValue), !Task.isCancelled else {
                return failed(invocation, "The change was not approved", effect: .notDispatched)
            }
        }

        do {
            try Task.checkCancellation()
            guard activeContext == invocation.session.context,
                  !cancelled.contains(request.id.rawValue) else { throw HanlinHostError.staleContext }
            let json = try await perform(spec.alias, args)
            // A completed DB commit must remain committed even if the caller stops
            // waiting. Never label a post-commit cancellation as rollback.
            let response = HanlinHostExecutionResult(
                result: .init(invocationID: request.id, logicalToolID: request.logicalToolID,
                              outcome: .completed([.text(json)]), completedAt: .now),
                effectState: spec.writes ? .confirmedCommitted : .confirmedNoEffect,
                context: invocation.session.context,
                reconciliationReference: spec.writes ? request.id.rawValue : nil)
            results[request.id.rawValue] = response
            return response
        } catch {
            // GSD bulk operations may partly succeed. Do not blindly retry a write.
            let response = failed(invocation, spec.writes
                ? "Write outcome needs reconciliation before retry"
                : "Task read failed", effect: spec.writes ? .uncertain : .confirmedNoEffect)
            results[request.id.rawValue] = response
            return response
        }
    }

    private func failed(_ invocation: HanlinHostInvocation, _ message: String,
                        effect: HanlinHostEffectState) -> HanlinHostExecutionResult {
        .init(result: .init(
            invocationID: invocation.request.id, logicalToolID: invocation.request.logicalToolID,
            outcome: .failed(.init(code: effect == .notDispatched ? .permissionDenied : .nativeFailure,
                                   userMessage: message)), completedAt: .now),
              effectState: effect, context: invocation.session.context,
              reconciliationReference: effect == .uncertain ? invocation.request.id.rawValue : nil)
    }

    private func perform(_ tool: String, _ a: GSDHanlinArguments) async throws -> String {
        switch tool {
        case "list_tasks":
            var tasks = try await store.fetchAllTasks()
            if a.status == "open" { tasks.removeAll { $0.completed } }
            if a.status == "completed" { tasks.removeAll { !$0.completed } }
            if let quadrant = a.quadrant, let q = Self.quadrant(quadrant) {
                tasks.removeAll { $0.quadrant != q }
            }
            if let query = a.query {
                tasks.removeAll { !$0.title.localizedStandardContains(query) &&
                    !$0.description.localizedStandardContains(query) &&
                    !$0.tags.contains(where: { $0.localizedStandardContains(query) }) }
            }
            return try Self.encode(Array(tasks.prefix(a.limit ?? 100)))
        case "get_task":
            guard let id = a.id, let task = try await store.fetchTask(id: id) else {
                throw HanlinHostError.invalidArguments
            }
            return try Self.encode(task)
        case "get_dashboard":
            let tasks = try await store.fetchAllTasks()
            let now = Date()
            let open = tasks.filter { !$0.completed && !$0.isSaved }
            let quadrantCounts = Dictionary(grouping: open, by: { $0.quadrant.rawValue })
                .mapValues(\.count)
            let summary = Dashboard(
                total: tasks.count, open: open.count,
                completed: tasks.filter(\.completed).count,
                overdue: open.filter { ($0.dueDate ?? .distantFuture) < now }.count,
                saved: tasks.filter(\.isSaved).count,
                estimatedOpenMinutes: open.reduce(0) { $0 + ($1.estimatedMinutes ?? 0) },
                byQuadrant: quadrantCounts)
            return try Self.encode(summary)
        case "list_tags":
            let tasks = try await store.fetchAllTasks()
            return try Self.encode(Array(Set(tasks.flatMap(\.tags))).sorted())
        case "list_smart_views":
            let views = await store.allViews
            return try Self.encode(views.map {
                ViewSummary(id: $0.id, name: $0.name, icon: $0.icon, builtIn: $0.isBuiltIn)
            })
        case "list_saved_tasks":
            return try Self.encode((try await store.fetchAllTasks()).filter(\.isSaved))
        case "list_archived_tasks":
            return try Self.encode(await store.archivedTasks)
        case "list_trashed_tasks":
            return try Self.encode(try await store.trashedTasks())
        case "create_task":
            guard let title = a.title else { throw HanlinHostError.invalidArguments }
            let now = Date()
            let task = GSDModel.Task(
                id: IDGenerator.generate(size: IDGenerator.Size.task),
                title: title, description: a.description ?? "",
                urgent: a.urgent ?? false, important: a.important ?? true,
                createdAt: now, updatedAt: now,
                dueDate: try Self.date(a.dueAt),
                tags: a.tags ?? [], estimatedMinutes: a.estimateMinutes)
            try await store.create(task)
            return try Self.encode(task)
        case "update_task":
            guard let id = a.id, let original = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            var task = original
            if let title = a.title { task.title = title }
            if let description = a.description { task.description = description }
            if let urgent = a.urgent { task.urgent = urgent }
            if let important = a.important { task.important = important }
            if a.clearDue == true { task.dueDate = nil }
            else if let due = a.dueAt { task.dueDate = try Self.date(due) }
            if let tags = a.tags { task.tags = tags }
            if let estimate = a.estimateMinutes { task.estimatedMinutes = estimate }
            guard try await store.saveEdits(task, openedAs: original) else {
                throw HanlinHostError.staleContext
            }
            return try Self.encode(try await store.fetchTask(id: id))
        case "set_completed":
            guard let id = a.id, let completed = a.completed,
                  let task = try await store.fetchTask(id: id) else { throw HanlinHostError.invalidArguments }
            if task.completed != completed { try await store.toggleComplete(task) }
            return try Self.encode(CompletionSummary(id: id, completed: completed))
        case "delete_task":
            guard let id = a.id, let task = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            try await store.delete(task)
            return try Self.encode(["trashed": id])
        case "add_subtask":
            guard let id = a.id, let title = a.title, let task = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            try await store.addSubtask(to: task, title: title)
            return try Self.encode(try await store.fetchTask(id: id))
        case "toggle_subtask":
            guard let id = a.id, let subtaskID = a.subtaskId, let task = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            try await store.toggleSubtask(in: task, subtaskID: subtaskID)
            return try Self.encode(try await store.fetchTask(id: id))
        case "add_dependency":
            guard let id = a.id, let dependency = a.dependencyId, let task = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            try await store.addDependency(dependency, to: task)
            return try Self.encode(try await store.fetchTask(id: id))
        case "remove_dependency":
            guard let id = a.id, let dependency = a.dependencyId, let task = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            try await store.removeDependency(dependency, from: task)
            return try Self.encode(try await store.fetchTask(id: id))
        case "bulk_complete":
            let outcome = try await store.bulkComplete(ids: Set(a.ids ?? []))
            return try Self.encode(BulkSummary(outcome))
        case "bulk_add_tags":
            let outcome = try await store.bulkAddTags(ids: Set(a.ids ?? []), tags: a.tags ?? [])
            return try Self.encode(BulkSummary(outcome))
        case "bulk_move":
            guard let q = a.quadrant.flatMap(Self.quadrant) else { throw HanlinHostError.invalidArguments }
            let outcome = try await store.bulkMove(ids: Set(a.ids ?? []), to: q)
            return try Self.encode(BulkSummary(outcome))
        case "set_focus":
            guard let id = a.id else { throw HanlinHostError.invalidArguments }
            let date: String? = a.clear == true ? nil : a.date
            let rank: Int? = a.clear == true ? nil : a.rank
            guard a.clear == true || (date != nil && rank != nil) else {
                throw HanlinHostError.invalidArguments
            }
            try await store.setFocus(id: id, date: date, rank: rank)
            return try Self.encode(try await store.fetchTask(id: id))
        case "start_timer":
            guard let id = a.id, let task = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            try await store.startTimer(task)
            return try Self.encode(["timerStarted": id])
        case "stop_timer":
            guard let id = a.id, let task = try await store.fetchTask(id: id)
            else { throw HanlinHostError.invalidArguments }
            try await store.stopTimer(task, notes: a.notes)
            return try Self.encode(["timerStopped": id])
        default: throw HanlinHostError.unknownTool
        }
    }

    private static func quadrant(_ value: String) -> Quadrant? {
        switch value {
        case "do_first": .urgentImportant
        case "schedule": .notUrgentImportant
        case "delegate": .urgentNotImportant
        case "eliminate": .notUrgentNotImportant
        default: nil
        }
    }

    private static func date(_ raw: String?) throws -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = iso.date(from: raw) { return value }
        iso.formatOptions = [.withInternetDateTime]
        if let value = iso.date(from: raw) { return value }
        iso.formatOptions = [.withFullDate]
        if let value = iso.date(from: raw) { return value }
        throw HanlinHostError.invalidArguments
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw HanlinHostError.outputLimitExceeded
        }
        return text
    }

    private struct CompletionSummary: Encodable { let id: String; let completed: Bool }
    private struct Dashboard: Encodable {
        let total: Int
        let open: Int
        let completed: Int
        let overdue: Int
        let saved: Int
        let estimatedOpenMinutes: Int
        let byQuadrant: [String: Int]
    }
    private struct ViewSummary: Encodable {
        let id: String
        let name: String
        let icon: String
        let builtIn: Bool
    }
    private struct BulkSummary: Encodable {
        let completedIDs: [String]
        let failures: [Failure]
        struct Failure: Encodable { let taskID: String; let message: String }
        init(_ outcome: BulkActionResult) {
            completedIDs = outcome.completedIDs.sorted()
            failures = outcome.failures.map { .init(taskID: $0.taskID, message: $0.message) }
        }
    }
}
