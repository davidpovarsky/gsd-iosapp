import Foundation
import Testing
import GSDModel
@testable import GSDWire

struct CloudTimerWireTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func task(_ entries: [TimeEntry]) -> GSDModel.Task {
        GSDModel.Task(id: "cloud-timer-task", title: "Timer", urgent: false, important: true,
                      createdAt: start, updatedAt: start, timeEntries: entries)
    }

    @Test func exactTimersAndNotesSurviveBothDirections() {
        let entries = [
            TimeEntry(id: "stopped1", startedAt: start, endedAt: start.addingTimeInterval(92.125), notes: "Retained note"),
            TimeEntry(id: "running1", startedAt: start.addingTimeInterval(100))
        ]
        let wire = TaskWireMapper.toWire(task(entries), owner: "owner", deviceId: "test", defaultReminder: 0)
        #expect(wire.timeEntries[0].minutes == 1)
        #expect(wire.timeEntries[1].endedAt == "")
        let pulled = TaskWireMapper.toDomain(wire, mergingInto: nil)
        #expect(pulled.timeEntries == entries)
        let merged = TaskWireMapper.toDomain(wire, mergingInto: task([]))
        #expect(merged.timeEntries == entries)
        #expect(merged.timeSpent == 1)
    }

    @Test func remoteStopClosesLocalTimerAndKeepsAnUnpublishedLocalEntry() {
        let local = task([TimeEntry(id: "shared01", startedAt: start),
                          TimeEntry(id: "local001", startedAt: start, endedAt: start.addingTimeInterval(60))])
        let remote = task([TimeEntry(id: "shared01", startedAt: start, endedAt: start.addingTimeInterval(90), notes: "From MCP")])
        let wire = TaskWireMapper.toWire(remote, owner: "owner", deviceId: "test", defaultReminder: 0)
        let merged = TaskWireMapper.toDomain(wire, mergingInto: local)
        #expect(merged.timeEntries.count == 2)
        #expect(merged.timeEntries.first?.endedAt == start.addingTimeInterval(90))
        #expect(merged.timeEntries.first?.notes == "From MCP")
    }

    @Test func legacyMinuteOnlyWireDoesNotEraseRichLocalTimers() {
        let local = task([TimeEntry(id: "legacy01", startedAt: start, notes: "Still running")])
        var wire = TaskWireMapper.toWire(local, owner: "owner", deviceId: "test", defaultReminder: 0)
        wire.timeEntries = [WireTimeEntry(id: "legacy01", startedAt: WireDate.format(start), minutes: 0)]
        #expect(TaskWireMapper.toDomain(wire, mergingInto: local).timeEntries == local.timeEntries)
    }
}
