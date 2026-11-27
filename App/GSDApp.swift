import AppIntents
import SwiftUI
import UIKit
import GSDModel
import GSDStore
import GSDSync
import GSDSnapshot
import GSDWire

@main
struct GSDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: TaskStore
    @State private var session: SessionStore
    @State private var syncEngine: SyncEngine
    @State private var coordinator: SyncCoordinator
    @State private var widgetRefresher: WidgetSnapshotRefresher
    @State private var reminderResyncer: ReminderResyncer
    @State private var watchSession: WatchSessionCoordinator
    @State private var spotlightIndexer: SpotlightIndexer
    @State private var shareDrainer: ShareInboxDrainer
    private let shareScopePublisher: ShareScopePublisher
    /// True when the local database couldn't be opened even after recovery — the app shows a
    /// recovery screen instead of the main UI (so no edits hit a throwaway store).
    @State private var databaseUnavailable: Bool
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("layoutDirectionPreference", store: .shared) private var direction = "system"
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false
    /// Frozen clock for the demo-video harness; `nil` in every normal launch.
    private let demoClock: Date?

    init() {
        // Editorial chrome: serif nav titles + ink (not system-blue) bars. Must run before
        // any UINavigationBar/UITabBar is realized, so the App init is the right window.
        AppAppearance.configure()
        // Demo-video harness: a fixed clock makes seeded data + relative dates deterministic
        // across takes. `nil` in normal launches, so production keeps the live system clock.
        let demoClock = DemoLaunch.clock
        self.demoClock = demoClock
        let now: @Sendable () -> Date = { demoClock ?? Date() }
        // The local store is the app's source of truth. `liveWithRecovery` moves aside an
        // unopenable store (corruption, failed migration) — preserved as .corrupt, never deleted —
        // and recreates it, instead of crash-looping at launch. If recovery ITSELF fails (an
        // unwritable/full container, a busy-lock at launch), fall back to a throwaway in-memory
        // store so the app launches into a recovery screen rather than crashing; the on-disk data
        // is untouched and a relaunch retries. (A fresh in-memory open has no file I/O; only a
        // broken migration could fail it, which the test suite catches before shipping.)
        // A harness launch (any --demo- argument) never touches what the real app owns. A
        // dev-signed Catalyst build shares the App Group container, the keychain session, the
        // notification center, Spotlight, and the widget snapshot with the installed app, and on
        // 2026-10-24 the seed trashed the owner's 166 real tasks and pushed their deletes to the
        // server. Isolated: in-memory store, signed out, a defaults suite that starts empty
        // (AppGroupDefaults.shared resolves it), no reminders, no Spotlight, and the share outbox
        // and widget snapshot in a scratch folder. The onboarding flag is set in that suite so the
        // harness never meets the onboarding cover.
        let isolated = HarnessLaunch.isIsolated
        if isolated { AppGroupDefaults.shared.set(true, forKey: "hasOnboarded") }
        let database: AppDatabase
        let databaseUnavailable: Bool
        do {
            database = try (isolated ? AppDatabase.inMemory() : AppDatabase.liveWithRecovery())
            databaseUnavailable = false
        } catch {
            database = try! AppDatabase.inMemory()
            databaseUnavailable = true
        }
        _databaseUnavailable = State(initialValue: databaseUnavailable)
        // The live scheduler reads NotificationSettings straight from App-Group defaults
        // (the same suite the store persists to) — avoids a store-construction cycle.
        let scheduler: any ReminderScheduling
        let liveScheduler: LiveReminderScheduler?
        if isolated {
            scheduler = NoopReminderScheduler()
            liveScheduler = nil
        } else {
            let live = LiveReminderScheduler(settingsProvider: { TaskStore.readNotificationSettings(from: .shared) })
            scheduler = live
            liveScheduler = live
        }
        // The test/demo harness owns a scratch identity, never the real app-group dataset.
        let sharedDirectory = isolated ? HarnessLaunch.scratchDirectory
            : FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
        let watchMutationGate = WatchMutationGate(directory: sharedDirectory)
        // Repos shared by the store and the sync engine (Phase 5c): pulled writes reach the store's
        // observer, and the store's enqueues reach the engine's drain — same GRDB instances.
        let taskRepo = GRDBTaskRepository(database, now: now)
        let queueRepo = GRDBSyncQueueRepository(database)
        let historyRepo = GRDBSyncHistoryRepository(database)
        let store = TaskStore(
            repository: taskRepo,
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database, now: now),
            trashRepository: GRDBTrashRepository(database, now: now),
            clock: now,
            reminders: scheduler,
            syncQueue: queueRepo
        )
        _store = State(initialValue: store)
        // Auth + transport (Phase 5b). Live seams; the pure AuthService logic is unit-tested.
        let tokenStore: any TokenStore = isolated ? SignedOutTokenStore() : KeychainTokenStore()
        let authService = AuthService(
            client: PocketBaseClient(baseURL: AuthConfig.live.baseURL),
            presenter: LiveWebAuthPresenter(),
            tokenStore: tokenStore,
            config: .live)
        // Sync engine (Phase 5c). Writes the shared repos directly; tokenProvider proxies to
        // AuthService.validToken (nil ⇒ no-op). deviceName read here on the main-actor init.
        let deviceName = UIDevice.current.name
        let syncEngine = SyncEngine(
            client: PocketBaseClient(baseURL: AuthConfig.live.baseURL),
            tasks: taskRepo, queue: queueRepo,
            tombstones: GRDBTombstoneRepository(database),   // archive + trash block stale remote copies
            cursor: SyncCursor(),
            deviceId: DeviceIdentity.current(nameProvider: { deviceName }).deviceId,
            tokenProvider: { try await authService.validToken() },
            rawToken: { tokenStore.load() },   // health-only: lets an expired session say so
            history: historyRepo,
            reminders: scheduler,
            library: GRDBCloudLibraryRepository(database)) // same account and sync lifecycle
        _syncEngine = State(initialValue: syncEngine)
        // SyncCoordinator (Phase 5d) owns when sync fires (cadence/foreground/network/debounced push/SSE)
        // and the status surface; SessionStore delegates start/stop to it on sign-in/out.
        let realtime = PocketBaseRealtime(baseURL: AuthConfig.live.baseURL)
        let coordinator = SyncCoordinator(
            engine: syncEngine, realtime: realtime, watchMutationGate: watchMutationGate,
            tokenProvider: { try? await authService.validToken() },
            signedIn: { tokenStore.load() != nil })
        _coordinator = State(initialValue: coordinator)
        store.onMutation = { coordinator.scheduleDebouncedPush() }
        // Auto-archive deletes each archived task's server copy (parity B-43). Signed in, it runs
        // only after a sync has pulled, so it never archives a stale local copy of a task that was
        // reopened elsewhere. The launch task and BackgroundRefresh sweep directly only when signed out.
        coordinator.afterCleanSync = { _ = try? await store.runAutoArchiveSweep() }
        // Widget snapshot refresher (Phase 6a): rebuilds the App-Group snapshot + reloads
        // widget timelines whenever the task set changes (local edits, remote sync, background).
        let widgetRefresher = WidgetSnapshotRefresher(
            store: store,
            snapshotStore: isolated ? WidgetSnapshotStore(containerURL: HarnessLaunch.scratchDirectory)
                                    : WidgetSnapshotStore())
        _widgetRefresher = State(initialValue: widgetRefresher)
        // Reminder resync (Fix A): remote writes (pull/SSE/reconcile) bypass the §9.1 mutation
        // hooks; this rebuilds reminders+badge from the snapshot on every observed change.
        let reminderResyncer = ReminderResyncer(store: store)
        _reminderResyncer = State(initialValue: reminderResyncer)
        let session = SessionStore(
            auth: authService, tokenStore: tokenStore, coordinator: coordinator,
            hasLocalActiveTasks: { (try? await store.hasCloudAccountData()) ?? true },
            eraseLocal: {
                try await watchMutationGate.replacingDataset {
                    try await store.eraseAllData()
                    try await GRDBCloudLibraryRepository(database).resetMetadata()
                }
            })
        _session = State(initialValue: session)
        // Canonical SessionStore phases fence unresolved transitions. Rechecking the token owner
        // also closes the short interval before a Keychain-change notification reaches MainActor.
        let watchScopeProvider: @MainActor @Sendable () -> WatchAccountScope? = {
            guard !watchMutationGate.isPaused, let identity = watchMutationGate.identity,
                  !session.inProgress, session.pendingAccountSwitch == nil else { return nil }
            if session.isSignedIn {
                guard let owner = session.currentUserID, owner == authService.currentUserId() else { return nil }
                return .account(userID: owner, datasetID: identity.datasetID)
            }
            guard session.currentUserID == nil, tokenStore.load() == nil else { return nil }
            return .guest(installationID: identity.installationID, datasetID: identity.datasetID)
        }
        shareScopePublisher = ShareScopePublisher(directory: sharedDirectory, scopeProvider: watchScopeProvider)
        liveScheduler?.configureScope(store: store, mutationGate: watchMutationGate,
                                      scopeProvider: watchScopeProvider)
        ReminderActionInbox.attach(store: store, mutationGate: watchMutationGate,
                                   scopeProvider: watchScopeProvider)
        // Apple Watch link (W2): sends the watch snapshot and applies its queued commands. A no-op
        // in the harness and wherever WatchConnectivity is unsupported (Mac Catalyst).
        let watchSession = WatchSessionCoordinator(
            store: store, enabled: !isolated, mutationGate: watchMutationGate,
            scopeProvider: watchScopeProvider,
            scopeDidChange: {
                if store.hasLoadedTasks, watchScopeProvider() != nil { reminderResyncer.schedule() }
            })
        _watchSession = State(initialValue: watchSession)
        let spotlightIndexer = SpotlightIndexer()
        _spotlightIndexer = State(initialValue: spotlightIndexer)
        store.onTasksChanged = {
            widgetRefresher.schedule()
            reminderResyncer.schedule()
            watchSession.schedule()
            if !isolated { spotlightIndexer.schedule(tasks: store.tasks) }   // Spotlight is the real app's
        }
        // Share Extension inbox (Phase 6d): drains the App-Group outbox on launch, foreground, the
        // Darwin signal, and background refresh — all through ShareInboxDrainer so the landings
        // never diverge. Trivial glue; the logic is the tested ShareInbox + TaskStore.
        let fetcher = PageTitleFetcher()
        let shareDrainer = ShareInboxDrainer(
            inbox: ShareInbox(store: isolated ? ShareOutboxStore(directoryURL: HarnessLaunch.scratchDirectory)
                                              : ShareOutboxStore()),
            store: store,
            titleEnricher: ShareTitleEnricher(store: store, fetch: fetcher.title,
                                            mutationGate: watchMutationGate, scopeProvider: watchScopeProvider),
            mutationGate: watchMutationGate, scopeProvider: watchScopeProvider,
            sharedDirectory: sharedDirectory, recoverJournals: true)
        _shareDrainer = State(initialValue: shareDrainer)
        // In-app intents (Siri/Shortcuts run in this process) resolve the SAME store via
        // AppDependencyManager. A second connection on the live DB would be invisible to
        // this one's ValueObservation (stale UI/widgets/reminders) and racing the open
        // mid-write risks SQLITE_BUSY. Registered in init(): background intent launches
        // run App.init before any perform().
        AppDependencyManager.shared.add(dependency: store)
        let intentScope = GSDAppIntentScope(store: store, mutationGate: watchMutationGate,
                                           scopeProvider: watchScopeProvider)
        AppDependencyManager.shared.add(dependency: intentScope)
        // Re-register the App Shortcut phrases with Siri on every launch. Install-time
        // extraction alone has proven unreliable on Mac Catalyst (Siri: "I don't see an
        // app for that"), and Apple's guidance is to call this whenever phrases change.
        GSDShortcuts.updateAppShortcutParameters()
        // BGTaskScheduler handlers MUST be registered before the app finishes launching —
        // `init()` (pre-launch) is the correct window; a view's `.task` runs after launch
        // and would trip "all launch handlers must be registered before application finishes
        // launching". `App.init()` is main-actor-isolated, so the @MainActor register is safe.
        BackgroundRefresh.register(
            store: store,
            signedIn: { coordinator.isSignedIn },
            // Same landings as the launch/foreground drains below, minus title enrichment:
            // that fetch is fire-and-forget and the window closes (database re-suspended) before
            // it would land, so the URL-derived title stands until the user edits it.
            drainShareInbox: { await shareDrainer.drain(enrichTitles: false) },
            sync: { await coordinator.backgroundSync() })
    }

    var body: some Scene {
        WindowGroup {
            // The local store couldn't be opened even after recovery — show a calm recovery screen
            // instead of the main UI (and never start sync/observation against the fallback store).
            if databaseUnavailable {
                DatabaseUnavailableView()
            // Demo-only: the marketing-video choreography launches with --demo-home to record the
            // faux Home Screen widget beat. The app itself never passes it, so this stays unreachable.
            } else if ProcessInfo.processInfo.arguments.contains(DemoHomeScreen.launchArgument) {
                DemoHomeScreen()
            } else {
            ContentView()
                .environment(shareDrainer)
                .environment(store)
                .environment(session)
                .environment(coordinator)
                .demoClock(demoClock)   // freezes relative-date rendering in the demo harness; no-op otherwise
                .preferredColorScheme(DemoLaunch.appearance ?? AppTheme(rawValue: themeRaw)?.colorScheme)
                .tint(Surface.ink) // quiet graphite chrome; genuine actions opt into Surface.tint
                .task {
                    store.start()
                    await DemoSeed.seedIfRequested(store, now: demoClock ?? .now)
                    await shareDrainer.drain()
                    // Drain the instant a share lands while the app is already running. On Mac
                    // Catalyst the extension never foregrounds the app and scenePhase `.active`
                    // is unreliable, so the launch/foreground drains alone leave captures stranded.
                    ShareOutboxSignal.observe {
                        _Concurrency.Task { await shareDrainer.drain() }
                    }
                    widgetRefresher.start()
                    watchSession.start()
                    // Signed in, the sweep waits for the launch sync below to pull (afterCleanSync).
                    if !coordinator.isSignedIn { try? await store.runAutoArchiveSweep() }
                    _ = try? await store.runTrashRetentionSweep()
                    await store.refreshBadge()
                    coordinator.start(trigger: .launch)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        BackgroundDatabaseWindow.resumeAppDatabaseForForeground() // before foreground sync
                        session.enteredForeground()
                        coordinator.enteredForeground()
                        _Concurrency.Task { await store.refreshBadge() }
                        _Concurrency.Task { await shareDrainer.drain() }
                        // Reminders that fired while the app was closed free slots under the
                        // 60-reminder cap, and a resync otherwise runs only on task changes.
                        // Skipped before the first snapshot: the launch emission does that sweep,
                        // and sweeping an empty snapshot would wipe live reminders.
                        if store.hasLoadedTasks { reminderResyncer.schedule() }
                    case .background:
                        coordinator.enteredBackground()
                        BackgroundRefresh.schedule()
                        // 0xDEAD10CC is an iOS jetsam kill with no macOS equivalent, and Catalyst
                        // scenePhase is unreliable (see project memory) — a spurious `.background`
                        // here would suspend the DB under a still-live window and any Siri intent.
                        #if !targetEnvironment(macCatalyst)
                        BackgroundDatabaseWindow.suspendAppDatabaseWhenIdle() // active owners release on exit/expiry
                        #endif
                    default:
                        break
                    }
                }
                .fullScreenCover(isPresented: Binding(
                    get: { !hasOnboarded },
                    set: { presenting in if !presenting { hasOnboarded = true } }
                )) {
                    OnboardingView(
                        onFinish: { hasOnboarded = true },
                        onGoogleSignIn: {
                            hasOnboarded = true
                            _Concurrency.Task { await session.signIn(provider: "google") }
                        },
                        onAppleSignIn: {
                            hasOnboarded = true
                            _Concurrency.Task { await session.signIn(provider: "apple") }
                        }
                    )
                    // The cover needs the app-owned session outside ContentView's modifiers.
                    .environment(session)
                }
                .transformEnvironment(\.layoutDirection) { inherited in
                    switch direction {
                    case "rtl": inherited = .rightToLeft
                    case "ltr": inherited = .leftToRight
                    default: break
                    }
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .commands { GSDMenuCommands() }
        #endif
    }
}
