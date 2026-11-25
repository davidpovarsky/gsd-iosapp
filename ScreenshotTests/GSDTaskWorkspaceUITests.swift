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
        let graphTask = app.buttons["task-workspace.open.demo-finance"].firstMatch
        XCTAssertTrue(graphTask.waitForExistence(timeout: 10))
        graphTask.tap()
        XCTAssertTrue(app.textFields["editor-title"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["editor-title"].value as? String,
                       hebrew ? "לקבל אישור ממחלקת הכספים" : "Get finance sign-off")
        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))

        tapMode("table", in: app)
        let completionID = "task-workspace.complete.demo-finance"
        let completion = revealTaskCompletion(completionID, in: app)
        XCTAssertTrue(completion.waitForExistence(timeout: 10))
        XCTAssertEqual(completion.label, hebrew ? "השלמת משימה" : "Complete task")
        completion.tap()
        // Canonical writes update updatedAt, moving this row to the top of the live table.
        // Reacquire its control after the lazy row has moved before asserting the new state.
        let updatedCompletion = revealTaskCompletion(completionID, in: app, searchingUpward: true)
        let reopenedLabel = hebrew ? "פתיחת המשימה מחדש" : "Reopen task"
        let persisted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", reopenedLabel), object: updatedCompletion)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 10), .completed)

        tapMode("board", in: app)
        let boardCompletion = revealTaskCompletion(completionID, in: app)
        XCTAssertTrue(boardCompletion.waitForExistence(timeout: 10))
        XCTAssertEqual(boardCompletion.label, reopenedLabel)
        boardCompletion.tap()
        let reopenedOnBoard = revealTaskCompletion(completionID, in: app, searchingUpward: true)
        let completeLabel = hebrew ? "השלמת משימה" : "Complete task"
        let reopened = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", completeLabel), object: reopenedOnBoard)
        XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 10), .completed)
        reopenedOnBoard.tap()
        let completedOnBoard = revealTaskCompletion(completionID, in: app, searchingUpward: true)
        let completedAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", reopenedLabel), object: completedOnBoard)
        XCTAssertEqual(XCTWaiter.wait(for: [completedAgain], timeout: 10), .completed)
        if UIDevice.current.userInterfaceIdiom == .pad {
            exerciseNativeBoardMove(in: app)
        }
        capture("02-board-after-completion")

        tapMode("timeline", in: app)
        let chart = app.descendants(matching: .any).matching(identifier: "task-workspace.timeline.chart").firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10))
        capture("03-timeline")
        clearTimelineDate(for: "demo-finance", in: app)

        tapMode("network", in: app)
        let network = app.descendants(matching: .any).matching(identifier: "task-workspace.network.canvas").firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 10))
        capture("04-network")
        let open = app.buttons["task-workspace.open.demo-finance"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        if UIDevice.current.userInterfaceIdiom == .pad {
            exerciseNativeNetworkPanAndFit(node: open, canvas: network, in: app)
        }
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
        let date = app.buttons["task-workspace.date.demo-finance"].firstMatch
        XCTAssertEqual(date.label, hebrew ? "קביעת תאריך" : "Set date")
        moveTaskToDelegate(in: app)
        exerciseDependencies(in: app)
    }

    private func exerciseNativeBoardMove(in app: XCUIApplication) {
        _ = revealTaskCompletion("task-workspace.complete.demo-finance", in: app)
        _ = revealTaskCompletion("task-workspace.complete.demo-physical", in: app)
        let source = app.buttons["task-workspace.open.demo-finance"].firstMatch
        let destination = app.buttons["task-workspace.open.demo-physical"].firstMatch
        XCTAssertTrue(source.exists && source.isHittable)
        XCTAssertTrue(destination.exists && destination.isHittable)
        XCTAssertTrue(app.frame.contains(source.frame) && app.frame.contains(destination.frame))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "native-board-drag-observed-elements"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture("02-before-native-board-drop")
        // AdvancedKanban uses its original DragGesture. Both endpoints are the
        // currently visible native task controls, so this works in LTR and RTL.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo:
                destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        tapMode("table", in: app)
        _ = revealTaskCompletion("task-workspace.complete.demo-finance", in: app)
        let lane = app.buttons["task-workspace.lane.demo-finance"].firstMatch
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", hebrew ? "לתכנן" : "Schedule"), object: lane)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed,
                       "A native cross-column drop must persist through the canonical task store")
        capture("02-table-after-native-board-drop")
        tapMode("board", in: app)
    }

    private func exerciseNativeNetworkPanAndFit(node: XCUIElement, canvas: XCUIElement,
                                                in app: XCUIApplication) {
        let fit = app.buttons["task-workspace.network.fit"].firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 10))
        fit.tap()
        let bounds = canvas.frame.intersection(app.frame)
        let occupied = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                                        "task-workspace.open."))
            .allElementsBoundByIndex.map { $0.frame } + [fit.frame]
        let before = node.frame
        XCTAssertTrue(node.isHittable && bounds.contains(before))
        let dx: CGFloat = before.midX < bounds.midX ? 80 : -80
        let dy: CGFloat = before.midY < bounds.midY ? 56 : -56
        let fractions: [CGFloat] = [0.15, 0.5, 0.85]
        let points = fractions.flatMap { x in
            fractions.map { y in CGPoint(x: bounds.minX + bounds.width * x,
                                        y: bounds.minY + bounds.height * y) }
        }
        guard let start = points.first(where: { point in
            bounds.contains(CGPoint(x: point.x + dx, y: point.y + dy)) &&
                !occupied.contains(where: { $0.insetBy(dx: -8, dy: -8).contains(point) })
        }) else {
            XCTFail("The visible network must expose background space for panning")
            return
        }
        let end = CGPoint(x: start.x + dx, y: start.y + dy)
        let observation = XCTAttachment(string: "canvas=\(bounds) node=\(before) pan=\(start)->\(end)\n" + app.debugDescription)
        observation.name = "native-network-pan-observed-elements"
        observation.lifetime = .keepAlways
        add(observation)
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: start.x - app.frame.minX, dy: start.y - app.frame.minY))
            .press(forDuration: 0.05, thenDragTo:
                origin.withOffset(CGVector(dx: end.x - app.frame.minX, dy: end.y - app.frame.minY)))
        // Native gestures and taps wait for the application to idle. Read their
        // completed layout directly; nested AX queries in a block-predicate wait
        // can stall its polling loop before any physical frame is recorded.
        let afterPan = node.frame
        let panMeasurement = XCTAttachment(string: "before=\(before) afterPan=\(afterPan)")
        panMeasurement.name = "native-network-after-pan-frame"
        panMeasurement.lifetime = .keepAlways
        add(panMeasurement)
        let panX = afterPan.midX - before.midX
        let panY = afterPan.midY - before.midY
        XCTAssertGreaterThan(panX * panX + panY * panY, 24 * 24,
                             "A native network pan must move the rendered task control")
        capture("04-network-after-native-pan")
        fit.tap()
        let afterFit = node.frame
        let fitMeasurement = XCTAttachment(string: "before=\(before) afterPan=\(afterPan) afterFit=\(afterFit)")
        fitMeasurement.name = "native-network-after-fit-frame"
        fitMeasurement.lifetime = .keepAlways
        add(fitMeasurement)
        let fitX = afterFit.midX - before.midX
        let fitY = afterFit.midY - before.midY
        XCTAssertLessThan(fitX * fitX + fitY * fitY, 24 * 24,
                          "Fit must recover the task position after native panning")
        XCTAssertTrue(node.isHittable && bounds.contains(afterFit))
        capture("04-network-after-fit")
    }

    private func clearTimelineDate(for id: String, in app: XCUIApplication) {
        let inspect = app.buttons["task-workspace.timeline.inspect.\(id)"].firstMatch
        XCTAssertTrue(inspect.waitForExistence(timeout: 10))
        inspect.tap()
        let due = app.buttons["task-workspace.timeline.due.\(id)"].firstMatch
        XCTAssertTrue(due.waitForExistence(timeout: 10))
        XCTAssertTrue(due.isHittable, "Timeline task actions must appear in the visible viewport")
        due.tap()
        let toggle = app.switches["task-workspace.date.toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()
        app.buttons["task-workspace.date.save"].tap()
        XCTAssertTrue(due.waitForExistence(timeout: 10))
        app.buttons["task-workspace.timeline.close-actions"].tap()
    }

    private func moveTaskToDelegate(in app: XCUIApplication) {
        let lane = app.buttons["task-workspace.lane.demo-finance"].firstMatch
        let destination = hebrew ? "להעביר לאחרים" : "Delegate"
        XCTAssertTrue(lane.waitForExistence(timeout: 10))
        lane.tap()
        app.buttons["task-workspace.lane-choice.demo-finance.urgent-not-important"].firstMatch.tap()
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", destination), object: lane)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed)
        capture("07-real-quadrant-change")
    }

    private func exerciseDependencies(in app: XCUIApplication) {
        app.buttons["task-workspace.options"].tap()
        app.buttons["task-workspace.connections"].tap()
        let remove = app.buttons["task-workspace.connection.remove.demo-finance.demo-deck"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: remove)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        waitForConnectionWrite(in: app)

        if UIDevice.current.userInterfaceIdiom == .pad {
            app.buttons["task-workspace.connection.done"].tap()
            exerciseNativeFlowConnection(in: app)
            app.buttons["task-workspace.options"].tap()
            app.buttons["task-workspace.connections"].tap()
            XCTAssertTrue(remove.waitForExistence(timeout: 10),
                          "A native connector drag must persist the exact canonical prerequisite edge")
            capture("08-flow-canonical-dependency-readback")
            remove.tap()
            let removedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: remove)
            XCTAssertEqual(XCTWaiter.wait(for: [removedAgain], timeout: 10), .completed)
            waitForConnectionWrite(in: app)
        }

        chooseConnection("prerequisite", title: hebrew ? "לקבל אישור ממחלקת הכספים" : "Get finance sign-off", in: app)
        chooseConnection("dependent", title: hebrew ? "לסיים את המצגת לרבעון השלישי" : "Finish the Q3 board deck", in: app)
        let add = app.buttons["task-workspace.connection.add"]
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        waitForConnectionWrite(in: app)
        XCTAssertFalse(add.isEnabled, "An existing connection must not be added twice")

        chooseConnection("prerequisite", title: hebrew ? "לסיים את המצגת לרבעון השלישי" : "Finish the Q3 board deck", in: app)
        chooseConnection("dependent", title: hebrew ? "לקבל אישור ממחלקת הכספים" : "Get finance sign-off", in: app)
        XCTAssertFalse(add.isEnabled, "The reverse edge must be rejected because it creates a dependency cycle")
        capture("08-dependencies-cycle-rejected")
        app.buttons["task-workspace.connection.done"].tap()
    }

    private func exerciseNativeFlowConnection(in app: XCUIApplication) {
        tapMode("graph", in: app)
        let fit = app.buttons["task-workspace.graph.fit"].firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 10))
        fit.tap()
        let source = app.descendants(matching: .any)
            .matching(identifier: "task-workspace.graph.handle.out.demo-finance").firstMatch
        let destination = app.descendants(matching: .any)
            .matching(identifier: "task-workspace.graph.handle.in.demo-deck").firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        XCTAssertTrue(destination.waitForExistence(timeout: 10))
        XCTAssertTrue(source.frame.width > 0 && source.frame.height > 0)
        XCTAssertTrue(destination.frame.width > 0 && destination.frame.height > 0)
        XCTAssertTrue(app.frame.contains(source.frame) && app.frame.contains(destination.frame))
        let observation = XCTAttachment(string: app.debugDescription)
        observation.name = "native-flow-connector-observed-elements"
        observation.lifetime = .keepAlways
        add(observation)
        capture("08-flow-before-native-connection")
        // These descriptors are measured from the original SwiftFlow Handles.
        // Their centers hit its existing minimumDistance: 0 connection gesture.
        source.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo:
                destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        capture("08-flow-after-native-connection")
    }

    private func waitForConnectionWrite(in app: XCUIApplication) {
        let done = app.buttons["task-workspace.connection.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: done)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed,
                       "Dependency validation must run after the canonical write has finished")
    }

    private func chooseConnection(_ field: String, title: String, in app: XCUIApplication) {
        let picker = app.buttons["task-workspace.connection.\(field)"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 10))
        choice.tap()
    }

    private func revealTaskCompletion(_ identifier: String, in app: XCUIApplication,
                                      searchingUpward: Bool = false) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        let title = app.buttons[identifier.replacingOccurrences(of: ".complete.", with: ".open.")].firstMatch
        let taskButtons = NSPredicate(format: "identifier BEGINSWITH %@", "task-workspace.complete.")
        // Compact tables and Kanban columns materialize their rows lazily.
        // Reveal the real row using its scroll container before asking for a hit point.
        for _ in 0..<14 {
            var candidates: [XCUIElement] = []
            let tableID = "task-workspace.table"
            let nativeTables = app.scrollViews.matching(identifier: tableID).allElementsBoundByIndex
                + app.tables.matching(identifier: tableID).allElementsBoundByIndex
                + app.collectionViews.matching(identifier: tableID).allElementsBoundByIndex
            if !nativeTables.isEmpty {
                // The live row can disappear between exists and the ancestor query.
                // Bind compact/regular tables by their own ID, independent of row lifetime.
                candidates = nativeTables
            } else if button.exists {
                candidates = app.scrollViews.containing(.button, identifier: identifier).allElementsBoundByIndex
                    + app.tables.containing(.button, identifier: identifier).allElementsBoundByIndex
                    + app.collectionViews.containing(.button, identifier: identifier).allElementsBoundByIndex
            }
            if candidates.isEmpty {
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
            } else if searchingUpward {
                container.swipeDown()
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
