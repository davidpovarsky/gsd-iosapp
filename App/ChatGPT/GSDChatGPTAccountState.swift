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
    @ObservationIgnored private let client = HanlinChatGPTPlanClient()
    @ObservationIgnored private let authorization = GSDChatGPTAuthorization()
    @ObservationIgnored private var refreshes: [String: _Concurrency.Task<HanlinChatGPTPlanCredentials, Error>] = [:]
    @ObservationIgnored private var epochs: [String: UUID] = [:]
    @ObservationIgnored private var locallySignedOut: Set<String> = []
    @ObservationIgnored private var storageAvailable = true
    @ObservationIgnored private var signInOperationID: UUID?

    private init() {
        do {
            if let saved = try GSDChatGPTKeychain.load() {
                snapshot = saved
            } else {
                try GSDChatGPTKeychain.save(snapshot)
            }
            publish()
        } catch {
            storageAvailable = false
            status = String(localized: "The device Keychain is unavailable. Unlock the device and reopen this screen.")
        }
    }

    private var activeAccount: GSDChatGPTRegistration? {
        snapshot.accounts.first { $0.clientID == snapshot.activeID }
    }

    private func publish() {
        activeID = snapshot.activeID
        email = activeAccount?.email
        canUsePlan = activeAccount?.credentials?.canUsePlan == true &&
            !locallySignedOut.contains(snapshot.activeID ?? "")
        selectedModelID = activeAccount?.modelID ?? ""
        accounts = snapshot.accounts.map {
            .init(id: $0.clientID,
                  label: ($0.email ?? String(localized: "ChatGPT account")) + " · " + String($0.clientID.suffix(6)),
                  signedIn: $0.credentials != nil && !locallySignedOut.contains($0.clientID))
        }
    }

    private func persist(_ next: GSDChatGPTSnapshot) throws {
        try GSDChatGPTKeychain.save(next)
        snapshot = next
        publish()
    }

    func signIn(accountID: String? = nil, requestPlanConsent: Bool = false) async {
        guard !isBusy, storageAvailable else { return }
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
            try persist(next)
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
        let credential = try await validCredentials(for: id)
        guard !isBusy, snapshot.activeID == id, credential.canUsePlan else {
            throw HanlinChatGPTPlanError.unavailable
        }
        if models.isEmpty { await loadModels() }
        guard !isBusy, snapshot.activeID == id, !selectedModelID.isEmpty,
              models.contains(where: { $0.slug == selectedModelID }) else {
            throw HanlinChatGPTPlanError.unavailable
        }
        return (credential.accessToken, selectedModelID, credential.clientID)
    }

    func loadModels() async {
        guard !isBusy else { return }
        await loadModelsForActiveAccount()
    }

    private func loadModelsForActiveAccount() async {
        guard let id = snapshot.activeID, canUsePlan else { return }
        do {
            let credential = try await validCredentials(for: id)
            let catalog = try await client.listModels(accessToken: credential.accessToken)
            guard snapshot.activeID == id, activeAccount?.credentials != nil,
                  !locallySignedOut.contains(id) else { return }
            models = catalog
            if !catalog.contains(where: { $0.slug == selectedModelID }), let first = catalog.first {
                selectModel(first.slug)
            }
            status = catalog.isEmpty
                ? String(localized: "This ChatGPT account has no available models for this app.")
                : String(localized: "ChatGPT models are ready.")
        } catch {
            guard snapshot.activeID == id else { return }
            models = []
            status = String(format: String(localized: "ChatGPT model access failed: %@"), GSDChatGPTCopy.error(error))
        }
    }

    func signOut() async {
        guard !isBusy, let id = snapshot.activeID else { return }
        isBusy = true
        defer { isBusy = false }
        if let pending = refreshes[id] {
            do { _ = try await pending.value }
            catch { status = String(localized: "The ChatGPT session could not be refreshed before sign-out.") }
        }
        epochs[id] = UUID()
        refreshes[id]?.cancel(); refreshes[id] = nil
        locallySignedOut.insert(id)
        models = []
        publish()
        guard let index = snapshot.accounts.firstIndex(where: { $0.clientID == id }) else { return }
        let credential = snapshot.accounts[index].credentials
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
        do {
            var next = snapshot
            next.accounts[index].credentials = nil
            try persist(next)
            models = []
            status = revoked
                ? String(localized: "Signed out of ChatGPT in GSD.")
                : String(localized: "Signed out on this device. Remote revocation was not confirmed; disconnect GSD in ChatGPT settings.")
        } catch {
            canUsePlan = false
            status = String(localized: "The device Keychain could not clear the ChatGPT credentials. Unlock the device and try signing out again.")
        }
    }
}
