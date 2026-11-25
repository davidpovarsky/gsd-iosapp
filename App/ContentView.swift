import SwiftUI
import CoreSpotlight
import GSDModel
import GSDStore
import GSDSnapshot
import GSDHanlinAgent
#if DEBUG && targetEnvironment(simulator)
import Foundation
import CryptoKit
import Dispatch
import UIKit
#endif

#if DEBUG && targetEnvironment(simulator)
@MainActor
enum WidgetRouteDiagnostics {
    private struct Event: Encodable, Sendable {
        let ordinal: Int
        let uptimeSeconds: TimeInterval
        let timestampUnixSeconds: TimeInterval
        let point: String
        let lifecyclePhase: String
        let applicationState: Int
        let routeKind: String?
        let taskIDSHA256: String?
        let outcome: String?
        let errorDomain: String?
        let errorCode: Int?
    }

    private struct Receipt: Encodable, Sendable {
        let schema = "gsd.widget-route-diagnostics"
        let version = 1
        let diagnosticOnly = true
        let armed = true
        let nonce: String
        let simulatorID: String
        let diagnosticSourceSHA: String
        let processID: Int32
        let truncated: Bool
        let events: [Event]
    }

    private static let writer = DispatchQueue(label: "gsd.widget-route-diagnostics", qos: .utility)
    private static var session: (nonce: String, simulatorID: String, sourceSHA: String)?
    private static var outputURL: URL?
    private static var events: [Event] = []
    private static var lifecyclePhase = "unobserved"
    private static var truncated = false
    static var isArmed: Bool { session != nil }

    static func armAtStartup() {
        let env = ProcessInfo.processInfo.environment
        guard session == nil, env["GSD_WIDGET_ROUTE_DIAGNOSTICS"] == "1",
              let nonce = env["GSD_WIDGET_ROUTE_DIAGNOSTIC_NONCE"],
              nonce.range(of: "^[0-9A-F]{8}$", options: .regularExpression) != nil,
              let simulatorID = env["GSD_WIDGET_ROUTE_DIAGNOSTIC_SIMULATOR_ID"],
              UUID(uuidString: simulatorID) != nil,
              let sourceSHA = env["GSD_WIDGET_ROUTE_DIAGNOSTIC_SOURCE_SHA"],
              sourceSHA.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        outputURL = support.appendingPathComponent("GSDWidgetRouteDiagnostics", isDirectory: true)
            .appendingPathComponent("receipt.json")
        session = (nonce, simulatorID, sourceSHA)
        event("startup-armed")
    }

    static func phaseChanged(_ phase: ScenePhase) {
        guard isArmed else { return }
        switch phase {
        case .active: lifecyclePhase = "active"
        case .inactive: lifecyclePhase = "inactive"
        case .background: lifecyclePhase = "background"
        @unknown default: lifecyclePhase = "unknown"
        }
        event("scene-phase")
    }

    static func incoming(_ url: URL) {
        guard isArmed else { return }
        guard let route = DeepLinkParser.route(from: url) else {
            event("incoming-url", routeKind: "unrecognized")
            return
        }
        switch route {
        case .task(let id): event("incoming-url", taskID: id, routeKind: "task")
        case .focus: event("incoming-url", routeKind: "focus")
        case .capture: event("incoming-url", routeKind: "capture")
        case .quadrant: event("incoming-url", routeKind: "quadrant")
        case .smartView: event("incoming-url", routeKind: "smartView")
        case .dashboard: event("incoming-url", routeKind: "dashboard")
        case .settings: event("incoming-url", routeKind: "settings")
        case .archive: event("incoming-url", routeKind: "archive")
        }
    }

    static func event(_ point: String, taskID: String? = nil, routeKind: String? = nil,
                      outcome: String? = nil, error: Error? = nil) {
        guard isArmed else { return }
        guard events.count < 64 else {
            if !truncated { truncated = true; publish() }
            return
        }
        let failure = error.map { $0 as NSError }
        let allowedDomains = ["GRDB.DatabaseError", "NSCocoaErrorDomain", "NSPOSIXErrorDomain",
                              "_Concurrency.CancellationError"]
        events.append(Event(
            ordinal: events.count, uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            timestampUnixSeconds: Date().timeIntervalSince1970, point: point,
            lifecyclePhase: lifecyclePhase, applicationState: UIApplication.shared.applicationState.rawValue,
            routeKind: routeKind, taskIDSHA256: taskID.flatMap { taskDigest($0) }, outcome: outcome,
            errorDomain: failure.map { allowedDomains.contains($0.domain) ? $0.domain : "other" },
            errorCode: failure?.code))
        publish()
    }

    private static func taskDigest(_ id: String) -> String? {
        let bytes = Array(id.utf8)
        guard (1...64).contains(bytes.count),
              bytes.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private static func publish() {
        guard let session, let outputURL else { return }
        let receipt = Receipt(nonce: session.nonce, simulatorID: session.simulatorID,
                              diagnosticSourceSHA: session.sourceSHA,
                              processID: ProcessInfo.processInfo.processIdentifier,
                              truncated: truncated, events: events)
        // No encoding, file I/O, or await on the routing/main actor.
        writer.async {
            do {
                try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                let bytes = try JSONEncoder().encode(receipt)
                guard bytes.count <= 65_536 else { return }
                try bytes.write(to: outputURL, options: .atomic)
            } catch {
                // Missing/invalid startup receipt makes collection inconclusive, never a pass.
            }
        }
    }
}
#endif


/// Adaptive root. Compact (iPhone): a TabView (Matrix · Browse · Dashboard). Regular (iPad):
/// a NavigationSplitView (sidebar Matrix + Dashboard + Smart Views → detail grid / filtered list).
///
/// Also hosts the ⌘K command palette: a hidden keyboard-shortcut button + the palette
/// sheet + the editor sheet it can open live here, while a shared `PaletteController`
/// (injected into the environment) lets each surface's magnifying-glass toolbar button
/// toggle the same palette and lets the selection handler drive navigation state the
/// surfaces own (tab/sidebar selection, the Browse push path).
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(TaskStore.self) private var store
    @Environment(SessionStore.self) private var session
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(AppGroupDefaults.Key.escalationWindowDays, store: .shared)
    private var escalationWindowRaw = EscalationWindow.default.rawValue

    @State private var palette = PaletteController()
    @State private var undo = UndoTaskController()
    /// Stashed when the palette picks an editor result; acted on in the sheet's onDismiss
    /// so we don't dismiss + present in the same runloop (iOS drops the second present).
    @State private var pendingEditor: EditorRequest?
    @State private var pendingSavedTaskID: String?
    /// Palette "What's new" — presented once the palette sheet has dismissed.
    @State private var pendingWhatsNew = false
    @State private var showWhatsNew = false
    /// Mac "About GSD" panel (app menu), posted by GSDMenuCommands on Catalyst.
    @State private var showHanlinAssistant = false
    @State private var showAbout = false
    /// "Field Guide" help sheet, posted by Settings ▸ About (all platforms) and the Mac Help menu.
    @State private var showHelp = false

    var body: some View {
        routedContent
            // Cross-account guard (design 2026-06-10 Fix C): a DIFFERENT account signed in
            // while this device holds tasks from the previous one — sync is parked until the
            // user chooses. Hosted here so sign-ins from Settings AND Onboarding both surface it.
            .confirmationDialog(
                String(localized: "Different account"),
                isPresented: Binding(
                    get: { session.pendingAccountSwitch != nil },
                    set: { presented in
                        if !presented {
                            // Defer one turn: a button action claims synchronously first, so
                            // this only cancels a no-choice (outside-tap) dismissal.
                            _Concurrency.Task { @MainActor in session.cancelAccountSwitchIfUnresolved() }
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(String(localized: "Keep my tasks")) { session.resolveAccountSwitch(.merge) }
                Button(String(localized: "Start fresh (erase tasks on this device)"), role: .destructive) {
                    session.resolveAccountSwitch(.fresh)
                }
                Button(String(localized: "Cancel"), role: .cancel) { session.resolveAccountSwitch(.cancel) }
            } message: {
                Text(String(localized: "You signed in as \(session.pendingAccountSwitch?.newEmail ?? String(localized: "a different account")), but this device has tasks from a previous account. Keep them and sync them to this account, or start fresh?"))
            }
    }

    // Opaque return boundaries keep the root modifier chain tractable for Swift's
    // type checker while preserving modifier order and state ownership.
    private var assistantContent: some View {
        rootContent
            .sheet(isPresented: $showHanlinAssistant) {
                GSDHanlinAssistantView(store: store, remoteBridge: nil)
                    .environment(session)
            }
            .overlay(alignment: .bottomTrailing) {
                if (sizeClass == .compact && palette.compactTab != 1 && palette.compactTab != 3)
                    || (sizeClass != .compact && palette.regularSelection != .dashboard) {
                    hanlinAssistantButton
                        .padding(.trailing, 18)
                        .padding(.bottom, sizeClass == .compact ? 100 : 24)
                }
            }
    }

    private var hanlinAssistantButton: some View {
        Button {
            showHanlinAssistant = true
        } label: {
            Label("AI", systemImage: "sparkles")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel("Open Hanlin task AI assistant")
        .accessibilityIdentifier("hanlin.assistant.open")
    }

    private var assistantInset: some View {
        hanlinAssistantButton
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background(Surface.paper)
    }

    private var actionContent: some View {
        assistantContent
            .environment(palette)
            .environment(\.escalationWindow, EscalationWindow(rawValue: escalationWindowRaw) ?? .default)
            // Hidden ⌘K trigger — a zero-size button carrying the keyboard shortcut so the
            // hardware ⌘K opens the palette anywhere in the app.
            .background { keyboardShortcuts }
            // Root-hosted so a delete from ANY surface gets the same Undo window. Compact hosts
            // it as the tab bar's accessory (see UndoTaskAccessory); regular keeps the capsule.
            .overlay(alignment: .bottom) {
                if sizeClass != .compact {
                    UndoTaskToast(undo: undo).padding(.bottom, 24)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdTaskDeleted)) { note in
                guard let task = note.object as? Task else { return }
                undo.noteDeleted(task)
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdTaskSaved)) { note in
                guard let task = note.object as? Task else { return }
                undo.noteSaved(task)
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdTaskMarkedUrgent)) { note in
                guard let task = note.object as? Task else { return }
                undo.noteMarkedUrgent(task)
            }
            .taskActionFailureAlert($undo.failure)
            // An iPhone Duo closes and opens mid-session (an iPad window resizes), and each root
            // keeps its own selection, so carry the surface in view across the swap.
            .onChange(of: sizeClass) { _, size in
                if size == .compact { palette.carryToCompact() } else { palette.carryToRegular() }
            }
    }

    private var presentedContent: some View {
        actionContent
            // Catalyst re-inject: its sheet hosting controller evaluates the presentation's
            // preferences before it inherits the presenter's environment, so @Observable stores
            // must be re-applied on the presented content (a no-op on iOS). Without it, the sheet's
            // @Environment(TaskStore.self) read traps ("No Observable object of type TaskStore").
            .sheet(isPresented: $palette.showPalette, onDismiss: presentPendingEditor) {
                CommandPaletteView(onSelect: handle).environment(store)
            }
            // The one task editor sheet for every surface (see PaletteController.editor).
            .sheet(item: $palette.editor) {
                TaskEditorView(request: $0, compactPresenter: sizeClass == .compact).environment(store)
            }
            .sheet(isPresented: $showAbout) { AboutView().presentationSizing(.fitted) }
            .sheet(isPresented: $showHelp) { HelpView(compactPresenter: sizeClass == .compact) }
            .sheet(isPresented: $showWhatsNew) {
                NavigationStack {
                    WhatsNewView().toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { showWhatsNew = false }
                        }
                    }
                }
            }
    }

    private var routedContent: some View {
        presentedContent
            .onOpenURL { url in
                #if DEBUG && targetEnvironment(simulator)
                WidgetRouteDiagnostics.incoming(url)
                #endif
                handleDeepLink(url)
            }
            .onContinueUserActivity(CSSearchableItemActionType, perform: handleSpotlightActivity)
            .onReceive(NotificationCenter.default.publisher(for: .gsdOpenDeepLink)) { notification in
                guard let url = notification.object as? URL else { return }
                // Delivered live — clear the persisted copy or it replays on the next cold launch.
                DeepLinkHandoff.clearPendingURL()
                handleDeepLink(url)
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdShowCommandPalette)) { _ in
                palette.showPalette = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdShowAbout)) { _ in
                showAbout = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdShowHelp)) { _ in
                showHelp = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdShowWhatsNew)) { _ in
                showWhatsNew = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .gsdSyncNow)) { _ in
                _Concurrency.Task { await session.syncNow() }
            }
            .task {
                if let url = DeepLinkHandoff.consumePendingURL() {
                    handleDeepLink(url)
                }
            }
    }

    @ViewBuilder private var keyboardShortcuts: some View {
        #if targetEnvironment(macCatalyst)
        // On Mac these shortcuts live in the menu bar (GSDMenuCommands) — avoid double-binding.
        // ⌘F is intentionally not re-provided on Mac (the palette opens with ⌘K); ⌘F is left to
        // the system text-find layer.
        EmptyView()
        #else
        Group {
            Button("", action: { palette.showPalette = true })
                .keyboardShortcut("k", modifiers: .command)
            Button("", action: { palette.showPalette = true })
                .keyboardShortcut("f", modifiers: .command)
            Button("", action: { palette.editor = .new(.urgentImportant, prefill: nil) })
                .keyboardShortcut("n", modifiers: .command)
            // Help lists ⌘? ("Open this field guide"); on Mac the Help menu binds it.
            Button("", action: { showHelp = true })
                .keyboardShortcut("?", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.urgentImportant).url) })
                .keyboardShortcut("1", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.notUrgentImportant).url) })
                .keyboardShortcut("2", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.urgentNotImportant).url) })
                .keyboardShortcut("3", modifiers: .command)
            Button("", action: { handleDeepLink(DeepLinkRoute.quadrant(.notUrgentNotImportant).url) })
                .keyboardShortcut("4", modifiers: .command)
        }
        .opacity(0)
        .accessibilityHidden(true)
        #endif
    }

    private func handleDeepLink(_ url: URL) {
        guard let route = DeepLinkParser.route(from: url) else { return }  // ignores gsd://oauth-callback
        switch route {
        case .focus:
            navigate(to: .matrix)   // the Matrix's Q1 quadrant IS today's focus
        case .capture:
            palette.editor = .new(.urgentImportant, prefill: nil)
        case .quadrant(let quadrant):
            navigate(to: .matrix)
            palette.focusedQuadrant = quadrant
        case .task(let id):
            openTask(id)
        case .smartView(let id):
            openSmartView(id)
        case .dashboard:
            navigate(to: .dashboard)
        case .settings:
            navigate(to: .settings)
        case .archive:
            navigate(to: .archive)
        }
    }

    /// Resolve a task link by direct repository read: on a cold launch (widget tap,
    /// Spotlight result, pending handoff) the observation snapshot is still empty when
    /// the URL arrives, so a `store.tasks` lookup would silently miss every time.
    private func openTask(_ id: String) {
        _Concurrency.Task { @MainActor in
            #if DEBUG && targetEnvironment(simulator)
            if WidgetRouteDiagnostics.isArmed {
                WidgetRouteDiagnostics.event("task-fetch-start", taskID: id)
                do {
                    if let task = try await store.fetchTask(id: id) {
                        WidgetRouteDiagnostics.event("task-fetch-result", taskID: id, outcome: "found")
                        if task.isSaved {
                            openSavedTask(task.id)
                            WidgetRouteDiagnostics.event("saved-task-requested", taskID: id)
                        } else {
                            palette.editor = .edit(task)
                            WidgetRouteDiagnostics.event("task-editor-assigned", taskID: id)
                        }
                    } else {
                        WidgetRouteDiagnostics.event("task-fetch-result", taskID: id, outcome: "missing")
                        navigate(to: .matrix)
                        WidgetRouteDiagnostics.event("matrix-fallback", taskID: id, outcome: "missing")
                    }
                } catch {
                    WidgetRouteDiagnostics.event("task-fetch-result", taskID: id, outcome: "error", error: error)
                    navigate(to: .matrix)
                    WidgetRouteDiagnostics.event("matrix-fallback", taskID: id, outcome: "error")
                }
                return
            }
            #endif
            if let task = try? await store.fetchTask(id: id) {
                if task.isSaved { openSavedTask(task.id) }
                else { palette.editor = .edit(task) }
            } else {
                navigate(to: .matrix)
            }
        }
    }

    private func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        handleDeepLink(DeepLinkRoute.task(id).url)
    }

    @ViewBuilder private var rootContent: some View {
        if sizeClass == .compact {
            if #available(iOS 26.1, *) {
                compactRoot
                    // The undo window rides the tab bar as its accessory (see UndoTaskAccessory).
                    .tabViewBottomAccessory(isEnabled: undo.action != nil) { UndoTaskAccessory(undo: undo) }
            } else {
                compactRoot
                    // iOS 26.0 has no isEnabled accessory: keep the capsule clear of the tab bar.
                    .overlay(alignment: .bottom) { UndoTaskToast(undo: undo).padding(.bottom, 72) }
            }
        } else {
            RegularRootView { assistantInset }
        }
    }

    private var compactRoot: some View {
        TabView(selection: $palette.compactTab) {
            MatrixView()
                .tabItem { Label(String(localized: "Matrix"), systemImage: "square.grid.2x2") }
                .tag(0)
            SmartViewListView()
                // Reserve space in Browse so the assistant cannot cover a list row.
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    assistantInset
                }
                .tabItem { Label(String(localized: "Browse"), systemImage: "line.3.horizontal.decrease.circle") }
                .tag(1)
            DashboardView()
                .tabItem { Label(String(localized: "Dashboard"), systemImage: "chart.bar.xaxis") }
                .tag(2)
            SettingsView()
                // Keep account explanations and settings rows clear of the assistant.
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    assistantInset
                }
                .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                .tag(3)
        }
        // The floating tab bar shrinks to the active tab while the user scrolls down and
        // returns on scroll up, so on a scrolled matrix the pinned capture bar is the only
        // chrome left in full.
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    private func handle(_ result: PaletteResult) {
        switch result {
        case .openTask(let task):
            if task.isSaved { pendingSavedTaskID = task.id }
            else { pendingEditor = .edit(task) }
        case .newTask: pendingEditor = .new(.urgentImportant, prefill: nil)
        case .toggleShowCompleted: showCompleted.toggle()
        case .toggleTheme:
            let order = AppTheme.allCases
            let current = AppTheme(rawValue: themeRaw) ?? .system
            let next = order[(order.firstIndex(of: current).map { $0 + 1 } ?? 0) % order.count]
            themeRaw = next.rawValue
        case .sendFeedback:
            navigate(to: .settings)
            // SettingsView owns the push (its own NavigationStack) — same handoff
            // pattern as the Help sheet.
            NotificationCenter.default.post(name: .gsdShowFeedback, object: nil)
        case .whatsNew: pendingWhatsNew = true
        case .navigate(let dest): navigate(to: dest)
        case .openSmartView(let id): openSmartView(id)
        }
    }

    /// The palette dismissed; if it picked an editor result, present it now (separate runloop).
    private func presentPendingEditor() {
        if pendingWhatsNew {
            pendingWhatsNew = false
            showWhatsNew = true
            return
        }
        if let id = pendingSavedTaskID {
            pendingSavedTaskID = nil
            openSavedTask(id)
            return
        }
        guard let pending = pendingEditor else { return }
        pendingEditor = nil
        palette.editor = pending
    }

    private func navigate(to dest: PaletteDestination) {
        if sizeClass == .compact {
            switch dest {
            case .matrix: palette.compactTab = 0
            case .browse: palette.compactTab = 1; palette.browsePath = []
            case .archive: palette.compactTab = 1; palette.browsePath = [.archive]
            case .saved: palette.compactTab = 1; palette.browsePath = [.saved]
            case .dashboard: palette.compactTab = 2
            case .settings: palette.compactTab = 3
            }
        } else {
            switch dest {
            case .matrix: palette.regularSelection = .matrix
            // iPad has no Browse tab: the sidebar is the browse list. Land on its Library section.
            case .browse: palette.regularSelection = .saved
            case .archive: palette.regularSelection = .archive
            case .saved: palette.regularSelection = .saved
            case .dashboard: palette.regularSelection = .dashboard
            case .settings: palette.regularSelection = .settings
            }
        }
    }

    private func openSmartView(_ id: String) {
        if sizeClass == .compact {
            palette.compactTab = 1
            palette.browsePath = [.view(id)]
        } else {
            palette.regularSelection = .smartView(id)
        }
    }

    private func openSavedTask(_ id: String) {
        palette.focusedSavedTaskID = id
        navigate(to: .saved)
    }
}

/// iPad split view. Sidebar selection drives the detail column.
private struct RegularRootView<DashboardAssistant: View>: View {
    let dashboardAssistant: () -> DashboardAssistant
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @Environment(SyncCoordinator.self) private var sync
    @State private var editorTarget: SmartViewEditorTarget?
    @State private var actionFailure: TaskActionFailure?

    var body: some View {
        @Bindable var palette = palette
        NavigationSplitView {
            List(selection: $palette.regularSelection) {
                // The four-pigment mark, not a gray grid symbol: the matrix row is the app.
                sidebarNavLabel(String(localized: "Matrix"), .matrix) {
                    Image("LaunchMark").resizable().scaledToFit().frame(width: 22, height: 22)
                }
                .accessibilityIdentifier("gsd.sidebar.matrix")
                sidebarNavLabel(String(localized: "Dashboard"), .dashboard) {
                    sidebarSymbol("chart.bar.xaxis", .dashboard)
                }
                .accessibilityIdentifier("gsd.sidebar.dashboard")

                Section(String(localized: "Smart Views")) {
                    ForEach(store.pinnedViews) { view in sidebarRow(view) }
                    ForEach(BuiltInSmartViews.all.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        sidebarRow(view)
                    }
                    ForEach(store.customViews.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        sidebarRow(view)
                    }
                    Button { editorTarget = .create } label: {
                        Label(String(localized: "New Smart View"), systemImage: "plus")
                    }
                    .tint(Surface.tint)
                }

                Section(String(localized: "Library")) {
                    sidebarNavLabel(String(localized: "Saved"), .saved) { sidebarSymbol("bookmark", .saved) }
                        .accessibilityIdentifier("gsd.sidebar.saved")
                    sidebarNavLabel(String(localized: "Archive"), .archive) { sidebarSymbol("archivebox", .archive) }
                        .accessibilityIdentifier("gsd.sidebar.archive")
                    sidebarNavLabel(String(localized: "Settings"), .settings) { sidebarSymbol("gearshape", .settings) }
                        .accessibilityIdentifier("gsd.sidebar.settings")
                }
            }
            // No opaque fill: the sidebar is system chrome and takes the system's material
            // (edge to edge on macOS 27), per PRODUCT.md principle 6.
            .navigationTitle("GSD")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { palette.showPalette = true } label: {
                        Label(String(localized: "Search"), systemImage: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SyncStatusChip(phase: sync.phase, pendingCount: sync.pendingCount,
                                   health: sync.health) { palette.regularSelection = .settings }
                }
            }
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0).environment(store) }  // Catalyst re-inject (see above)
            .taskActionFailureAlert($actionFailure)
        } detail: {
            switch palette.regularSelection {
            case .smartView(let id):
                if let view = store.allViews.first(where: { $0.id == id }) {
                    NavigationStack { FilteredTaskListView(view: view) }
                } else {
                    MatrixGridView()
                }
            case .archive:
                NavigationStack { ArchiveListView() }
            case .saved:
                NavigationStack { SavedListView() }
            case .dashboard:
                DashboardView()
                    // Reserve the button's own area so chart values remain reachable.
                    .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                        dashboardAssistant()
                    }
            case .settings:
                SettingsView()
            case .matrix, .none:
                MatrixGridView()
            }
        }
    }

    /// A top-level sidebar destination: an ink label beside the given icon (de-blued chrome).
    private func sidebarNavLabel(_ title: String, _ item: RegularItem,
                                 @ViewBuilder icon: () -> some View) -> some View {
        Label {
            Text(title).foregroundStyle(sidebarInk(item, base: Surface.ink))
        } icon: {
            icon()
        }
        .tag(item)
    }

    /// A graphite SF Symbol for a sidebar row, flipped to the selection's contrasting ink.
    private func sidebarSymbol(_ name: String, _ item: RegularItem) -> some View {
        Image(systemName: name).foregroundStyle(sidebarInk(item, base: Surface.ink2))
    }

    /// iPad uses the root ink tint as an opaque selection fill, so paper is its contrasting
    /// label color in both appearances. Catalyst owns its active/inactive selection colors.
    private func sidebarInk(_ item: RegularItem, base: Color) -> AnyShapeStyle {
        #if targetEnvironment(macCatalyst)
        palette.regularSelection == item ? AnyShapeStyle(.primary) : AnyShapeStyle(base)
        #else
        palette.regularSelection == item ? AnyShapeStyle(Surface.paper) : AnyShapeStyle(base)
        #endif
    }

    @ViewBuilder private func sidebarRow(_ view: SmartView) -> some View {
        SmartViewRow(view: view, selected: palette.regularSelection == .smartView(view.id))
            .tag(RegularItem.smartView(view.id))
            .contextMenu {
                let isPinned = store.pinnedSmartViewIds.contains(view.id)
                Button {
                    if isPinned { store.unpin(view.id) } else { store.pin(view.id) }
                } label: {
                    Label(isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                          systemImage: isPinned ? "pin.slash" : "pin")
                }
                if !view.isBuiltIn {
                    Button { editorTarget = .edit(view) } label: {
                        Label(String(localized: "Edit"), systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        deleteSmartView(view)
                    } label: {
                        Label(String(localized: "Delete"), systemImage: "trash")
                    }
                }
            }
    }

    private func deleteSmartView(_ view: SmartView) {
        _Concurrency.Task { @MainActor in
            do {
                try await store.deleteView(id: view.id)
            } catch {
                actionFailure = TaskActionFailure(String(localized: "Couldn’t delete “\(view.name)”: \(error.localizedDescription)"))
            }
        }
    }
}
