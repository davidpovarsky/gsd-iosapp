import Foundation
import HanlinChatCore
import Observation

struct GSDChatGPTAccountLabel: Identifiable {
    let id: String
    let label: String
    let signedIn: Bool
}

@MainActor @Observable
final class GSDChatGPTAccountState {
    static let shared = GSDChatGPTAccountState()
    private(set) var accounts: [GSDChatGPTAccountLabel] = []
    private(set) var activeID: String?
    private(set) var email: String?
    private(set) var canUsePlan = false
    private(set) var isBusy = false
    private(set) var models: [HanlinChatGPTPlanModel] = []
    private(set) var selectedModelID = ""
    private(set) var status = String(localized: "Continue with ChatGPT to use your plan for eligible AI requests.")
    var showPlanWelcome = false

    @ObservationIgnored private var snapshot = GSDChatGPTSnapshot.empty()
    @ObservationIgnored private let client: HanlinChatGPTPlanClient
    @ObservationIgnored private let loadSnapshot: @MainActor () throws -> GSDChatGPTSnapshot?
    @ObservationIgnored private let saveSnapshot: @MainActor (GSDChatGPTSnapshot) throws -> Void
    @ObservationIgnored private let localSignOutStore: GSDChatGPTLocalSignOutStore
    @ObservationIgnored private let authorization = GSDChatGPTAuthorization()
    @ObservationIgnored private var refreshes: [String: _Concurrency.Task<HanlinChatGPTPlanCredentials, Error>] = [:]
    @ObservationIgnored private var epochs: [String: UUID] = [:]
    @ObservationIgnored private var locallySignedOut: Set<String> = []
    @ObservationIgnored private var storageAvailable = true
    @ObservationIgnored private var signInOperationID: UUID?

    private convenience init() {
        self.init(client: HanlinChatGPTPlanClient(),
                  loadSnapshot: GSDChatGPTKeychain.load,
                  saveSnapshot: GSDChatGPTKeychain.save,
                  localSignOutStore: GSDChatGPTLocalSignOutStore())
    }

    /// App lifecycle acceptance injects storage and a URLSession-backed SDK client.
    /// The shared live instance always uses the device Keychain and original SDK.
    init(client: HanlinChatGPTPlanClient,
         loadSnapshot: @escaping @MainActor () throws -> GSDChatGPTSnapshot?,
         saveSnapshot: @escaping @MainActor (GSDChatGPTSnapshot) throws -> Void,
         localSignOutStore: GSDChatGPTLocalSignOutStore) {
        self.client = client
        self.loadSnapshot = loadSnapshot
        self.saveSnapshot = saveSnapshot
        self.localSignOutStore = localSignOutStore
        _ = reloadStoredState()
    }

    /// A screen reopen or explicit sign-in may retry a transient Keychain lock once.
    /// Reloading never grants access to a registration with a local sign-out fence.
    @discardableResult
    private func reloadStoredState() -> Bool {
        do {
            let denied = try localSignOutStore.deniedRegistrationHashes()
            let restored: GSDChatGPTSnapshot
            if let saved = try loadSnapshot() {
                restored = saved
            } else {
                restored = .empty()
                try saveSnapshot(restored)
            }
            snapshot = restored
            locallySignedOut.formUnion(restored.accounts.compactMap { account in
                denied.contains(GSDChatGPTLocalSignOutStore.registrationHash(account.clientID))
                    ? account.clientID : nil
            })
            storageAvailable = true
            models = []
            publish()
            if activeID == nil {
                status = String(localized: "Continue with ChatGPT to use your plan for eligible AI requests.")
            } else if activeAccount?.credentials == nil || locallySignedOut.contains(activeID ?? "") {
                status = String(localized: "Sign in again to use this ChatGPT account.")
            } else {
                status = canUsePlan
                    ? String(localized: "ChatGPT account selected.")
                    : String(localized: "Signed in to ChatGPT. Plan usage permission has not been granted.")
            }
            return true
        } catch {
            storageAvailable = false
            models = []
            publish()
            status = String(localized: "The saved ChatGPT account state could not be read. Unlock the device and try again.")
            return false
        }
    }

    private var activeAccount: GSDChatGPTRegistration? {
        snapshot.accounts.first { $0.clientID == snapshot.activeID }
    }

    private func publish() {
        activeID = snapshot.activeID
        email = activeAccount?.email
        canUsePlan = storageAvailable && activeAccount?.credentials?.canUsePlan == true &&
            !locallySignedOut.contains(snapshot.activeID ?? "")
        selectedModelID = activeAccount?.modelID ?? ""
        accounts = snapshot.accounts.map {
            .init(id: $0.clientID,
                  label: ($0.email ?? String(localized: "ChatGPT account")) + " · " + String($0.clientID.suffix(6)),
                  signedIn: storageAvailable && $0.credentials != nil && !locallySignedOut.contains($0.clientID))
        }
    }

    private func persist(_ next: GSDChatGPTSnapshot) throws {
        try saveSnapshot(next)
        snapshot = next
        publish()
    }

    func signIn(accountID: String? = nil, requestPlanConsent: Bool = false) async {
        guard !isBusy else { return }
        if !storageAvailable, !reloadStoredState() { return }
        isBusy = true
        let operationID = UUID()
        signInOperationID = operationID
        defer {
            if signInOperationID == operationID { signInOperationID = nil }
            isBusy = false
        }
        if let accountID, let pending = refreshes[accountID] {
            _ = try? await pending.value
            refreshes[accountID] = nil
        }
        if let accountID { epochs[accountID] = UUID() }
        let selected = snapshot.accounts.first { $0.clientID == accountID }
        let hostID = snapshot.hostID
        status = String(localized: "Opening secure ChatGPT sign-in…")
        do {
            guard signInOperationID == operationID else { throw GSDChatGPTAuthorizationError.cancelled }
            let (callback, attempt) = try await authorization.authenticate { port in
                try HanlinChatGPTPlanClient.makeAttempt(
                    hostID: hostID, loopbackPort: port, previous: selected?.credentials,
                    appName: "GSD Tasks", clientID: selected?.clientID,
                    idTokenHint: selected?.credentials?.idToken, emailHint: selected?.email,
                    requestPlanConsent: requestPlanConsent)
            }
            guard signInOperationID == operationID else { throw GSDChatGPTAuthorizationError.cancelled }
            status = String(localized: "Verifying ChatGPT identity and permissions…")
            let credential = try await client.exchange(
                callback: callback, attempt: attempt, priorAccount: selected?.credentials)
            guard signInOperationID == operationID else {
                try? await client.revoke(credential)
                throw GSDChatGPTAuthorizationError.cancelled
            }
            if let selected {
                guard credential.clientID == selected.clientID,
                      credential.subject == selected.subject else {
                    throw HanlinChatGPTPlanError.invalidIdentity
                }
            }
            var next = snapshot
            if let index = next.accounts.firstIndex(where: { $0.clientID == credential.clientID }) {
                guard next.accounts[index].subject == credential.subject else {
                    throw HanlinChatGPTPlanError.invalidIdentity
                }
                next.accounts[index].credentials = credential
            } else {
                next.accounts.append(.init(credentials: credential))
            }
            next.activeID = credential.clientID
            // A verified interactive sign-in is the only operation that removes this fence.
            // Publish eligibility only after both credential persistence and fence removal succeed.
            try saveSnapshot(next)
            try localSignOutStore.clearAfterSignIn(credential.clientID)
            snapshot = next
            signInOperationID = nil
            locallySignedOut.remove(credential.clientID)
            publish()
            models = []
            if credential.canUsePlan {
                status = String(localized: "ChatGPT plan permission granted.")
                showPlanWelcome = !(activeAccount?.hasShownPlanWelcome ?? true)
                await loadModelsForActiveAccount()
            } else {
                status = String(localized: "Signed in to ChatGPT. Plan usage permission has not been granted.")
            }
        } catch GSDChatGPTAuthorizationError.cancelled {
            status = String(localized: "ChatGPT sign-in was cancelled.")
        } catch {
            status = String(format: String(localized: "ChatGPT sign-in failed: %@"), GSDChatGPTCopy.error(error))
        }
    }

    func cancelSignIn() {
        signInOperationID = nil
        authorization.cancel()
    }

    func selectAccount(_ id: String) {
        guard !isBusy, snapshot.accounts.contains(where: { $0.clientID == id }) else { return }
        do {
            var next = snapshot
            next.activeID = id
            try persist(next)
            models = []
            status = activeAccount?.credentials == nil
                ? String(localized: "Sign in again to use this ChatGPT account.")
                : String(localized: "ChatGPT account selected.")
        } catch {
            status = String(localized: "The device Keychain could not save the selected account.")
        }
    }

    func selectModel(_ modelID: String) {
        guard models.contains(where: { $0.slug == modelID }), let id = snapshot.activeID,
              let index = snapshot.accounts.firstIndex(where: { $0.clientID == id }) else { return }
        do {
            var next = snapshot
            next.accounts[index].modelID = modelID
            try persist(next)
        } catch {
            status = String(localized: "The device Keychain could not save the selected model.")
        }
    }

    func acknowledgePlanWelcome() {
        showPlanWelcome = false
        guard let id = snapshot.activeID,
              let index = snapshot.accounts.firstIndex(where: { $0.clientID == id }) else { return }
        do {
            var next = snapshot
            next.accounts[index].hasShownPlanWelcome = true
            try persist(next)
        } catch {
            status = String(localized: "The device Keychain could not save this preference.")
        }
    }

    /// One rotation, including its durable Keychain write, is shared by all
    /// callers for this registration. A sign-out epoch cannot be resurrected.
    private func validCredentials(for id: String) async throws -> HanlinChatGPTPlanCredentials {
        guard storageAvailable, !locallySignedOut.contains(id),
              let credential = snapshot.accounts.first(where: { $0.clientID == id })?.credentials else {
            throw HanlinChatGPTPlanError.unavailable
        }
        if let pending = refreshes[id] { return try await pending.value }
        guard credential.expiresAt.timeIntervalSinceNow < 60 else { return credential }
        if let earliest = credential.earliestRefreshAt, earliest > Date() {
            guard credential.expiresAt.timeIntervalSinceNow > 5 else {
                throw GSDChatGPTSessionError.refreshNotYetPermitted
            }
            return credential
        }
        let epoch = epochs[id] ?? UUID()
        epochs[id] = epoch
        let pending = _Concurrency.Task { @MainActor [weak self, client] in
            let refreshed: HanlinChatGPTPlanCredentials
            do { refreshed = try await client.refresh(credential) }
            catch HanlinChatGPTPlanError.oauth(_, let code, _) where
                code == "near_expiry" && credential.expiresAt.timeIntervalSinceNow > 5 {
                guard let self, self.epochs[id] == epoch,
                      !self.locallySignedOut.contains(id),
                      self.snapshot.accounts.first(where: { $0.clientID == id })?.credentials != nil else {
                    throw CancellationError()
                }
                return credential
            }
            guard let self, self.epochs[id] == epoch,
                  !self.locallySignedOut.contains(id),
                  let index = self.snapshot.accounts.firstIndex(where: { $0.clientID == id }),
                  self.snapshot.accounts[index].credentials != nil else { throw CancellationError() }
            var next = self.snapshot
            next.accounts[index].credentials = refreshed
            try self.persist(next)
            return refreshed
        }
        refreshes[id] = pending
        defer { if epochs[id] == epoch { refreshes[id] = nil } }
        return try await pending.value
    }

    func accessForInference() async throws -> (token: String, modelID: String, accountID: String) {
        guard !isBusy, let id = snapshot.activeID else { throw HanlinChatGPTPlanError.unavailable }
        let epoch = epochs[id] ?? UUID()
        epochs[id] = epoch
        let credential = try await validCredentials(for: id)
        guard epochs[id] == epoch, !isBusy, storageAvailable, snapshot.activeID == id, canUsePlan,
              !locallySignedOut.contains(id), credential.canUsePlan else {
            throw HanlinChatGPTPlanError.unavailable
        }
        if models.isEmpty { await loadModels() }
        guard epochs[id] == epoch, !isBusy, storageAvailable, snapshot.activeID == id, canUsePlan,
              !locallySignedOut.contains(id), !selectedModelID.isEmpty,
              models.contains(where: { $0.slug == selectedModelID }) else {
            throw HanlinChatGPTPlanError.unavailable
        }
        return (credential.accessToken, selectedModelID, credential.clientID)
    }

    func loadModels() async {
        guard !isBusy else { return }
        if !storageAvailable, !reloadStoredState() { return }
        await loadModelsForActiveAccount()
    }

    private func loadModelsForActiveAccount() async {
        guard let id = snapshot.activeID, canUsePlan else { return }
        let epoch = epochs[id] ?? UUID()
        epochs[id] = epoch
        do {
            let credential = try await validCredentials(for: id)
            guard epochs[id] == epoch, snapshot.activeID == id, canUsePlan,
                  !locallySignedOut.contains(id) else { return }
            let catalog = try await client.listModels(accessToken: credential.accessToken)
            // Authentication may have replaced this registration while the request was in flight.
            guard epochs[id] == epoch, snapshot.activeID == id, canUsePlan,
                  activeAccount?.credentials != nil,
                  !locallySignedOut.contains(id) else { return }
            models = catalog
            if !catalog.contains(where: { $0.slug == selectedModelID }), let first = catalog.first {
                selectModel(first.slug)
            }
            status = catalog.isEmpty
                ? String(localized: "This ChatGPT account has no available models for this app.")
                : String(localized: "ChatGPT models are ready.")
        } catch {
            guard epochs[id] == epoch, snapshot.activeID == id, canUsePlan,
                  activeAccount?.credentials != nil,
                  !locallySignedOut.contains(id) else { return }
            models = []
            status = String(format: String(localized: "ChatGPT model access failed: %@"), GSDChatGPTCopy.error(error))
        }
    }

    func signOut() async {
        guard !isBusy, let id = snapshot.activeID,
              let index = snapshot.accounts.firstIndex(where: { $0.clientID == id }) else { return }
        isBusy = true
        defer { isBusy = false }
        let credential = snapshot.accounts[index].credentials
        let pending = refreshes.removeValue(forKey: id)
        // Revoke in-memory authority immediately, before waiting on any network operation.
        epochs[id] = UUID()
        pending?.cancel()
        locallySignedOut.insert(id)
        models = []
        showPlanWelcome = false
        publish()

        var fenced = false
        do { try localSignOutStore.markSignedOut(id); fenced = true } catch {}
        var cleared = false
        do {
            var next = snapshot
            next.accounts[index].credentials = nil
            try persist(next)
            cleared = true
        } catch {}
        guard fenced || cleared else {
            // Neither store committed the denial. Keep this process disabled and report failure.
            status = String(localized: "The device could not save the ChatGPT sign-out. Please try again.")
            return
        }
        // A rotating SDK refresh may still finish. Its old app epoch cannot persist or return it;
        // the SDK's revoke operation follows the rotated token from the captured credential.
        if let pending { _ = await pending.result }
        var revoked = credential == nil
        if let credential {
            for attempt in 0..<2 {
                do { try await client.revoke(credential); revoked = true; break }
                catch {
                    if attempt == 0 {
                        do { try await _Concurrency.Task.sleep(for: .milliseconds(500)) }
                        catch { break }
                    }
                }
            }
        }
        if cleared {
            status = revoked
                ? String(localized: "Signed out of ChatGPT in GSD.")
                : String(localized: "Signed out on this device. Remote revocation was not confirmed; disconnect GSD in ChatGPT settings.")
        } else {
            status = String(localized: "The device Keychain could not clear the ChatGPT credentials. Unlock the device and try signing out again.")
        }
    }
}
