import Foundation
import HanlinAgentCore
import HanlinHostContracts
import HanlinPlatformContracts

/// Every model-visible action is declared here. No wildcard tools or implicit writes.
public enum GSDHanlinToolCatalog {
    public enum Field: Sendable {
        case text(Int)
        case bool
        case int(Int, Int)
        case choice([String])
        case texts(Int, Int)

        func schema() -> [String: Any] {
            switch self {
            case .text(let max): return ["type": "string", "minLength": 1, "maxLength": max]
            case .bool: return ["type": "boolean"]
            case .int(let min, let max): return ["type": "integer", "minimum": min, "maximum": max]
            case .choice(let allowed): return ["type": "string", "enum": allowed]
            case .texts(let count, let length):
                return ["type": "array", "maxItems": count,
                        "items": ["type": "string", "minLength": 1, "maxLength": length]]
            }
        }
    }

    public struct Spec: Sendable {
        public let alias: String
        public let title: String
        public let summary: String
        public let writes: Bool
        public let fields: [String: Field]
        public let required: [String]

        init(_ alias: String, _ title: String, _ summary: String, writes: Bool = false,
             fields: [String: Field] = [:], required: [String] = []) {
            self.alias = alias; self.title = title; self.summary = summary
            self.writes = writes; self.fields = fields; self.required = required
        }

        public func schemaJSON() throws -> Data {
            let properties = fields.mapValues { $0.schema() }
            let schema: [String: Any] = ["type": "object", "properties": properties,
                                         "required": required, "additionalProperties": false]
            return try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        }
    }

    // 22 scoped tools. Read results are JSON, mutations require host approval again
    // even when the model/provider already approved its tool call.
    public static let specs: [Spec] = [
        .init("list_tasks", "List tasks", "Search and filter active GSD tasks",
              fields: ["query": .text(200), "status": .choice(["all","open","completed"]),
                       "quadrant": .choice(["do_first","schedule","delegate","eliminate"]),
                       "limit": .int(1, 200)]),
        .init("get_task", "Get task", "Get one task by its exact local ID",
              fields: ["id": .text(128)], required: ["id"]),
        .init("get_dashboard", "Task dashboard", "Overview and totals grouped by priority and due date"),
        .init("list_tags", "List tags", "List tags used in the local task database"),
        .init("list_smart_views", "Smart views", "List saved GSD smart views"),
        .init("list_saved_tasks", "Saved tasks", "Read tasks saved for later"),
        .init("list_archived_tasks", "Archived tasks", "Read archived task records"),
        .init("list_trashed_tasks", "Trashed tasks", "Read recoverable trash records"),
        .init("create_task", "Create task", "Create a task in GSD's canonical write path",
              writes: true,
              fields: ["title": .text(80), "description": .text(600), "urgent": .bool,
                       "important": .bool, "due_at": .text(50),
                       "tags": .texts(20,30), "estimate_minutes": .int(1,10080)],
              required: ["title"]),
        .init("update_task", "Update task", "Change editable fields without overwriting newer data",
              writes: true,
              fields: ["id": .text(128), "title": .text(80), "description": .text(600),
                       "urgent": .bool, "important": .bool, "due_at": .text(50),
                       "clear_due": .bool, "tags": .texts(20,30), "estimate_minutes": .int(1,10080)],
              required: ["id"]),
        .init("set_completed", "Complete or reopen", "Set the completion state with recurrence handling",
              writes: true, fields: ["id": .text(128), "completed": .bool],
              required: ["id","completed"]),
        .init("delete_task", "Move task to trash", "Soft-delete a task; recoverable in Trash",
              writes: true, fields: ["id": .text(128)], required: ["id"]),
        .init("add_subtask", "Add subtask", "Append a subtask to an existing task",
              writes: true, fields: ["id": .text(128), "title": .text(100)], required: ["id","title"]),
        .init("toggle_subtask", "Toggle subtask", "Switch a subtask completion state",
              writes: true, fields: ["id": .text(128), "subtask_id": .text(128)],
              required: ["id","subtask_id"]),
        .init("add_dependency", "Add dependency", "Block one task on another task",
              writes: true, fields: ["id": .text(128), "dependency_id": .text(128)],
              required: ["id","dependency_id"]),
        .init("remove_dependency", "Remove dependency", "Remove a dependency edge",
              writes: true, fields: ["id": .text(128), "dependency_id": .text(128)],
              required: ["id","dependency_id"]),
        .init("bulk_complete", "Bulk complete", "Complete several tasks using GSD's bulk service",
              writes: true, fields: ["ids": .texts(100,128)], required: ["ids"]),
        .init("bulk_add_tags", "Bulk add tags", "Add tags to multiple tasks",
              writes: true, fields: ["ids": .texts(100,128), "tags": .texts(20,30)],
              required: ["ids","tags"]),
        .init("bulk_move", "Bulk reprioritize", "Move tasks into a chosen matrix quadrant",
              writes: true, fields: ["ids": .texts(100,128),
                                    "quadrant": .choice(["do_first","schedule","delegate","eliminate"])],
              required: ["ids","quadrant"]),
        .init("set_focus", "Focus pick", "Set or clear one of the three daily focus slots",
              writes: true, fields: ["id": .text(128), "date": .text(10), "rank": .int(1,3),
                                    "clear": .bool], required: ["id"]),
        .init("start_timer", "Start timer", "Start time tracking on an active task",
              writes: true, fields: ["id": .text(128)], required: ["id"]),
        .init("stop_timer", "Stop timer", "Stop time tracking on a task",
              writes: true, fields: ["id": .text(128), "notes": .text(200)], required: ["id"])
    ]

    public static func descriptor(for spec: Spec) throws -> HanlinHostTool {
        let logical = HanlinLogicalToolID(
            providerInstanceID: try .init(validating: "gsd.agent"),
            localToolID: try .init(validating: spec.alias))
        let revision = try HanlinDescriptorRevision(1)
        let original = try spec.schemaJSON()
        // Use the SDK's actual schema contracts, never hand-build a model-side surrogate.
        let schema = try HanlinJSONSchemaDocument.decodeCanonicalJSON(original,
            defaultDialect: .draft2020_12)
        let descriptor = HanlinToolDescriptor(
            logicalID: logical, descriptorRevision: revision, owner: .system,
            title: try .init(["en": spec.title]),
            summary: try .init(["en": spec.summary]),
            inputSchema: schema, risk: spec.writes ? .write : .read, presentation: .init())
        return HanlinHostTool(
            route: .init(alias: spec.alias, logicalToolID: logical, descriptorRevision: revision),
            descriptor: descriptor,
            writeGuarantee: spec.writes ? .hostManagedMutation : .readOnly,
            originalInputSchemaJSON: original)
    }

    public static func catalog(for context: HanlinHostContext) throws -> HanlinHostCatalog {
        let tools = try specs.map(descriptor(for:))
        let result = HanlinHostCatalog(apiVersion: .init(major: 1, minor: 1),
            revision: .init(1), context: context, tools: tools)
        try result.validate()
        return result
    }
}
