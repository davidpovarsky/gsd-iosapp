import UIKit
import XCTest

/// Isolated fixture store, real SwiftUI views and canonical TaskStore writes.
/// The fixture store is in memory; persistence/reopen coverage belongs to the package tests.
@MainActor
final class GSDTaskWorkspaceUITests: XCTestCase {
    private var hebrew: Bool { ProcessInfo.processInfo.environment["GSD_TEST_LANGUAGE"] == "he" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    func testWorkspaceCompletionPropagatesAcrossViewsAndOpensCanonicalEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed", "-AppleLanguages", hebrew ? "(he)" : "(en)",
            "-AppleLocale", hebrew ? "he_IL" : "en_US"
        ]
        app.launch()
        let tab = app.tabBars.buttons[hebrew ? "מרחב משימות" : "Workspace"]
        let sidebar = app.descendants(matching: .any).matching(identifier: "gsd.sidebar.workspace").firstMatch
        let entry = tab.exists ? tab : sidebar
        XCTAssertTrue(entry.waitForExistence(timeout: 20))
        entry.tap()
        let workspace = app.descendants(matching: .any).matching(identifier: "task-workspace").firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 15))
        capture("01-live-graph")

        tapMode("table", in: app)
        let completionID = "task-workspace.complete.demo-finance"
        let completion = app.buttons[completionID].firstMatch
        XCTAssertTrue(completion.waitForExistence(timeout: 10))
        XCTAssertEqual(completion.label, hebrew ? "השלמת משימה" : "Complete task")
        completion.tap()
        let reopenedLabel = hebrew ? "פתיחת המשימה מחדש" : "Reopen task"
        let persisted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", reopenedLabel), object: completion)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 10), .completed)

        tapMode("board", in: app)
        let boardCompletion = app.buttons[completionID].firstMatch
        XCTAssertTrue(boardCompletion.waitForExistence(timeout: 10))
        XCTAssertEqual(boardCompletion.label, reopenedLabel)
        capture("02-board-after-completion")

        tapMode("timeline", in: app)
        let chart = app.descendants(matching: .any).matching(identifier: "task-workspace.timeline.chart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        capture("03-timeline")

        tapMode("network", in: app)
        let network = app.descendants(matching: .any).matching(identifier: "task-workspace.network.canvas").firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 10))
        capture("04-network")
        let taskTitle = hebrew ? "לקבל אישור ממחלקת הכספים" : "Get finance sign-off"
        let open = app.buttons[taskTitle].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let title = app.textFields["editor-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String,
                       hebrew ? "לקבל אישור ממחלקת הכספים" : "Get finance sign-off")
        capture("05-canonical-editor")
        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        tapMode("table", in: app)
        XCTAssertEqual(app.buttons[completionID].firstMatch.label, reopenedLabel)
        capture("06-table-persisted-state")
    }

    private func tapMode(_ mode: String, in app: XCUIApplication) {
        let button = app.buttons["task-workspace.tab.\(mode)"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        if !button.isHittable {
            // The native mode strip scrolls horizontally. XCTest does not auto-scroll
            // its offscreen buttons; use their current frames to work in both LTR and RTL.
            let strip = app.scrollViews.containing(.button, identifier: "task-workspace.tab.\(mode)").firstMatch
            XCTAssertTrue(strip.exists)
            for _ in 0..<4 {
                if button.isHittable { break }
                if button.frame.midX > strip.frame.midX {
                    strip.swipeLeft()
                } else {
                    strip.swipeRight()
                }
            }
        }
        XCTAssertTrue(button.isHittable, "Mode must be visible before tapping: \(mode)")
        button.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(hebrew ? "he" : "en")-workspace-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
