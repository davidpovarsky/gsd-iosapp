import Foundation
import GSDModel

/// The fixtures the screenshot and video harness seeds through `--demo-seed`: 24 tasks across the
/// four quadrants, 14 of them completed over the two weeks before `now`, so the dashboard trend
/// reads like real history. They live in the package so the seed's one safety rule is testable.
///
/// The rule: `seed` fills an empty store and refuses any other. On 2026-10-24 the Mac widths
/// harness ran the seed against the owner's real store. A dev-signed Catalyst build shares the
/// App Group container and the keychain session with the installed app, so the seed trashed 166
/// real tasks and pushed their deletes to PocketBase. The seed has no delete path any more, and
/// the App adds the outer fence: a harness launch (`HarnessLaunch`) opens an in-memory database,
/// runs signed out, and points every shared seam at scratch, so even a seed that passes this
/// check cannot reach the server or the real app.
public enum DemoFixtures {
    public enum SeedError: Error, Equatable {
        /// The store holds at least one task, fixture or real. Nothing was changed.
        case storeNotEmpty
    }

    /// Every fixture id, for tests that check a seeded store.
    public static let ids: Set<String> = Set(tasks(now: Date(timeIntervalSince1970: 0)).map(\.id))

    /// Fill an empty store. Every harness launch opens a fresh in-memory store, so a non-empty one
    /// means the seed is somewhere it must not be, and it is refused untouched.
    @MainActor
    public static func seed(into store: TaskStore, now: Date) async throws {
        guard try await store.fetchAllTasks().isEmpty else { throw SeedError.storeNotEmpty }
        for task in tasks(now: now) {
            try await store.create(task)
            // create() stamps createdAt with "now"; save() keeps the task's own. The second
            // write backdates the seeded creation so the dashboard's Created trend reads like
            // real history instead of one spike on the demo day.
            if task.createdAt < now { try await store.save(task) }
        }
    }

    public static func tasks(now: Date) -> [Task] {
        let cal = Calendar.current
        func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }
        func daysFromNow(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: now)! }

        // urgent/important → quadrant: (T,T) Do First · (F,T) Schedule · (T,F) Delegate · (F,F) Eliminate
        // `created` is days ago, so the dashboard's Created trend spreads across the past two weeks.
        func t(_ id: String, _ title: String, u: Bool, i: Bool,
               tags: [String] = [], recurrence: RecurrenceType = .none,
               subtasks: [Subtask] = [], deps: [String] = [],
               due: Date? = nil, done: Date? = nil, created: Int = 0) -> Task {
            Task(id: id, title: title, urgent: u, important: i,
                 completed: done != nil, completedAt: done,
                 createdAt: daysAgo(created), updatedAt: now, dueDate: due,
                 recurrence: recurrence, tags: tags, subtasks: subtasks, dependencies: deps)
        }

        var out: [Task] = []
        // ---- Active: Do First ---- (varied due dates so the cards read realistically AND
        // deterministically against the frozen demo clock: today / +2d / overdue)
        out.append(t("demo-finance", String(localized: "Get finance sign-off"), u: true, i: true, tags: [String(localized: "work")],
                     due: cal.startOfDay(for: now), created: 1))
        out.append(t("demo-deck", String(localized: "Finish the Q3 board deck"), u: true, i: true, tags: [String(localized: "work")],
                     subtasks: [Subtask(id: "sub1", title: String(localized: "Pull revenue numbers"), completed: true),
                                Subtask(id: "sub2", title: String(localized: "Draft the narrative")),
                                Subtask(id: "sub3", title: String(localized: "Design the key slides"))],
                     deps: ["demo-finance"], due: daysFromNow(2), created: 3))
        // Overdue, and kept free of subtasks/deps so it's the clean card we complete on camera.
        out.append(t("demo-investor", String(localized: "Reply to the investor email"), u: true, i: true, tags: [String(localized: "work")],
                     due: daysAgo(1), created: 2))
        // ---- Active: Schedule ----
        out.append(t("demo-vacation", String(localized: "Plan the summer vacation"), u: false, i: true, tags: [String(localized: "family")],
                     due: daysFromNow(7), created: 5))
        out.append(t("demo-physical", String(localized: "Book the annual physical"), u: false, i: true, tags: [String(localized: "health")],
                     created: 9))
        out.append(t("demo-passport", String(localized: "Renew passport"), u: false, i: true, tags: [String(localized: "family")],
                     due: daysFromNow(30), created: 4))
        // ---- Active: Delegate ----
        out.append(t("demo-newsletter", String(localized: "Send the weekly newsletter"), u: true, i: false,
                     tags: [String(localized: "work")], recurrence: .weekly, due: daysFromNow(1), created: 6))
        out.append(t("demo-supplies", String(localized: "Order office supplies"), u: true, i: false, tags: [String(localized: "errands")],
                     created: 1))
        // ---- Active: Eliminate ----
        out.append(t("demo-downloads", String(localized: "Sort the downloads folder"), u: false, i: false, tags: [String(localized: "errands")],
                     created: 8))
        out.append(t("demo-reviews", String(localized: "Browse gadget reviews"), u: false, i: false, created: 12))

        // ---- Completed history (drives the Dashboard trend; completedAt is preserved by create()) ----
        let done: [(String, String, Bool, Bool, [String], Int)] = [
            ("d-expense", String(localized: "Submit the expense report"), true, true, [String(localized: "work")], 1),
            ("d-standup", String(localized: "Write standup notes"), true, false, [String(localized: "work")], 1),
            ("d-dentist", String(localized: "Call the dentist"), false, true, [String(localized: "health")], 2),
            ("d-pr", String(localized: "Review PR #482"), true, true, [String(localized: "work")], 2),
            ("d-water", String(localized: "Water the plants"), false, false, [String(localized: "home")], 3),
            ("d-card", String(localized: "Pay the credit card"), false, true, [String(localized: "errands")], 3),
            ("d-grocery", String(localized: "Grocery run"), true, false, [String(localized: "errands")], 4),
            ("d-login", String(localized: "Fix the login bug"), true, true, [String(localized: "work")], 5),
            ("d-walk", String(localized: "Walk the dog"), true, false, [String(localized: "home")], 5),
            ("d-recipe", String(localized: "Try the new recipe"), false, false, [String(localized: "home")], 6),
            ("d-invoice", String(localized: "Send the client invoice"), true, true, [String(localized: "work")], 7),
            ("d-1on1", String(localized: "Prep the 1:1 agenda"), false, true, [String(localized: "work")], 8),
            ("d-laundry", String(localized: "Do the laundry"), true, false, [String(localized: "home")], 9),
            ("d-read", String(localized: "Read the design article"), false, false, [], 11),
        ]
        for (id, title, u, i, tags, ago) in done {
            out.append(t(id, title, u: u, i: i, tags: tags, done: daysAgo(ago), created: ago + 1 + ago % 3))
        }
        return out
    }
}
