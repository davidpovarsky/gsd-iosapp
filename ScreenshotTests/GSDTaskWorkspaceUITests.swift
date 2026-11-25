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
        let completion = revealTaskCompletion(completionID, in: app)
        XCTAssertTrue(completion.waitForExistence(timeout: 10))
        XCTAssertEqual(completion.label, hebrew ? "השלמת משימה" : "Complete task")
        completion.tap()
        let reopenedLabel = hebrew ? "פתיחת המשימה מחדש" : "Reopen task"
        let persisted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", reopenedLabel), object: completion)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 10), .completed)

        tapMode("board", in: app)
        let boardCompletion = revealTaskCompletion(completionID, in: app)
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
        XCTAssertEqual(revealTaskCompletion(completionID, in: app).label, reopenedLabel)
        capture("06-table-persisted-state")
    }

    private func revealTaskCompletion(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        let title = app.buttons[identifier.replacingOccurrences(of: ".complete.", with: ".open.")].firstMatch
        let taskButtons = NSPredicate(format: "identifier BEGINSWITH %@", "task-workspace.complete.")
        // Compact tables and Kanban columns materialize their rows lazily.
        // Reveal the real row using its scroll container before asking for a hit point.
        for _ in 0..<14 {
            let candidates: [XCUIElement]
            if button.exists {
                candidates = app.scrollViews.containing(.button, identifier: identifier).allElementsBoundByIndex
                    + app.tables.containing(.button, identifier: identifier).allElementsBoundByIndex
                    + app.collectionViews.containing(.button, identifier: identifier).allElementsBoundByIndex
            } else {
                candidates = app.scrollViews.containing(taskButtons).allElementsBoundByIndex
                    + app.tables.containing(taskButtons).allElementsBoundByIndex
                    + app.collectionViews.containing(taskButtons).allElementsBoundByIndex
            }
            let visible = candidates.filter {
                let viewport = taskViewport($0, in: app)
                return viewport.height > 100 && viewport.width > 40
            }
            // Prefer the actual vertical task column over its horizontal ancestor.
            guard let container = visible.min(by: {
                let a = taskViewport($0, in: app), b = taskViewport($1, in: app)
                return a.width * a.height < b.width * b.height
            }) else {
                XCTFail("A visible task scroll container is required.")
                return button
            }
            let viewport = taskViewport(container, in: app).insetBy(dx: 2, dy: 6)
            if button.exists && !button.frame.isEmpty {
                let frame = title.exists && !title.frame.isEmpty ? button.frame.union(title.frame) : button.frame
                if viewport.contains(frame) && button.isHittable { return button }
                if frame.minX < viewport.minX {
                    container.swipeRight()
                } else if frame.maxX > viewport.maxX {
                    container.swipeLeft()
                } else if frame.minY < viewport.minY {
                    container.swipeDown()
                } else {
                    container.swipeUp()
                }
            } else {
                container.swipeUp()
            }
        }
        XCTFail("The canonical task completion control must be visible after bounded scrolling: \(identifier)")
        return button
    }

    private func taskViewport(_ container: XCUIElement, in app: XCUIApplication) -> CGRect {
        var viewport = container.frame.intersection(app.frame)
        // The floating native compact tab bar can cover the bottom of a scroll view.
        for tabBar in app.tabBars.allElementsBoundByIndex where tabBar.frame.intersects(viewport) {
            viewport.size.height = max(0, min(viewport.maxY, tabBar.frame.minY) - viewport.minY)
        }
        return viewport
    }

    private func tapMode(_ mode: String, in app: XCUIApplication) {
        let identifier = "task-workspace.tab.\(mode)"
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        // XCTest can throw while asking isHittable for a wholly clipped button.
        // The actual horizontal strip is the shortest visible scroll ancestor;
        // use its current geometry before asking XCTest for an activation point.
        let strips = app.scrollViews.containing(.button, identifier: identifier)
            .allElementsBoundByIndex.filter { !$0.frame.isEmpty }
        guard let strip = strips.min(by: { $0.frame.height < $1.frame.height }) else {
            XCTFail("The task presentation strip is missing.")
            return
        }
        for _ in 0..<4 {
            let viewport = strip.frame.intersection(app.frame)
            let frame = button.frame
            if !frame.isEmpty && viewport.contains(frame) { break }
            if frame.midX > viewport.midX {
                strip.swipeLeft()
            } else {
                strip.swipeRight()
            }
        }
        let viewport = strip.frame.intersection(app.frame)
        guard !button.frame.isEmpty && viewport.contains(button.frame) else {
            XCTFail("Mode must be inside the visible strip before hit-testing: \(mode)")
            return
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
