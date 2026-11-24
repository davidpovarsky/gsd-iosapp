#!/usr/bin/env python3
"""Probe automatic scheduling through the actual app SyncCoordinator source.

Only Network/GSDSync/GSDStore import boundaries are replaced. A controlled path
monitor invokes the registered callback from its dispatch queue; the engine seam
records calls, without implementing task storage or synchronization. Real engine,
Oracle, physical connectivity and app UI acceptance remain separate evidence.
"""
import argparse
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
EXPECTED_CASES = 8
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

struct NWPath: Sendable {
    enum Status: Sendable, Equatable { case satisfied, unsatisfied }
    let status: Status
}
final class NWPathMonitor: Sendable {
    private struct State {
        var handler: (@Sendable (NWPath) -> Void)?
        var queue: DispatchQueue?
        var cancelled = false
    }
    private let state = Mutex(State())
    private static let instances = Mutex<[NWPathMonitor]>([])
    init() { Self.instances.withLock { $0.append(self) } }
    static var count: Int { instances.withLock { $0.count } }
    static var latest: NWPathMonitor? { instances.withLock { $0.last } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var started: Bool { state.withLock { $0.queue != nil && $0.handler != nil } }
    var pathUpdateHandler: (@Sendable (NWPath) -> Void)? {
        get { state.withLock { $0.handler } }
        set { state.withLock { $0.handler = newValue } }
    }
    func start(queue: DispatchQueue) { state.withLock { $0.queue = queue } }
    func cancel() { state.withLock { $0.cancelled = true } }
    // queued=true models a callback already queued before cancellation.
    func emit(_ status: NWPath.Status, queued: Bool = false) async -> Bool {
        let delivery = state.withLock { value -> (@Sendable (NWPath) -> Void, DispatchQueue)? in
            guard queued || !value.cancelled,
                  let handler = value.handler, let queue = value.queue else { return nil }
            return (handler, queue)
        }
        guard let (handler, queue) = delivery else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                handler(NWPath(status: status))
                continuation.resume(returning: true)
            }
        }
    }
}
enum SyncTrigger: Sendable, Equatable {
    case launch, signIn, manual, foreground, periodic, networkRegained, mutation, background
}
struct SyncResult: Sendable {
    var skipped = false
    var notSignedIn = false
    var error: String?
}
struct SyncHealth: Sendable {
    enum Level: Sendable, Equatable { case ok, warning }
    let level: Level
    let message: String?
}
// These async boundary methods deliberately have no suspension points. Once the
// health acknowledgment is visible on MainActor, that callback has completed its
// scheduling decision. This probe does not model the real engine actor's work.
@MainActor final class SyncEngine {
    var triggers: [SyncTrigger] = []
    var healthReads = 0
    var resetCount = 0
    var signInCount = 0
    func sync(trigger: SyncTrigger) async -> SyncResult {
        triggers.append(trigger); return SyncResult()
    }
    func health(online: Bool) async -> SyncHealth {
        healthReads += 1
        return SyncHealth(level: online ? .ok : .warning, message: nil)
    }
    func pendingCount() async -> Int { 0 }
    func beginSignIn() async { signInCount += 1 }
    func resetCursor() async { resetCount += 1 }
    func pushNow() async -> SyncResult { SyncResult() }
    func eraseAllRemote() async -> SyncResult { SyncResult() }
    func flushDeletes() async -> SyncResult { SyncResult() }
    func applyRealtime(rawData: Data) async {}
}
struct PocketBaseRealtime: Sendable {
    func events(token: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
@MainActor final class TaskStore { func eraseAllData() async throws {} }
enum AccountDeleter {
    struct ErasePass { init(_ result: SyncResult) {} }
}
'''

CHECKS = r'''
struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
@MainActor final class SessionFlag { var signedIn = true }
@MainActor struct Fixture {
    let engine: SyncEngine
    let session: SessionFlag
    let coordinator: SyncCoordinator
    init() {
        let engine = SyncEngine(), session = SessionFlag()
        self.engine = engine; self.session = session
        coordinator = SyncCoordinator(engine: engine, realtime: PocketBaseRealtime(),
                                      tokenProvider: { nil }, signedIn: { session.signedIn })
    }
    func start(trigger: SyncTrigger = .launch) async throws -> NWPathMonitor {
        let before = NWPathMonitor.count, reads = engine.healthReads
        coordinator.start(trigger: trigger)
        try await waitFor("initial sync and status") { engine.healthReads > reads }
        guard NWPathMonitor.count == before + 1, let monitor = NWPathMonitor.latest,
              engine.triggers.last == trigger else { throw ProbeFailure("monitor/start mismatch") }
        return monitor
    }
    func emit(_ status: NWPath.Status, via monitor: NWPathMonitor,
              syncs: Int = 0, queued: Bool = false) async throws {
        let reads = engine.healthReads
        guard await monitor.emit(status, queued: queued) else { throw ProbeFailure("event not delivered") }
        // One health read belongs to the callback; each clean sync schedules a
        // further status refresh. Await both so no earlier work can acknowledge
        // the next event. Production callback code is never called directly.
        try await waitFor("callback and resulting status") { engine.healthReads >= reads + 1 + syncs }
    }
}
@MainActor func waitFor(_ reason: String, _ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(2)
    while !condition() {
        guard clock.now < deadline else { throw ProbeFailure("timeout waiting for " + reason) }
        try await _Concurrency.Task.sleep(for: .milliseconds(2))
    }
}
@main struct SyncConnectivityCheck {
    @MainActor static var passes = 0
    @MainActor static var failures = 0
    @MainActor static func check(_ name: String, _ body: @MainActor () async throws -> Bool) async {
        do {
            if try await body() { passes += 1; print("PASS " + name) }
            else { failures += 1; print("FAIL " + name) }
        } catch {
            failures += 1; print("FAIL " + name + ": " + String(describing: error))
        }
    }
    @MainActor static func run() async {
        await check("launch registers and starts the monitor") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            return monitor.started && !monitor.cancelled && f.engine.triggers == [.launch]
        }
        await check("loss then return schedules exactly one recovery sync") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            try await f.emit(.unsatisfied, via: monitor)
            guard f.coordinator.health.level == .warning, f.engine.triggers == [.launch] else { return false }
            try await f.emit(.satisfied, via: monitor, syncs: 1)
            return f.coordinator.health.level == .ok && f.engine.triggers == [.launch, .networkRegained]
        }
        await check("repeated path statuses do not duplicate sync") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            try await f.emit(.satisfied, via: monitor)
            try await f.emit(.unsatisfied, via: monitor)
            try await f.emit(.unsatisfied, via: monitor)
            try await f.emit(.satisfied, via: monitor, syncs: 1)
            try await f.emit(.satisfied, via: monitor)
            return f.engine.triggers == [.launch, .networkRegained]
        }
        await check("background cancels recovery and foreground installs a fresh monitor") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            try await f.emit(.unsatisfied, via: monitor)
            f.coordinator.enteredBackground()
            guard monitor.cancelled, !(await monitor.emit(.satisfied)) else { return false }
            try await f.emit(.satisfied, via: monitor, queued: true)
            guard f.engine.triggers == [.launch] else { return false }
            let reads = f.engine.healthReads, count = NWPathMonitor.count
            f.coordinator.enteredForeground()
            try await waitFor("foreground status") { f.engine.healthReads > reads }
            return NWPathMonitor.count == count + 1 && NWPathMonitor.latest !== monitor
                && f.engine.triggers == [.launch, .foreground]
        }
        await check("sign out cancels callbacks and resets the existing cursor") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            try await f.emit(.unsatisfied, via: monitor)
            f.session.signedIn = false; f.coordinator.signedOut()
            try await waitFor("cursor reset") { f.engine.resetCount == 1 }
            try await f.emit(.satisfied, via: monitor, queued: true)
            f.coordinator.start(); f.coordinator.enteredForeground(); await f.coordinator.syncNow()
            return monitor.cancelled && f.engine.triggers == [.launch]
        }
        await check("session loss suppresses recovery before lifecycle teardown") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            try await f.emit(.unsatisfied, via: monitor)
            f.session.signedIn = false
            try await f.emit(.satisfied, via: monitor)
            return !monitor.cancelled && f.engine.triggers == [.launch]
        }
        await check("sign in decision holds recovery until explicitly accepted") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            try await f.emit(.unsatisfied, via: monitor)
            await f.coordinator.beginSignIn()
            try await f.emit(.satisfied, via: monitor, queued: true)
            // Keep signedIn true deliberately: the decision hold must be its own guard.
            f.coordinator.start(); f.coordinator.enteredForeground(); await f.coordinator.syncNow()
            guard monitor.cancelled, f.engine.signInCount == 1, f.engine.triggers == [.launch] else { return false }
            let accepted = try await f.start(trigger: .signIn)
            try await f.emit(.unsatisfied, via: accepted)
            try await f.emit(.satisfied, via: accepted, syncs: 1)
            return f.engine.triggers == [.launch, .signIn, .networkRegained]
        }
        await check("account deletion holds recovery until failure releases it") {
            let f = Fixture(); defer { f.coordinator.stop() }
            let monitor = try await f.start()
            try await f.emit(.unsatisfied, via: monitor)
            f.coordinator.holdForAccountDeletion()
            try await f.emit(.satisfied, via: monitor, queued: true)
            f.coordinator.start(); f.coordinator.enteredForeground(); await f.coordinator.syncNow()
            guard monitor.cancelled, f.engine.triggers == [.launch] else { return false }
            let reads = f.engine.healthReads
            f.coordinator.releaseAfterFailedAccountDeletion()
            try await waitFor("deletion recovery status") { f.engine.healthReads > reads }
            return f.engine.triggers == [.launch, .manual] && NWPathMonitor.latest !== monitor
        }
        print("SYNC_CONNECTIVITY_RESULT passed=\(passes) failed=\(failures)")
    }
    @MainActor static func main() async {
        await run()
        if failures != 0 || passes != 8 { exit(1) }
    }
}
'''


def run_bounded(arguments, timeout):
    """Stop only this command's process tree if its toolchain or probe stalls."""
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
        return subprocess.CompletedProcess(arguments, 124, output, errors + "\nTimed out; no behavioral pass.\n")
    return subprocess.CompletedProcess(arguments, process.returncode, output, errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--parse-only", action="store_true", help="Swift syntax only; does not run behavior")
    args = parser.parse_args()
    source_path = ROOT / "App/Sync/SyncCoordinator.swift"
    coordinator = source_path.read_text(encoding="utf-8")
    for module in ("Network", "GSDSync", "GSDStore"):
        boundary = f"import {module}\n"
        assert coordinator.count(boundary) == 1, f"{module} boundary changed; review the probe explicitly"
        coordinator = coordinator.replace(boundary, "")
    assert coordinator.count("final class SyncCoordinator") == 1, "Coordinator source boundary changed"
    compiler_name = "swift-frontend" if args.parse_only else "swiftc"
    compiler = shutil.which(compiler_name)
    if not compiler:
        raise SystemExit(compiler_name + " is required")
    print(json.dumps({"compiler": compiler, "expected_cases": EXPECTED_CASES,
                      "scope": "actual coordinator scheduling; controlled monitor and recording engine boundary",
                      "source_sha256": {str(source_path.relative_to(ROOT)):
                                        hashlib.sha256(source_path.read_bytes()).hexdigest()}}), flush=True)
    with tempfile.TemporaryDirectory(prefix="gsd-sync-connectivity-") as scratch:
        scratch = Path(scratch)
        source = scratch / "SyncConnectivityCheck.swift"
        executable = scratch / ("SyncConnectivityCheck.exe" if os.name == "nt" else "SyncConnectivityCheck")
        source.write_text(SEAMS + coordinator + CHECKS, encoding="utf-8")
        if args.parse_only:
            arguments = [compiler, "-frontend", "-parse", str(source)]
        else:
            arguments = [compiler, "-swift-version", "6", "-warnings-as-errors", "-parse-as-library",
                         str(source), "-o", str(executable)]
        build = run_bounded(arguments, timeout=30 if args.parse_only else 180)
        print(build.stdout, end="")
        print(build.stderr, end="", file=sys.stderr)
        if build.returncode:
            return build.returncode
        if args.parse_only:
            print("SYNC_CONNECTIVITY_PARSE_RESULT pass=1 behavior=not_run")
            return 0
        run = run_bounded([str(executable)], timeout=20)
        print(run.stdout, end="")
        print(run.stderr, end="", file=sys.stderr)
        return run.returncode


if __name__ == "__main__":
    sys.exit(main())
