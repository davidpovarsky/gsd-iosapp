import Foundation
import GSDSnapshot

/// These checks use separate copies of this native executable and actual file leases.
/// No networking, personal credentials or real task dataset is involved.
@main struct ShareProcessProbe {
    enum ProbeError: Error { case setup(String), expectedBodyFailure }
    @MainActor static var failures = 0
    @MainActor static var children: [Process] = []

    static func makeDirectory(_ root: URL, _ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    static func writeFlag(_ url: URL) throws { try Data("ready".utf8).write(to: url, options: .atomic) }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    static func inode(_ directory: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(SharedMutationLease.filename).path)
        guard let value = attributes[.systemFileNumber] as? NSNumber else { throw ProbeError.setup("missing inode") }
        return value.uint64Value
    }
    @MainActor static func waitFor(_ condition: @MainActor () -> Bool, attempts: Int = 600) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    @MainActor static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        let data = try! JSONSerialization.data(withJSONObject: ["name": name, "passed": passed], options: [.sortedKeys])
        print("SHARE_PROCESS_CHECK " + String(decoding: data, as: UTF8.self))
    }
    @MainActor static func launch(_ arguments: [String]) throws -> Process {
        let process = Process()
        guard let executableURL = Bundle.main.executableURL,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProbeError.setup("The running process executable could not be resolved.")
        }
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        children.append(process)
        return process
    }
    @MainActor static func cleanChildren() async {
        for process in children where process.isRunning { process.terminate() }
        _ = await waitFor({ children.allSatisfy { !$0.isRunning } })
    }

    static func leaseChild(directory: URL) async throws {
        let lease = try await SharedMutationLease.acquire(directory: directory, mode: .shared)
        defer { lease.release() }
        try writeFlag(directory.appendingPathComponent("child-ready"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !exists(directory.appendingPathComponent("child-release")) {
            guard ContinuousClock.now < deadline else { throw ProbeError.setup("lease child release deadline") }
            try await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
    }
    static func identityChild(directory: URL, index: String) async throws {
        try writeFlag(directory.appendingPathComponent("identity-ready-" + index))
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !exists(directory.appendingPathComponent("identity-go")) {
            guard ContinuousClock.now < deadline else { throw ProbeError.setup("identity child start deadline") }
            try await _Concurrency.Task.sleep(for: .milliseconds(5))
        }
        let identity = try SharedDatasetIdentityStore(directory: directory).loadOrCreate()
        try JSONEncoder().encode(identity).write(
            to: directory.appendingPathComponent("identity-result-" + index + ".json"), options: .atomic)
    }

    @MainActor static func sharedAdmissionCheck(root: URL) async throws {
        let directory = try makeDirectory(root, "shared-admission")
        let gate = WatchMutationGate(directory: directory)
        guard let before = gate.identity else { throw ProbeError.setup("shared identity") }
        let first = try await SharedMutationLease.acquire(directory: directory, mode: .shared)
        let second = try await SharedMutationLease.acquire(directory: directory, mode: .shared, timeout: .seconds(1))
        defer { first.release(); second.release() }
        let originalInode = try inode(directory)
        var bodyRan = false
        let reset = _Concurrency.Task { @MainActor in
            try await gate.replacingDataset { bodyRan = true }
        }
        guard await waitFor({ gate.isPaused }) else { throw ProbeError.setup("shared reset admission") }
        var mainActorTicks = 0
        for _ in 0..<4 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10))
            mainActorTicks += 1
        }
        let blockedByBoth = !bodyRan && gate.identity == before && gate.admit() == nil
        first.release()
        try await _Concurrency.Task.sleep(for: .milliseconds(40))
        let blockedBySecond = !bodyRan && gate.identity == before
        second.release()
        try await reset.value
        let after = try SharedDatasetIdentityStore(directory: directory).read()
        let finalInode = try inode(directory)
        check("shared_leases_coexist_and_exclusive_reset_keeps_main_actor_responsive",
              blockedByBoth && blockedBySecond && mainActorTicks == 4 && bodyRan
              && !gate.isPaused && after == gate.identity && after.datasetID != before.datasetID
              && after.installationID == before.installationID && finalInode == originalInode)
    }

    @MainActor static func externalProcessCheck(root: URL) async throws {
        let directory = try makeDirectory(root, "external-process")
        let gate = WatchMutationGate(directory: directory)
        guard let before = gate.identity else { throw ProbeError.setup("external identity") }
        let child = try launch(["--lease-child", directory.path])
        defer { if child.isRunning { child.terminate() } }
        guard await waitFor({ exists(directory.appendingPathComponent("child-ready")) && child.isRunning }) else {
            throw ProbeError.setup("external lease readiness")
        }
        let marker = directory.appendingPathComponent("destructive-body")
        let reset = _Concurrency.Task { @MainActor in
            try await gate.replacingDataset { try writeFlag(marker) }
        }
        guard await waitFor({ gate.isPaused }) else { throw ProbeError.setup("external reset admission") }
        try await _Concurrency.Task.sleep(for: .milliseconds(40))
        let persistedBeforeRelease = try SharedDatasetIdentityStore(directory: directory).read()
        let blocked = !exists(marker) && gate.identity == before && persistedBeforeRelease == before
        try writeFlag(directory.appendingPathComponent("child-release"))
        guard await waitFor({ !child.isRunning }) else { throw ProbeError.setup("external child exit") }
        try await reset.value
        check("external_process_share_lease_delays_dataset_reset",
              blocked && child.terminationStatus == 0 && exists(marker)
              && gate.identity?.datasetID != before.datasetID && !gate.isPaused)
    }

    @MainActor static func cancellationCheck(root: URL) async throws {
        let directory = try makeDirectory(root, "cancel-acquisition")
        let gate = WatchMutationGate(directory: directory)
        let held = try await SharedMutationLease.acquire(directory: directory, mode: .shared)
        defer { held.release() }
        var bodyRan = false
        let operation = _Concurrency.Task { @MainActor in
            try await gate.withExternalWritesPaused { bodyRan = true }
        }
        guard await waitFor({ gate.isPaused }) else { throw ProbeError.setup("cancel pause") }
        operation.cancel()
        var cancelled = false
        do { try await operation.value } catch is CancellationError { cancelled = true }
        held.release()
        let next = try await SharedMutationLease.acquire(directory: directory, mode: .exclusive, timeout: .seconds(1))
        next.release()
        let ticket = gate.admit()
        if let ticket { gate.finish(ticket) }
        check("cancelled_exclusive_acquisition_releases_admission_without_running_body",
              cancelled && !bodyRan && !gate.isPaused && ticket != nil)
    }

    @MainActor static func throwingBodyCheck(root: URL) async throws {
        let directory = try makeDirectory(root, "throwing-body")
        let gate = WatchMutationGate(directory: directory)
        var ran = false, threw = false
        do {
            let _: Void = try await gate.withExternalWritesPaused {
                ran = true
                throw ProbeError.expectedBodyFailure
            }
        } catch ProbeError.expectedBodyFailure { threw = true }
        let later = try await SharedMutationLease.acquire(directory: directory, mode: .shared, timeout: .seconds(1))
        later.release()
        check("throwing_external_body_releases_lease_and_local_pause", ran && threw && !gate.isPaused)
    }

    @MainActor static func concurrentIdentityCheck(root: URL) async throws {
        let directory = try makeDirectory(root, "concurrent-first-identity")
        var participants: [Process] = []
        for index in 0..<8 { participants.append(try launch(["--identity-child", directory.path, String(index)])) }
        defer { for child in participants where child.isRunning { child.terminate() } }
        guard await waitFor({
            (0..<8).allSatisfy { exists(directory.appendingPathComponent("identity-ready-" + String($0))) }
        }, attempts: 1_000) else { throw ProbeError.setup("eight identity child readiness") }
        try writeFlag(directory.appendingPathComponent("identity-go"))
        guard await waitFor({ participants.allSatisfy { !$0.isRunning } }, attempts: 1_000) else {
            throw ProbeError.setup("eight identity child completion")
        }
        let winner = try SharedDatasetIdentityStore(directory: directory).read()
        let results = try (0..<8).map {
            try JSONDecoder().decode(SharedDatasetIdentity.self,
                from: Data(contentsOf: directory.appendingPathComponent("identity-result-" + String($0) + ".json")))
        }
        let leftover = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".scope-") }
        check("concurrent_first_processes_share_one_persisted_identity",
              participants.allSatisfy { $0.terminationStatus == 0 } && winner.isValid
              && results.count == 8 && results.allSatisfy { $0 == winner } && leftover.isEmpty)
    }

    @MainActor static func codecCheck(root: URL) async throws {
        let legacy = try makeDirectory(root, "legacy-codec")
        let value = SharedDatasetIdentity(installationID: "67E337DA-5D75-448B-96A0-24874B2B9A28",
                                         datasetID: "74D65B8D-5B3C-4BFD-B1C2-A9A7706E7F93")
        let bytes = try JSONEncoder().encode(value)
        let legacyURL = legacy.appendingPathComponent(SharedDatasetIdentityStore.filename)
        try bytes.write(to: legacyURL, options: .atomic)
        let restored = try SharedDatasetIdentityStore(directory: legacy).loadOrCreate()
        let corrupt = try makeDirectory(root, "corrupt-codec")
        let invalid = Data("not a JSON identity".utf8)
        let corruptURL = corrupt.appendingPathComponent(SharedDatasetIdentityStore.filename)
        try invalid.write(to: corruptURL, options: .atomic)
        var refused = false
        do { _ = try SharedDatasetIdentityStore(directory: corrupt).loadOrCreate() } catch { refused = true }
        let held = WatchMutationGate(directory: corrupt)
        let legacyAfter = try Data(contentsOf: legacyURL), corruptAfter = try Data(contentsOf: corruptURL)
        check("corrupt_identity_stays_held_and_legacy_codec_survives",
              restored == value && legacyAfter == bytes
              && refused && held.identity == nil && held.admit() == nil && corruptAfter == invalid)
    }

    @MainActor static func processDeathCheck(root: URL) async throws {
        let directory = try makeDirectory(root, "process-death")
        let gate = WatchMutationGate(directory: directory)
        guard let before = gate.identity else { throw ProbeError.setup("death identity") }
        let child = try launch(["--lease-child", directory.path])
        defer { if child.isRunning { child.terminate() } }
        guard await waitFor({ exists(directory.appendingPathComponent("child-ready")) && child.isRunning }) else {
            throw ProbeError.setup("death child readiness")
        }
        let originalInode = try inode(directory)
        var bodyRan = false
        let reset = _Concurrency.Task { @MainActor in
            try await gate.replacingDataset { bodyRan = true }
        }
        guard await waitFor({ gate.isPaused }) else { throw ProbeError.setup("death reset admission") }
        try await _Concurrency.Task.sleep(for: .milliseconds(40))
        let blocked = !bodyRan && gate.identity == before
        child.terminate()
        guard await waitFor({ !child.isRunning }) else { throw ProbeError.setup("owned child termination") }
        try await reset.value
        let finalInode = try inode(directory)
        check("owned_process_death_releases_local_lease_without_replacing_lock_inode",
              blocked && bodyRan && gate.identity?.datasetID != before.datasetID
              && child.terminationReason == .uncaughtSignal && finalInode == originalInode)
    }

    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--lease-child", args.count == 2 {
            do { try await leaseChild(directory: URL(fileURLWithPath: args[1])); exit(0) }
            catch { exit(2) }
        }
        if args.first == "--identity-child", args.count == 3 {
            do { try await identityChild(directory: URL(fileURLWithPath: args[1]), index: args[2]); exit(0) }
            catch { exit(2) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GSDShareProcesses-" + UUID().uuidString)
        let status: Int32
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await sharedAdmissionCheck(root: root)
            try await externalProcessCheck(root: root)
            try await cancellationCheck(root: root)
            try await throwingBodyCheck(root: root)
            try await concurrentIdentityCheck(root: root)
            try await codecCheck(root: root)
            try await processDeathCheck(root: root)
            status = failures == 0 ? 0 : 1
        } catch {
            print("SHARE_PROCESS_ERROR " + String(describing: error))
            status = 2
        }
        await cleanChildren()
        try? FileManager.default.removeItem(at: root)
        exit(status)
    }
}
