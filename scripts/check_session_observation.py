#!/usr/bin/env python3
"""Exercise the app SessionStore with real Observation and in-memory platform seams.

This compiles SessionStore unchanged except for its GSDSync import, plus the real
KeychainTokenStore load/save/clear methods. Security.framework storage and the
network/coordinator dependencies are replaced in this host-only probe. It does
not replace the canonical Xcode app build or a real Keychain acceptance test.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SEAMS = r'''
import Foundation
import Observation
import Synchronization
#if os(Windows)
import ucrt
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}
let errSecSuccess: Int32 = 0
enum SharedTokenKeychain {
    static let value = Mutex<String?>(nil)
    static func load() -> String? { value.withLock { $0 } }
    static func save(_ token: String) -> Int32 {
        value.withLock { $0 = token }; return errSecSuccess
    }
    static func clear() { value.withLock { $0 = nil } }
}
struct AuthRecord: Sendable { let id: String; let email: String? }
struct AuthResult: Sendable { let token: String; let record: AuthRecord }
enum AuthError: Error { case cancelled }
struct AuthService: Sendable {
    let tokenStore: any TokenStore
    func currentUserId() -> String? { tokenStore.load()?.split(separator: "|").first.map(String.init) }
    func enabledOAuthProviders() async -> [String] { [] }
    func signIn(provider: String) async throws -> AuthResult { issue() }
    func signInWithEmail(_ email: String, password: String) async throws -> AuthResult { issue() }
    func createAccountWithEmail(_ email: String, password: String) async throws -> AuthResult { issue() }
    private func issue() -> AuthResult {
        let result = AuthResult(token: "owner-b|fixture", record: AuthRecord(id: "owner-b", email: "same@example.test"))
        tokenStore.save(result.token); return result
    }
    func signOut() { tokenStore.clear() }
    func deleteAccountViaRoute() async throws { tokenStore.clear() }
    func deleteAccount() async throws { tokenStore.clear() }
}
enum AppleIdentity {
    enum AccountNote: Equatable { case separateAccount }
    static func accountNote(provider: String, email: String?) -> AccountNote? { nil }
}
enum AccountSwitch {
    enum Decision { case proceed, prompt }
    static func evaluate(lastOwnerId: String?, newOwnerId: String, hasLocalActiveTasks: Bool) -> Decision {
        lastOwnerId != nil && lastOwnerId != newOwnerId && hasLocalActiveTasks ? .prompt : .proceed
    }
}
struct EraseReport: Sendable { static let empty = EraseReport() }
struct AccountDeleter: Sendable {
    enum Outcome: Sendable {
        case deleted, sessionExpired, failed(remoteTasksErased: Bool)
        var endsSession: Bool { if case .failed(let erased) = self { return erased }; return true }
    }
    let deleteViaRoute: @Sendable () async throws -> Void
    let erasePass: @Sendable () async -> EraseReport
    let deleteUserRecord: @Sendable () async throws -> Void
    func delete() async -> Outcome {
        do { try await deleteViaRoute(); return .deleted } catch { return .sessionExpired }
    }
}
@MainActor final class SyncCoordinator {
    enum Trigger { case signIn }
    func beginSignIn() async {}
    func cancelSignIn() {}
    func signedOut() {}
    func start(trigger: Trigger) {}
    func holdForAccountDeletion() {}
    func releaseAfterFailedAccountDeletion() {}
    func eraseRemoteTasksPass() async -> EraseReport { .empty }
    func syncNow() async {}
}
#if !canImport(Darwin)
extension String { init(localized value: String) { self = value } }
#endif
'''

LEGACY_SEAM = r'''
    private enum Legacy {
        static let value = Mutex<String?>(nil)
        static func load() -> String? { value.withLock { $0 } }
        static func save(_ token: String) { value.withLock { $0 = token } }
        static func clear() { value.withLock { $0 = nil } }
    }
}
'''

CHECKS = r'''
final class ChangeCounter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}
final class NoticeRecorder: Sendable {
    private let values = Mutex<[Bool]>([])
    func record(_ notice: Notification) {
        values.withLock { $0.append(notice.object == nil && notice.userInfo == nil) }
    }
    var hasTwoEmptyPayloads: Bool { values.withLock { $0 == [true, true] } }
}
@main struct SessionObservationCheck {
    @MainActor static var failures = 0
    @MainActor static var passes = 0
    static let changed = Notification.Name("com.itorah.gsd.sessionTokenDidChange")
    @MainActor static func check(_ name: String, _ condition: Bool) {
        if condition { passes += 1; print("PASS " + name) }
        else { failures += 1; print("FAIL " + name) }
    }
    @MainActor static func watch(_ session: SessionStore) -> ChangeCounter {
        let counter = ChangeCounter()
        withObservationTracking {
            _ = session.currentUserID; _ = session.isSignedIn
        } onChange: { counter.increment() }
        return counter
    }
    @MainActor static func settle() async {
        try? await _Concurrency.Task.sleep(for: .milliseconds(100))
    }
    @MainActor static func makeSession(localTasks: Bool = false) -> SessionStore {
        SessionStore(auth: AuthService(tokenStore: KeychainTokenStore()), tokenStore: KeychainTokenStore(),
                     hasLocalActiveTasks: { localTasks })
    }
    @MainActor static func reset() async {
        KeychainTokenStore().clear()
        for key in ["gsd.accountEmail", "gsd.accountProvider", "gsd.lastOwnerId"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        await settle()
    }
    @MainActor static func run() async -> Int {
        let keys = ["gsd.accountEmail", "gsd.accountProvider", "gsd.lastOwnerId"]
        let original = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, original) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        await reset()
        do {
            KeychainTokenStore().save("owner-a|initial")
            let session = makeSession()
            check("initial identity comes from the existing token store", session.isSignedIn && session.currentUserID == "owner-a")
        }
        await reset()
        do {
            let notices = NoticeRecorder()
            let observer = NotificationCenter.default.addObserver(forName: changed, object: nil, queue: nil) { notice in
                notices.record(notice)
            }
            KeychainTokenStore().save("owner-a|private-fixture")
            KeychainTokenStore().clear()
            NotificationCenter.default.removeObserver(observer)
            check("save and clear each publish one payload-free notice", notices.hasTwoEmptyPayloads)
        }
        await reset()
        do {
            KeychainTokenStore().save("owner-a|initial")
            UserDefaults.standard.set("same@example.test", forKey: "gsd.accountEmail")
            let session = makeSession()
            let observed = watch(session)
            await _Concurrency.Task.detached { KeychainTokenStore().save("owner-b|replacement") }.value
            await settle()
            check("external different owner invalidates identity even with unchanged email", observed.count > 0 && session.currentUserID == "owner-b" && session.email == "same@example.test")
        }
        await reset()
        do {
            KeychainTokenStore().save("owner-a|initial")
            let session = makeSession()
            let observed = watch(session)
            await _Concurrency.Task.detached { KeychainTokenStore().clear() }.value
            await settle()
            check("rejected-refresh clear invalidates identity without a UI action", observed.count > 0 && !session.isSignedIn && session.currentUserID == nil)
        }
        await reset()
        do {
            KeychainTokenStore().save("owner-a|initial")
            let session = makeSession()
            let observed = watch(session)
            KeychainTokenStore().save("owner-a|renewed")
            await settle()
            check("same-owner refresh preserves identity without a false switch", observed.count == 0 && session.currentUserID == "owner-a" && session.isSignedIn)
        }
        await reset()
        do {
            KeychainTokenStore().save("owner-a|initial")
            let session = makeSession()
            let observed = watch(session)
            session.signOut()
            check("explicit sign-out updates observed identity synchronously", observed.count > 0 && session.currentUserID == nil && !session.isSignedIn)
        }
        await reset()
        do {
            let session = makeSession()
            let observed = watch(session)
            KeychainTokenStore().save("owner-b|queued")
            KeychainTokenStore().clear()
            await settle()
            check("queued notices reread current state instead of replaying an old owner", observed.count == 0 && session.currentUserID == nil && !session.isSignedIn)
        }
        await reset()
        do {
            UserDefaults.standard.set("owner-a", forKey: "gsd.lastOwnerId")
            let session = makeSession(localTasks: true)
            await session.signInWithEmail("same@example.test", password: "test-only", createAccount: false)
            check("pending account decision holds credentials and publishes signed-out state", session.pendingAccountSwitch?.newOwnerId == "owner-b" && !session.isSignedIn && session.currentUserID == nil && KeychainTokenStore().load() == nil)
            let observed = watch(session)
            session.resolveAccountSwitch(.fresh)
            await settle()
            check("accepted account decision publishes the new owner", observed.count > 0 && session.currentUserID == "owner-b" && session.isSignedIn)
        }
        await reset()
        do {
            KeychainTokenStore().save("owner-a|initial")
            let session = makeSession()
            let observed = watch(session)
            await session.deleteAccount(eraseLocalData: false)
            check("confirmed deletion invalidates the observed identity", observed.count > 0 && !session.isSignedIn && session.currentUserID == nil)
        }
        await reset()
        do {
            var session: SessionStore? = makeSession()
            weak let weakSession = session
            session = nil
            await settle()
            check("notification observation does not retain the session", weakSession == nil)
        }
        await reset()
        print("SESSION_OBSERVATION_RESULT passed=\(passes) failed=\(failures)")
        return failures == 0 ? 0 : 1
    }
    @MainActor static func main() async {
        let result = await run()
        if result != 0 { exit(Int32(result)) }
    }
}
'''


def run_bounded(arguments, timeout):
    """Stop only this command's process tree if the toolchain stalls."""
    process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               start_new_session=os.name != "nt",
                               creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0)
    try:
        output, errors = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(process.pid), "/T", "/F"],
                           capture_output=True, timeout=15, check=False)
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        output, errors = process.communicate(timeout=15)
        return subprocess.CompletedProcess(arguments, 124, output, errors + "\nToolchain timed out; no behavioral result.\n")
    return subprocess.CompletedProcess(arguments, process.returncode, output, errors)


def main():
    session_path = ROOT / "App/Auth/SessionStore.swift"
    keychain_path = ROOT / "App/Auth/KeychainTokenStore.swift"
    session = session_path.read_text(encoding="utf-8")
    keychain = keychain_path.read_text(encoding="utf-8")
    marker = "    /// The app-private item earlier builds wrote"
    assert keychain.count(marker) == 1, "Keychain storage boundary changed; update this probe explicitly"
    keychain = keychain.split(marker)[0] + LEGACY_SEAM
    for module in ["Security", "GSDSync", "GSDWire"]:
        keychain = keychain.replace(f"import {module}\n", "")
    session = session.replace("import GSDSync\n", "")
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("swiftc is required")
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in (session_path, keychain_path)}
    print(json.dumps({"swiftc": compiler, "source_sha256": hashes}), flush=True)
    with tempfile.TemporaryDirectory(prefix="gsd-session-observation-") as scratch:
        scratch = Path(scratch)
        source = scratch / "SessionObservationCheck.swift"
        executable = scratch / ("SessionObservationCheck.exe" if os.name == "nt" else "SessionObservationCheck")
        source.write_text(SEAMS + keychain + session + CHECKS, encoding="utf-8")
        build = run_bounded([compiler, "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                             str(source), "-o", str(executable)], timeout=180)
        print(build.stdout, end="")
        print(build.stderr, end="", file=sys.stderr)
        if build.returncode:
            return build.returncode
        run = run_bounded([str(executable)], timeout=20)
        print(run.stdout, end="")
        print(run.stderr, end="", file=sys.stderr)
        return run.returncode


if __name__ == "__main__":
    sys.exit(main())
