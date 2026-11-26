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
        let graphObservation = XCTAttachment(string:
            "Finance native control frame: \(graphTask.frame)\n\(app.debugDescription)")
        graphObservation.name = "native-graph-open-observed-elements"
        graphObservation.lifetime = .keepAlways
        add(graphObservation)
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
        try exerciseBoardCollapseRestore(in: app)
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
        exerciseNativeBoardMove(in: app)
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
        exerciseNativeNetworkPanAndFit(node: open, canvas: network, in: app)
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
        try exerciseOrdinaryBoardScrollWithoutReordering(in: app)
    }

    private struct BoardCardObservation {
        let identifier: String
        let frame: CGRect
        let value: String
    }

    private func nativeBoardCards(in column: XCUIElement) throws -> [BoardCardObservation] {
        let snapshot: any XCUIElementSnapshot = try column.snapshot()
        var pending = snapshot.children
        var cards: [BoardCardObservation] = []
        while let item = pending.popLast() {
            if item.identifier.hasPrefix("task-workspace.board.card.") {
                if !item.frame.isEmpty {
                    cards.append(.init(identifier: item.identifier, frame: item.frame,
                                       value: item.value as? String ?? ""))
                }
                // This is the real outer draggable card, not its inner buttons.
                continue
            }
            pending.append(contentsOf: item.children)
        }
        XCTAssertEqual(Set(cards.map(\.identifier)).count, cards.count,
                       "Native Board card identities must be unique")
        return cards.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func exerciseNativeBoardMove(in app: XCUIApplication) {
        _ = revealTaskCompletion("task-workspace.complete.demo-finance", in: app)
        let source = app.descendants(matching: .any)
            .matching(identifier: "task-workspace.board.card.demo-finance").firstMatch
        let sourceColumn = app.scrollViews["task-workspace.board.column.urgent-important"].firstMatch
        let destination = app.scrollViews["task-workspace.board.column.not-urgent-important"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10) && sourceColumn.exists && destination.exists)
        let sourceVisible = source.frame.intersection(taskViewport(sourceColumn, in: app))
        let destinationVisible = taskViewport(destination, in: app).insetBy(dx: 4, dy: 12)
        XCTAssertGreaterThanOrEqual(sourceVisible.width, 44)
        XCTAssertGreaterThanOrEqual(sourceVisible.height, 44)
        XCTAssertGreaterThanOrEqual(destinationVisible.width, 44,
                                    "An actual part of the adjacent column must be visible on phone and tablet")
        XCTAssertGreaterThanOrEqual(destinationVisible.height, 44)
        let startPoint = CGPoint(x: sourceVisible.midX, y: sourceVisible.midY)
        let endPoint = CGPoint(x: destinationVisible.midX, y: destinationVisible.midY)
        let observation = XCTAttachment(string:
            "source=\(source.frame) sourceVisible=\(sourceVisible) "
            + "destination=\(destination.frame) destinationVisible=\(destinationVisible) "
            + "displayLift=\(startPoint)->\(endPoint)\n" + app.debugDescription)
        observation.name = "native-board-system-lift-observed-elements"
        observation.lifetime = .keepAlways
        add(observation)
        capture("02-before-native-board-drop")
        guard let start = measuredNativeCoordinate(on: source, at: startPoint,
            observationName: "native-board-lift-start"),
              let end = measuredNativeCoordinate(on: destination, at: endPoint,
                observationName: "native-board-lift-end") else { return }
        // iOS Transferable drag begins with a genuine system lift. A quick
        // vertical gesture remains ordinary scrolling and is verified separately.
        start.press(forDuration: 1.2, thenDragTo: end)
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

    private func exerciseBoardCollapseRestore(in app: XCUIApplication) throws {
        let column = app.scrollViews["task-workspace.board.column.urgent-important"].firstMatch
        let controlID = "task-workspace.board.collapse.urgent-important"
        XCTAssertTrue(column.waitForExistence(timeout: 10))
        let beforeFrame = column.frame
        let viewport = taskViewport(column, in: app)
        let before = try nativeBoardCards(in: column).filter { viewport.contains($0.frame) }
        XCTAssertFalse(before.isEmpty)
        let collapse = app.buttons[controlID].firstMatch
        XCTAssertTrue(collapse.isHittable)
        collapse.tap()
        XCTAssertTrue(column.waitForNonExistence(timeout: 5))
        let expand = app.buttons[controlID].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        XCTAssertEqual(expand.label, hebrew ? "הרחבת העמודה" : "Expand column")
        XCTAssertTrue(app.frame.contains(expand.frame) && expand.isHittable)
        XCTAssertGreaterThanOrEqual(expand.frame.width, 44)
        XCTAssertGreaterThanOrEqual(expand.frame.height, 44)
        capture("02-board-collapsed-with-visible-expand")
        expand.tap()
        XCTAssertTrue(column.waitForExistence(timeout: 5))
        XCTAssertEqual(column.frame.width, beforeFrame.width, accuracy: 1)
        let visibleIDs = Set(before.map(\.identifier))
        let after = try nativeBoardCards(in: column).filter { visibleIDs.contains($0.identifier) }
        XCTAssertEqual(after.map(\.identifier), before.map(\.identifier),
                       "Restoring the column must preserve the displayed task order")
        XCTAssertEqual(after.map(\.value), before.map(\.value))
        for restored in after {
            XCTAssertTrue(taskViewport(column, in: app).contains(restored.frame))
        }
        let first = try XCTUnwrap(after.first)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: first.identifier).firstMatch.isHittable)
    }

    private func filterTableForTask(named name: String, in app: XCUIApplication) {
        let search = app.textFields["task-workspace.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let clear = app.buttons[hebrew ? "ניקוי חיפוש" : "Clear search"].firstMatch
        if clear.exists { clear.tap() }
        search.tap()
        search.typeText(name + "\n")
        XCTAssertEqual(search.value as? String, name)
    }

    private func clearWorkspaceSearch(in app: XCUIApplication) {
        let clear = app.buttons[hebrew ? "ניקוי חיפוש" : "Clear search"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5) && clear.isHittable)
        clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))
    }

    private func exerciseOrdinaryBoardScrollWithoutReordering(in app: XCUIApplication) throws {
        // Grow the fixture only until the actual native column has enough content
        // for the short swipe, after all original five-view and dependency captures.
        let doName = hebrew ? "לביצוע מיידי" : "Do First"
        var createdIDs: [String] = []
        var before: [BoardCardObservation] = []
        var viewport = CGRect.zero
        tapMode("board", in: app)
        let column = app.scrollViews["task-workspace.board.column.urgent-important"].firstMatch
        while true {
            XCTAssertTrue(column.waitForExistence(timeout: 10))
            viewport = taskViewport(column, in: app).insetBy(dx: 4, dy: 12)
            before = try nativeBoardCards(in: column)
            let visible = before.filter {
                let area = $0.frame.intersection(viewport)
                return !area.isNull && area.width >= 44 && area.height >= 44
            }
            let lowestEdge = before.map(\.frame.maxY).max() ?? viewport.minY
            let overflow = lowestEdge - viewport.maxY
            let observation = XCTAttachment(string:
                "created=\(createdIDs.count) viewport=\(viewport) measuredOverflow=\(overflow)\n"
                + before.map { "\($0.identifier) \($0.frame) [\($0.value)]" }.joined(separator: "\n"))
            observation.name = "native-board-measured-fixture-capacity-\(createdIDs.count)"
            observation.lifetime = .keepAlways
            add(observation)
            if visible.count >= 2 && overflow >= 120 { break }
            guard createdIDs.count < 12 else {
                XCTFail("Twelve real additional tasks did not produce measured native column overflow")
                return
            }
            tapMode("table", in: app)
            app.buttons["task-workspace.create"].tap()
            let title = app.textFields["editor-title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
            let doChoice = editor.buttons.matching(
                NSPredicate(format: "label CONTAINS %@", doName)).firstMatch
            XCTAssertTrue(doChoice.waitForExistence(timeout: 5) && doChoice.isHittable)
            doChoice.tap()
            XCTAssertTrue(doChoice.isSelected)
            let name = String(format: "Board ordinary scroll acceptance task %02d", createdIDs.count + 1)
            title.tap()
            title.typeText(name)
            let save = app.buttons["editor-save"]
            XCTAssertTrue(save.isEnabled && save.isHittable)
            save.tap()
            XCTAssertTrue(title.waitForNonExistence(timeout: 10))
            // Search makes the new canonical row reachable even when its normal
            // sorted position has not yet materialized in the lazy Table.
            filterTableForTask(named: name, in: app)
            let created = app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "task-workspace.open.", name)).firstMatch
            XCTAssertTrue(created.waitForExistence(timeout: 10),
                          "The real editor must publish the actual canonical task")
            XCTAssertEqual(created.label, name)
            let id = String(created.identifier.dropFirst("task-workspace.open.".count))
            XCTAssertFalse(id.isEmpty)
            createdIDs.append(id)
            XCTAssertEqual(Set(createdIDs).count, createdIDs.count,
                           "Every editor save must create one distinct real task")
            XCTAssertEqual(app.buttons["task-workspace.lane." + id].firstMatch.label, doName)
            clearWorkspaceSearch(in: app)
            tapMode("board", in: app)
        }
        let visible = before.filter { viewport.contains($0.frame) }
        guard let touched = visible.min(by: {
            abs($0.frame.midY - viewport.midY) < abs($1.frame.midY - viewport.midY)
        }) else {
            XCTFail("The overflowing column must contain a fully visible real card")
            return
        }
        let card = app.descendants(matching: .any).matching(identifier: touched.identifier).firstMatch
        XCTAssertTrue(card.isHittable)
        let touchedID = String(touched.identifier.dropFirst("task-workspace.board.card.".count))
        let touchedTitle = app.buttons["task-workspace.open." + touchedID].firstMatch.label
        XCTAssertFalse(touchedTitle.isEmpty)
        let previousCompletion = app.buttons["task-workspace.complete." + touchedID].firstMatch.label
        XCTAssertTrue([hebrew ? "השלמת משימה" : "Complete task",
                       hebrew ? "פתיחת המשימה מחדש" : "Reopen task"].contains(previousCompletion))
        let startPoint = CGPoint(x: touched.frame.midX, y: touched.frame.midY)
        let distance = min(CGFloat(120), startPoint.y - viewport.minY - 20)
        XCTAssertGreaterThan(distance, 24)
        let endPoint = CGPoint(x: startPoint.x, y: startPoint.y - distance)
        guard let start = measuredNativeCoordinate(on: card, at: startPoint,
            observationName: "native-board-ordinary-scroll-start"),
              let end = measuredNativeCoordinate(on: card, at: endPoint,
                observationName: "native-board-ordinary-scroll-end") else { return }
        let beforeAttachment = XCTAttachment(string: "column=\(column.frame) viewport=\(viewport) "
            + "touched=\(touched.identifier) displaySwipe=\(startPoint)->\(endPoint)\n"
            + before.map { "\($0.identifier) \($0.frame) [\($0.value)]" }.joined(separator: "\n"))
        beforeAttachment.name = "native-board-ordinary-scroll-before"
        beforeAttachment.lifetime = .keepAlways
        add(beforeAttachment)
        capture("08-board-before-ordinary-scroll")
        // Pause under touch before lift-off so this deliberately short scroll
        // stays measurable instead of flinging the touched card offscreen.
        start.press(forDuration: 0.05, thenDragTo: end,
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        let after = try nativeBoardCards(in: column)
        func physicallyVisible(_ observation: BoardCardObservation) -> Bool {
            let area = observation.frame.intersection(viewport)
            return !area.isNull && area.width >= 44 && area.height >= 44
        }
        let afterIDs = Set(after.filter(physicallyVisible).map(\.identifier))
        let common = before.filter { physicallyVisible($0) && afterIDs.contains($0.identifier) }
        let afterAttachment = XCTAttachment(string:
            after.map { "\($0.identifier) \($0.frame) [\($0.value)]" }.joined(separator: "\n"))
        afterAttachment.name = "native-board-ordinary-scroll-after"
        afterAttachment.lifetime = .keepAlways
        add(afterAttachment)
        XCTAssertGreaterThanOrEqual(common.count, 2, "Scrolling must move multiple physically visible cards")
        XCTAssertTrue(common.contains { $0.identifier == touched.identifier })
        let commonIDs = Set(common.map(\.identifier))
        XCTAssertEqual(before.filter { commonIDs.contains($0.identifier) }.map(\.identifier),
                       after.filter { commonIDs.contains($0.identifier) }.map(\.identifier),
                       "Ordinary card-centered scrolling must preserve card order")
        for previous in common {
            let current = try XCTUnwrap(after.first { $0.identifier == previous.identifier })
            XCTAssertLessThan(current.frame.minY - previous.frame.minY, -24,
                              "The column content, including the touched card, must physically scroll upward")
            XCTAssertEqual(current.frame.midX, previous.frame.midX, accuracy: 2)
            XCTAssertFalse(previous.value.isEmpty, "The native card must expose its lane and position")
            XCTAssertEqual(current.value, previous.value, "Scrolling must preserve native lane and position")
        }
        capture("08-board-after-ordinary-scroll")
        tapMode("table", in: app)
        filterTableForTask(named: touchedTitle, in: app)
        let completion = revealTaskCompletion("task-workspace.complete." + touchedID, in: app)
        XCTAssertEqual(app.buttons["task-workspace.lane." + touchedID].firstMatch.label, doName)
        XCTAssertEqual(completion.label, previousCompletion,
                       "Ordinary scrolling must preserve the touched task's canonical completion state")
        capture("08-board-scroll-canonical-readback")
        clearWorkspaceSearch(in: app)
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
        // A SwiftUI Form exposes its row and the nested native UISwitch. Require
        // that actual control and observe its geometry before the native touch.
        let dateSwitch = toggle.switches.firstMatch
        XCTAssertTrue(dateSwitch.waitForExistence(timeout: 5))
        let rowFrame = toggle.frame
        let switchFrame = dateSwitch.frame
        XCTAssertTrue(rowFrame.contains(switchFrame) && app.frame.contains(switchFrame))
        XCTAssertTrue(dateSwitch.isHittable)
        XCTAssertEqual(dateSwitch.value as? String, "1")
        let before = XCTAttachment(string:
            "row=\(rowFrame) switch=\(switchFrame) app=\(app.frame)\n\(app.debugDescription)")
        before.name = "native-date-before-toggle-observed-elements"
        before.lifetime = .keepAlways
        add(before)
        capture("03-date-before-toggle")
        // Use the observed native center and retain the geometry and bounded
        // state transition together; this makes no assumption about tap timing.
        dateSwitch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let disabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
        let result = XCTWaiter.wait(for: [disabled], timeout: 5)
        let after = XCTAttachment(string:
            "rowValue=\(String(describing: toggle.value)) switchValue=\(String(describing: dateSwitch.value))\n"
            + app.debugDescription)
        after.name = "native-date-after-toggle-observed-elements"
        after.lifetime = .keepAlways
        add(after)
        capture("03-date-after-toggle")
        XCTAssertEqual(result, .completed, "The date must be disabled before saving")
        XCTAssertEqual(dateSwitch.value as? String, "0")
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
        // These descriptors are measured from the rendered SwiftFlow handles.
        // Their centers hit the adapter's native connector layer; the caller
        // verifies the resulting edge through the canonical connection editor.
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
            let nativeColumns = visible.filter {
                $0.identifier.hasPrefix("task-workspace.board.column.")
            }
            let focusedNativeColumn = nativeColumns.max(by: {
                let a = taskViewport($0, in: app), b = taskViewport($1, in: app)
                return a.width * a.height < b.width * b.height
            })
            // Named native columns remain resolvable while lazy task rows are absent.
            guard let container = focusedNativeColumn ?? visible.min(by: {
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
                    scrollTaskContainer(container, swipingUp: false, in: app)
                } else {
                    scrollTaskContainer(container, swipingUp: true, in: app)
                }
            } else if searchingUpward {
                scrollTaskContainer(container, swipingUp: false, in: app)
            } else {
                scrollTaskContainer(container, swipingUp: true, in: app)
            }
        }
        let failure = XCTAttachment(string: app.debugDescription)
        failure.name = "native-task-reveal-failure"
        failure.lifetime = .keepAlways
        add(failure)
        capture("task-reveal-failure")
        XCTFail("The canonical task completion control must be visible after bounded scrolling: \(identifier)")
        return button
    }

    private func scrollTaskContainer(_ container: XCUIElement, swipingUp: Bool,
                                     in app: XCUIApplication) {
        let board = app.scrollViews["task-workspace.board"].firstMatch
        guard board.exists else {
            if swipingUp { container.swipeUp() } else { container.swipeDown() }
            return
        }
        XCTAssertTrue(container.identifier.hasPrefix("task-workspace.board.column."),
                      "Board scrolling must target its actual native vertical column")
        let viewport = taskViewport(container, in: app).insetBy(dx: 4, dy: 12)
        guard let cards = try? nativeBoardCards(in: container),
              let observed = cards.filter({ viewport.contains($0.frame) }).min(by: {
                  abs($0.frame.midY - viewport.midY) < abs($1.frame.midY - viewport.midY)
              }) else {
            XCTFail("An actual visible native Board card is required for ordinary scrolling")
            return
        }
        let card = app.descendants(matching: .any).matching(identifier: observed.identifier).firstMatch
        let point = CGPoint(x: observed.frame.midX, y: observed.frame.midY)
        let available = swipingUp ? point.y - viewport.minY - 20 : viewport.maxY - point.y - 20
        let distance = min(CGFloat(120), available)
        XCTAssertGreaterThan(distance, 24)
        let endPoint = CGPoint(x: point.x, y: point.y + (swipingUp ? -distance : distance))
        guard let start = measuredNativeCoordinate(on: card, at: point,
            observationName: "native-board-reveal-scroll-start"),
              let end = measuredNativeCoordinate(on: card, at: endPoint,
                observationName: "native-board-reveal-scroll-end") else { return }
        let observation = XCTAttachment(string: "column=\(container.frame) viewport=\(viewport) "
            + "card=\(observed.identifier) frame=\(observed.frame) displaySwipe=\(point)->\(endPoint)")
        observation.name = "native-board-card-centered-reveal"
        observation.lifetime = .keepAlways
        add(observation)
        start.press(forDuration: 0.05, thenDragTo: end)
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
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        let captureName = "\(hebrew ? "he" : "en")-workspace-\(name)"
        attachment.name = captureName
        attachment.lifetime = .keepAlways
        add(attachment)
        // Export the same unmodified screen immediately for review while the case continues.
        if let destination = ProcessInfo.processInfo.environment["GSD_SCREENSHOT_DIR"] {
            do {
                let directory = URL(fileURLWithPath: destination, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try screenshot.pngRepresentation.write(
                    to: directory.appendingPathComponent(captureName + ".png"), options: .atomic)
            } catch {
                XCTFail("Workspace screenshot export failed: \(error)")
            }
        }
    }
}
