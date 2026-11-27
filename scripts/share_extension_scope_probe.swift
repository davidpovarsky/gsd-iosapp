import Foundation
import Security
import Synchronization
import Observation
import GSDModel
import GSDSnapshot

struct FixtureKeychainResult: Sendable {
    var status: OSStatus = errSecItemNotFound
    var data: Data?
}
let fixtureKeychain = Mutex(FixtureKeychainResult())
func fixtureSecItemCopyMatching(_ query: CFDictionary,
                                _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    let snapshot = fixtureKeychain.withLock { $0 }
    result?.pointee = snapshot.data.map { $0 as NSData }
    return snapshot.status
}
enum FixtureCredential: Equatable {
    case account(token: String, owner: String)
    case signedOut
    case unavailable
}
func readFixtureCredential() -> FixtureCredential {
    #if SHARE_SCOPE_PRESENT
    return switch SharedTokenKeychain.snapshot() {
    case .token(let token, let owner): .account(token: token, owner: owner)
    case .missing: .signedOut
    case .unavailable: .unavailable
    }
    #else
    if let token = SharedTokenKeychain.load(), let owner = JWT.userId(token) {
        return .account(token: token, owner: owner)
    }
    return .signedOut
    #endif
}
@MainActor final class PushRecorder {
    struct Post { let task: GSDModel.Task; let token: String }
    private(set) var posts: [Post] = []
    var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func push(_ task: GSDModel.Task, token: String) async -> String? {
        posts.append(Post(task: task, token: token))
        if hold { await withCheckedContinuation { continuation = $0 } }
        return "record-" + String(posts.count)
    }
    func release() { hold = false; continuation?.resume(); continuation = nil }
}
// Only HTTP is doubled. The legacy controller's complete save method is copied unchanged.
@MainActor final class DirectTaskPush {
    enum Outcome { case pushed(String), failed(String) }
    let recorder: PushRecorder
    init(recorder: PushRecorder) { self.recorder = recorder }
    func attempt(_ task: GSDModel.Task) async -> Outcome {
        guard case .account(let token, _) = readFixtureCredential() else { return .failed("fixture has no usable token") }
        if let id = await recorder.push(task, token: token) { return .pushed(id) }
        return .failed("fixture request failed")
    }
}
@MainActor @Observable final class PublicationPhase {
    var scope: WatchAccountScope?
    init(scope: WatchAccountScope?) { self.scope = scope }
}
@MainActor final class ShareSubject {
    let outbox: ShareOutboxStore
    let saveOperation: @MainActor (SharedCapture) async throws -> Bool
    init(directory: URL, recorder: PushRecorder) {
        outbox = ShareOutboxStore(directoryURL: directory)
        #if SHARE_SCOPE_PRESENT
        #if SHARE_SERVER_GENERATION
        let writer = ShareCaptureSession(outbox: outbox, directory: directory, credential: {
            switch readFixtureCredential() {
            case .account(let token, let owner): .account(token: token, ownerID: owner)
            case .signedOut: .signedOut
            case .unavailable: .unavailable
            }
        }, push: { task, token, authorization in
            do { try authorization.prepare("fixture-generation") } catch { return nil }
            return await recorder.push(task, token: token)
        })
        #else
        let writer = ShareCaptureSession(outbox: outbox, directory: directory, credential: {
            switch readFixtureCredential() {
            case .account(let token, let owner): .account(token: token, ownerID: owner)
            case .signedOut: .signedOut
            case .unavailable: .unavailable
            }
        }, push: { task, token in await recorder.push(task, token: token) })
        #endif
        saveOperation = { try await writer.save($0) == .held }
        #else
        let controller = ShareViewController(outbox: outbox, push: DirectTaskPush(recorder: recorder))
        saveOperation = { try await controller.saveAndPush($0); return false }
        #endif
    }
    func save(_ title: String) async throws -> Bool {
        try await saveOperation(SharedCapture(title: title, urls: [], urgent: false, important: true,
                                             tags: ["scope"], capturedAt: Date(timeIntervalSince1970: 100)))
    }
}
@main struct ShareExtensionScopeProbe {
    static let installation = "9F9C8A0F-29EE-4CB8-98A8-226667E00BC7"
    static let dataset = "C56FD9CE-6BA2-42DF-A158-E0E9EA09634B"
    @MainActor static var failures = 0
    static func token(_ owner: String, version: Int = 1) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["id": owner, "exp": 4_000_000_000, "fixtureVersion": version])
        return "fixture." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".fixture"
    }
    static func setCredential(_ token: String?, status: OSStatus = errSecSuccess) {
        fixtureKeychain.withLock { $0 = FixtureKeychainResult(status: status, data: token.map { Data($0.utf8) }) }
    }
    static func scope(_ owner: String) -> WatchAccountScope { .account(userID: owner, datasetID: dataset) }
    static func makeDirectory(_ root: URL, _ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func identity(_ directory: URL) throws {
        try JSONSerialization.data(withJSONObject: ["installationID": installation, "datasetID": dataset])
            .write(to: directory.appendingPathComponent("watch-dataset-identity.json"), options: .atomic)
    }
    static func publish(_ scope: WatchAccountScope?, directory: URL, nonce: String = UUID().uuidString) throws {
        var record: [String: Any] = ["version": 1, "nonce": nonce, "guestBootstrap": false]
        if let scope { record["scope"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scope)) }
        try JSONSerialization.data(withJSONObject: record)
            .write(to: directory.appendingPathComponent("share-scope-publication.json"), options: .atomic)
    }
    static func origin(_ capture: SharedCapture?) -> WatchAccountScope? {
        guard let capture else { return nil }
        let object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(capture)) as! [String: Any]
        guard let raw = object["origin"] else { return nil }
        return try! JSONDecoder().decode(WatchAccountScope.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("SHARE_EXTENSION_SCOPE_CHECK " + String(decoding: data, as: UTF8.self))
    }
    @MainActor static func waitFor(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @MainActor static func credentialChecks(root: URL) async throws {
        setCredential(nil, status: errSecItemNotFound)
        let missing = readFixtureCredential() == .signedOut
        setCredential(nil, status: errSecInteractionNotAllowed)
        let unavailable = readFixtureCredential() == .unavailable
        setCredential("malformed", status: errSecSuccess)
        let malformed = readFixtureCredential() == .unavailable
        let a = try token("fixture-account-a")
        setCredential(a)
        let valid = readFixtureCredential() == .account(token: a, owner: "fixture-account-a")
        check("keychain_missing_unavailable_and_token_are_distinct", missing && unavailable && malformed && valid)

        let signedIn = try makeDirectory(root, "signed-in-no-publication")
        let recorder = PushRecorder()
        let subject = ShareSubject(directory: signedIn, recorder: recorder)
        let held = try await subject.save("Do not adopt an unverified personal account")
        check("missing_publication_never_authorizes_account_post", held && recorder.posts.isEmpty
              && subject.outbox.pending().count == 1 && (origin(subject.outbox.pending().first?.capture)) == nil)

        let guest = try makeDirectory(root, "first-guest")
        setCredential(nil, status: errSecItemNotFound)
        let guestNetwork = PushRecorder(), guestSubject = ShareSubject(directory: guest, recorder: guestNetwork)
        _ = try await guestSubject.save("First ever share")
        let guestOrigin = origin(guestSubject.outbox.pending().first?.capture)
        let identityURL = guest.appendingPathComponent("watch-dataset-identity.json")
        let savedIdentity = (try? Data(contentsOf: identityURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        check("first_share_bootstraps_only_unpushed_stable_guest", guestNetwork.posts.isEmpty
              && guestSubject.outbox.pending().count == 1 && guestOrigin?.kind == "guest"
              && guestOrigin?.isValid == true && guestOrigin?.identifier == savedIdentity?["installationID"]
              && guestOrigin?.datasetID == savedIdentity?["datasetID"])

        let locked = try makeDirectory(root, "unavailable")
        setCredential(nil, status: errSecInteractionNotAllowed)
        let lockedNetwork = PushRecorder(), lockedSubject = ShareSubject(directory: locked, recorder: lockedNetwork)
        let lockedHeld = try await lockedSubject.save("Protected data must not become guest")
        check("unavailable_keychain_cannot_bootstrap_guest", lockedHeld && lockedNetwork.posts.isEmpty
              && lockedSubject.outbox.pending().count == 1 && (origin(lockedSubject.outbox.pending().first?.capture)) == nil
              && !FileManager.default.fileExists(atPath: locked.appendingPathComponent("watch-dataset-identity.json").path))
    }

    @MainActor static func staleSheetChecks(root: URL) async throws {
        let a = try token("fixture-account-a"), b = try token("fixture-account-b")
        let foreign = try makeDirectory(root, "account-change")
        try identity(foreign); try publish(scope("fixture-account-a"), directory: foreign); setCredential(a)
        let network = PushRecorder(), subject = ShareSubject(directory: foreign, recorder: network)
        try publish(scope("fixture-account-b"), directory: foreign); setCredential(b)
        let held = try await subject.save("A draft while B is current")
        check("old_sheet_never_posts_with_another_accounts_token", held && network.posts.isEmpty
              && (origin(subject.outbox.pending().first?.capture)) == scope("fixture-account-a"))

        let rotated = try makeDirectory(root, "token-rotation")
        try identity(rotated); try publish(scope("fixture-account-a"), directory: rotated); setCredential(a)
        let rotatedNetwork = PushRecorder(), rotatedSubject = ShareSubject(directory: rotated, recorder: rotatedNetwork)
        setCredential(try token("fixture-account-a", version: 2))
        let rotatedHeld = try await rotatedSubject.save("Same owner with replaced authority")
        check("same_owner_token_replacement_invalidates_open_sheet", rotatedHeld && rotatedNetwork.posts.isEmpty
              && (origin(rotatedSubject.outbox.pending().first?.capture)) == scope("fixture-account-a"))

        let returned = try makeDirectory(root, "same-owner-return")
        try identity(returned); try publish(scope("fixture-account-a"), directory: returned); setCredential(a)
        let returnedNetwork = PushRecorder()
        #if SHARE_SCOPE_PRESENT
        let phase = PublicationPhase(scope: scope("fixture-account-a"))
        let publisher = ShareScopePublisher(directory: returned, scopeProvider: { phase.scope })
        let oldNonce = try ShareScopePublicationStore(directory: returned).read()!.nonce
        #endif
        let returnedSubject = ShareSubject(directory: returned, recorder: returnedNetwork)
        #if SHARE_SCOPE_PRESENT
        phase.scope = nil
        let invalidatedSynchronously = try ShareScopePublicationStore(directory: returned).read()?.scope == nil
        phase.scope = scope("fixture-account-a")
        let rearmed = await waitFor {
            let current = try? ShareScopePublicationStore(directory: returned).read()
            return current?.scope == scope("fixture-account-a") && current?.nonce != oldNonce
        }
        _ = publisher
        #else
        try publish(nil, directory: returned)
        try publish(scope("fixture-account-a"), directory: returned)
        let invalidatedSynchronously = true, rearmed = true
        #endif
        let returnedHeld = try await returnedSubject.save("Old sheet after A returns")
        check("unresolved_then_same_account_keeps_old_sheet_invalid", invalidatedSynchronously && rearmed
              && returnedHeld && returnedNetwork.posts.isEmpty
              && (origin(returnedSubject.outbox.pending().first?.capture)) == scope("fixture-account-a"))
    }

    @MainActor static func journalChecks(root: URL) async throws {
        let a = try token("fixture-account-a")
        let live = try makeDirectory(root, "active-post")
        try identity(live); try publish(scope("fixture-account-a"), directory: live); setCredential(a)
        let network = PushRecorder(); network.hold = true
        let subject = ShareSubject(directory: live, recorder: network)
        let operation = _Concurrency.Task { try await subject.save("Journal before POST") }
        let entered = await waitFor { network.posts.count == 1 }
        #if SHARE_SCOPE_PRESENT
        let journal = subject.outbox.inFlightCaptures().first?.capture
        #else
        let journal: SharedCapture? = nil
        #endif
        let journalMatches = journal?.taskID == network.posts.first?.task.id
            && (origin(journal)) == scope("fixture-account-a")
        setCredential(try token("fixture-account-b"))
        try publish(scope("fixture-account-b"), directory: live)
        network.release()
        let held = try await operation.value
        check("post_uses_frozen_token_after_durable_origin_journal", entered && journalMatches && held
              && network.posts.first?.token == a && subject.outbox.pending().count == 1
              && (origin(subject.outbox.pending().first?.capture)) == scope("fixture-account-a"))

        let abandoned = try makeDirectory(root, "abandoned")
        try identity(abandoned); try publish(scope("fixture-account-a"), directory: abandoned); setCredential(a)
        let recoveryNetwork = PushRecorder(), recovery = ShareSubject(directory: abandoned, recorder: recoveryNetwork)
        let blocker = abandoned.appendingPathComponent(ShareOutboxStore.directoryName)
        try Data("forced regular outbox failure".utf8).write(to: blocker)
        var threw = false
        do { _ = try await recovery.save("Recover the uncertain identity") } catch { threw = true }
        let originalID = recoveryNetwork.posts.first?.task.id
        try FileManager.default.removeItem(at: blocker)
        #if SHARE_SCOPE_PRESENT
        let lease = try await SharedMutationLease.acquire(directory: abandoned, mode: .exclusive)
        try recovery.outbox.recoverInFlight()
        try recovery.outbox.recoverInFlight()
        lease.release()
        let journalEmpty = recovery.outbox.inFlightCaptures().isEmpty
        #else
        let journalEmpty = true
        #endif
        let recovered = recovery.outbox.pending()
        check("abandoned_post_recovers_once_under_the_same_identity", threw && originalID != nil
              && recovered.count == 1 && recovered.first?.capture.taskID == originalID
              && recovered.first?.capture.remoteRecordID == nil && journalEmpty
              && (origin(recovered.first?.capture)) == scope("fixture-account-a"))
    }


    @MainActor static func editedRetryCheck(root: URL) async throws {
        let directory = try makeDirectory(root, "edited-retry-fact")
        let a = try token("fixture-account-a")
        try identity(directory); try publish(scope("fixture-account-a"), directory: directory); setCredential(a)
        let network = PushRecorder(), subject = ShareSubject(directory: directory, recorder: network)
        let blocker = directory.appendingPathComponent(ShareOutboxStore.directoryName)
        try Data("forced regular outbox failure".utf8).write(to: blocker)
        var failed = false
        do { _ = try await subject.save("Original input") } catch { failed = true }
        let originalID = network.posts.first?.task.id
        try FileManager.default.removeItem(at: blocker)
        _ = try await subject.save("Edited after the failed save")
        let pending = subject.outbox.pending()
        let stored = try pending.first.map {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.capture)) as! [String: Any]
        }
        check("edited_retry_records_authored_change_without_timestamp_inference",
              failed && originalID != nil && network.posts.count == 1 && pending.count == 1
              && pending.first?.capture.taskID == originalID
              && pending.first?.capture.title == "Edited after the failed save"
              && pending.first?.capture.capturedAt == Date(timeIntervalSince1970: 100)
              && stored?["isEditedRetry"] as? Bool == true)
    }

    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDShareExtensionScope-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try await credentialChecks(root: root)
            try await staleSheetChecks(root: root)
            try await journalChecks(root: root)
            try await editedRetryCheck(root: root)
            exit(failures == 0 ? 0 : 1)
        } catch {
            print("SHARE_EXTENSION_SCOPE_ERROR " + String(describing: error)); exit(2)
        }
    }
}
