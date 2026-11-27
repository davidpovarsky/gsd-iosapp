import Foundation
import UIKit
import XCTest

/// Supplemental iPad touch acceptance against the ordinary persistent app on a fresh owned simulator.
/// No demo seed, in-memory store, direct database edit, or injected task mutation is used.
@MainActor
final class GSDMatrixPersistenceUITests: XCTestCase {
    private enum Failure: Error { case condition(String) }
    private var hebrew = false
    private var artifacts = URL(fileURLWithPath: "/")
    private var receipt: [String: Any] = [:]
    private var checks: [String] = []

    func testNativeMatrixDragPersistsAfterRelaunch() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["GSD_SYSTEM_SURFACE_FRESH_SIMULATOR"] == "1",
              let source = environment["GSD_SYSTEM_SURFACE_APP_SOURCE"],
              source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let simulator = environment["GSD_SYSTEM_SURFACE_SIMULATOR_UDID"],
              UUID(uuidString: simulator) != nil,
              let path = environment["GSD_SYSTEM_SURFACE_ARTIFACTS"], path.hasPrefix("/"),
              let language = environment["GSD_TEST_LANGUAGE"], ["en", "he"].contains(language) else {
            throw Failure.condition("Missing owned-simulator, source, language, or artifact contract.")
        }
        try require(UIDevice.current.userInterfaceIdiom == .pad, "This native drag gate requires iPad.")
        hebrew = language == "he"
        artifacts = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        receipt = [
            "schemaVersion": 1, "sourceSHA": source, "simulator": simulator,
            "language": language, "scope": "ordinary_app_native_matrix_drag_and_disk_relaunch",
            "demoSeed": false, "inMemoryStore": false, "passed": false
        ]
        try persist()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(bundleIdentifier: "com.itorah.gsd")
        app.launchArguments = [
            "-AppleLanguages", hebrew ? "(he)" : "(en)",
            "-AppleLocale", hebrew ? "he_IL" : "en_US"
        ]
        defer { app.terminate() }
        do {
            try exerciseMatrix(app)
            receipt["passed"] = true
            try persist()
        } catch {
            try? capture(app, "failure-matrix-native-state")
            receipt["failure"] = String(describing: error)
            try persist()
            throw error
        }
    }

    private func exerciseMatrix(_ app: XCUIApplication) throws {
        let token = String(UUID().uuidString.prefix(8))
        let sourceTitle = "GSD Matrix source " + token
        let destinationTitle = "GSD Matrix destination " + token
        let schedule = hebrew ? "לתכנן" : "Schedule"
        let doFirst = hebrew ? "לביצוע מיידי" : "Do First"
        receipt["syntheticTitles"] = [sourceTitle, destinationTitle]
        app.launch()
        try requireMatrix(app)
        let sourceID = try createTask(sourceTitle, quadrantTaps: 1, expectedQuadrant: doFirst, in: app)
        let destinationID = try createTask(destinationTitle, quadrantTaps: 2, expectedQuadrant: schedule, in: app)
        try require(sourceID != destinationID, "The two ordinary tasks must have distinct canonical IDs.")
        receipt["taskCardIDs"] = [sourceID, destinationID]
        try checked("twoOrdinaryTasksCreated")

        // The existing product-video helper observes this native keyboard key. If it is absent,
        // attempt a tap on the observed navigation bar, then require actual keyboard dismissal.
        if app.keyboards.firstMatch.exists {
            let hide = app.keyboards.buttons[hebrew ? "הסתרת המקלדת" : "Hide keyboard"]
            if hide.exists {
                hide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                let bar = app.navigationBars.firstMatch
                try require(bar.waitForExistence(timeout: 5), "The navigation bar is unavailable.")
                bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            try require(app.keyboards.firstMatch.waitForNonExistence(timeout: 8),
                        "The native keyboard must dismiss before the Matrix drag.")
        }
        let source = card(sourceID, in: app)
        let destination = card(destinationID, in: app)
        try require(source.isHittable && destination.isHittable, "Both Matrix cards must be visible and hittable.")
        try require(app.frame.contains(source.frame) && app.frame.contains(destination.frame),
                    "Both full Matrix cards must be inside the observed app viewport.")
        try require(hebrew ? source.frame.midX > destination.frame.midX : source.frame.midX < destination.frame.midX,
                    "The Do First and Schedule panes must follow the current LTR/RTL direction.")
        receipt["beforeDrag"] = [
            "sourceFrame": NSCoder.string(for: source.frame),
            "destinationFrame": NSCoder.string(for: destination.frame),
            "sourceLabel": source.label, "destinationLabel": destination.label
        ]
        try capture(app, "01-matrix-before-native-drag")
        // Same genuine system lift as the existing Matrix choreography; no store or menu move.
        source.press(forDuration: 1.0, thenDragTo: destination)
        let moved = card(sourceID, in: app)
        let scheduled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", schedule), object: moved)
        try require(XCTWaiter.wait(for: [scheduled], timeout: 10) == .completed,
                    "The native Matrix drop must update the source task to Schedule.")
        try require(try uniqueCardID(containing: sourceTitle, in: app) == sourceID,
                    "Dragging must preserve the original task ID and create no duplicate.")
        try require(try uniqueCardID(containing: destinationTitle, in: app) == destinationID,
                    "Dragging onto the destination must preserve that independent task.")
        try require(card(destinationID, in: app).label.contains(schedule),
                    "The destination task must remain in Schedule after the native drop.")
        try checked("nativeDragChangedOnlySourceQuadrant")
        try capture(app, "02-matrix-after-native-drag")
        try verifyCanonicalEditor(sourceID, title: sourceTitle, expectedQuadrant: schedule, in: app)
        try checked("canonicalEditorReadback")

        app.terminate()
        try require(app.wait(for: .notRunning, timeout: 10), "Disk persistence requires an actual app termination.")
        app.launch()
        try requireMatrix(app)
        try require(try uniqueCardID(containing: sourceTitle, in: app) == sourceID,
                    "The moved task must retain the same ID after ordinary relaunch.")
        try require(card(sourceID, in: app).label.contains(schedule),
                    "The new quadrant must reload from the ordinary persistent store.")
        try require(try uniqueCardID(containing: destinationTitle, in: app) == destinationID,
                    "The destination task must remain intact after relaunch.")
        try require(card(destinationID, in: app).label.contains(schedule),
                    "The destination quadrant must also remain Schedule after disk relaunch.")
        try capture(app, "03-matrix-after-disk-relaunch")
        try verifyCanonicalEditor(sourceID, title: sourceTitle, expectedQuadrant: schedule, in: app)
        try checked("sameIDAndQuadrantAfterDiskRelaunch")
    }

    private func requireMatrix(_ app: XCUIApplication) throws {
        let skip = app.buttons[hebrew ? "דילוג" : "Skip"]
        if skip.waitForExistence(timeout: 5) {
            try require(skip.isHittable, "The normal onboarding Skip action is obscured.")
            skip.tap()
            try require(skip.waitForNonExistence(timeout: 10), "Normal onboarding did not dismiss.")
        }
        let field = app.textFields["capture-field"]
        try require(field.waitForExistence(timeout: 30) && field.isEnabled,
                    "The ordinary app did not reach the Matrix capture field.")
        try require(field.wait(for: \.isHittable, toEqual: true, timeout: 10),
                    "The ordinary Matrix capture field is obscured.")
    }

    private func createTask(_ title: String, quadrantTaps: Int, expectedQuadrant: String,
                            in app: XCUIApplication) throws -> String {
        let chip = app.buttons["capture-quadrant-chip"]
        try require(chip.waitForExistence(timeout: 10), "The real capture quadrant control is missing.")
        for _ in 0..<quadrantTaps { chip.tap() }
        try require(chip.label == expectedQuadrant, "The real capture override did not select the intended quadrant.")
        let field = app.textFields["capture-field"]
        field.tap()
        field.typeText(title + "\n")
        let id = try uniqueCardID(containing: title, in: app)
        try require(card(id, in: app).label.contains(expectedQuadrant),
                    "The newly created task must carry its selected canonical quadrant.")
        return id
    }

    private func uniqueCardID(containing title: String, in app: XCUIApplication) throws -> String {
        let matches = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'task-card-' AND label CONTAINS %@", title))
        try require(matches.firstMatch.waitForExistence(timeout: 20), "The ordinary task card is missing.")
        let ids = Set(matches.allElementsBoundByIndex.map(\.identifier))
        try require(ids.count == 1, "A synthetic title must identify exactly one canonical task ID.")
        guard let id = ids.first else { throw Failure.condition("Task ID is unavailable.") }
        return id
    }

    private func card(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func verifyCanonicalEditor(_ identifier: String, title: String,
                                       expectedQuadrant: String, in app: XCUIApplication) throws {
        let task = card(identifier, in: app)
        try require(task.waitForExistence(timeout: 10) && task.isHittable, "The task cannot open its real editor.")
        task.tap()
        let titleField = app.textFields["editor-title"]
        try require(titleField.waitForExistence(timeout: 10), "The canonical editor did not open.")
        try require(titleField.value as? String == title, "The editor opened a different task.")
        let form = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        let quadrant = form.buttons[expectedQuadrant].firstMatch
        try require(quadrant.waitForExistence(timeout: 10) && quadrant.isSelected,
                    "The canonical editor must show Schedule selected without any editing.")
        try capture(app, "editor-" + String(checks.count))
        app.buttons["editor-cancel"].tap()
        try require(titleField.waitForNonExistence(timeout: 10), "The read-only editor inspection did not close.")
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { XCTFail(message); throw Failure.condition(message) }
    }

    private func checked(_ name: String) throws {
        checks.append(name)
        try persist()
    }

    private func persist() throws {
        receipt["checks"] = checks
        let bytes = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: artifacts.appendingPathComponent("matrix-native-persistence.json"), options: .atomic)
    }

    private func capture(_ app: XCUIApplication, _ name: String) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try screenshot.pngRepresentation.write(to: artifacts.appendingPathComponent(name + ".png"), options: .atomic)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-observed-elements"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
