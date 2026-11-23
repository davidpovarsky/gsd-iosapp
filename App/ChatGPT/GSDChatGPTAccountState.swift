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
    @ObservationIgnored private var storageAvailable = true

    init() {
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
        canUsePlan = activeAccount?.credentials?.canUsePlan == true
        selectedModelID = activeAccount?.modelID ?? ""
        accounts = snapshot.accounts.map {
            .init(id: $0.clientID,
                  label: ($0.email ?? String(localized: "ChatGPT account")) + " · " + String($0.clientID.suffix(6)),
                  signedIn: $0.credentials != nil)
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
        defer { isBusy = false }
        let selected = snapshot.accounts.first { $0.clientID == accountID }
        let hostID = snapshot.hostID
        status = String(localized: "Opening secure ChatGPT sign-in…")
        do {
            let (callback, attempt) = try await authorization.authenticate { port in
                try HanlinChatGPTPlanClient.makeAttempt(
                    hostID: hostID, loopbackPort: port, previous: selected?.credentials,
                    appName: "GSD Tasks", clientID: selected?.clientID,
                    idTokenHint: selected?.credentials?.idToken, emailHint: selected?.email,
                    requestPlanConsent: requestPlanConsent)
            }
            status = String(localized: "Verifying ChatGPT identity and permissions…")
            let credential = try await client.exchange(
                callback: callback, attempt: attempt, priorAccount: selected?.credentials)
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
            models = []
            if credential.canUsePlan {
                status = String(localized: "ChatGPT plan permission granted.")
                showPlanWelcome = !(activeAccount?.hasShownPlanWelcome ?? true)
                await loadModels()
            } else {
                status = String(localized: "Signed in to ChatGPT. Plan usage permission has not been granted.")
            }
        } catch GSDChatGPTAuthorizationError.cancelled {
            status = String(localized: "ChatGPT sign-in was cancelled.")
        } catch {
            status = String(format: String(localized: "ChatGPT sign-in failed: %@"), error.localizedDescription)
        }
    }

    func cancelSignIn() { authorization.cancel() }

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
        guard let credential = snapshot.accounts.first(where: { $0.clientID == id })?.credentials else {
            throw HanlinChatGPTPlanError.unavailable
        }
        if let pending = refreshes[id] { return try await pending.value }
        guard credential.expiresAt.timeIntervalSinceNow < 90 else { return credential }
        let epoch = epochs[id] ?? UUID()
        epochs[id] = epoch
        let pending = _Concurrency.Task { @MainActor [weak self, client] in
            let refreshed = try await client.refresh(credential)
            guard let self, self.epochs[id] == epoch,
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
        guard snapshot.activeID == id, credential.canUsePlan else {
            throw HanlinChatGPTPlanError.unavailable
        }
        if models.isEmpty { await loadModels() }
        guard snapshot.activeID == id, !selectedModelID.isEmpty,
              models.contains(where: { $0.slug == selectedModelID }) else {
            throw HanlinChatGPTPlanError.unavailable
        }
        return (credential.accessToken, selectedModelID, credential.clientID)
    }

    func loadModels() async {
        guard let id = snapshot.activeID, canUsePlan else { return }
        do {
            let credential = try await validCredentials(for: id)
            let catalog = try await client.listModels(accessToken: credential.accessToken)
            guard snapshot.activeID == id, activeAccount?.credentials != nil else { return }
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
            status = String(format: String(localized: "ChatGPT model access failed: %@"), error.localizedDescription)
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
