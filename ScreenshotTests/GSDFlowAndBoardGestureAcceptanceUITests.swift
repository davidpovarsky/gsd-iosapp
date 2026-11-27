import Foundation
import UIKit
import XCTest

/// Additive touch evidence; the original Workspace suite remains a separate gate.
@MainActor
final class GSDFlowAndBoardGestureAcceptanceUITests: XCTestCase {
    private enum Failure: Error { case condition(String) }
    private struct Node {
        let id: String
        let title: String
        let frame: CGRect
    }
    private struct Geometry {
        let canvas: CGRect
        let nodes: [String: Node]
        let actionFrames: [String: CGRect]
        let completionLabels: [String: String]
    }
    private var hebrew = false
    private var artifacts = URL(fileURLWithPath: "/")
    private var receipt: [String: Any] = [:]
    private var checks: [String] = []
    private var measurements: [[String: Any]] = []
    private let scale: CGFloat = 1.2
    private let tolerance: CGFloat = 3

    func testFlowPinchPanEditingAndBoardMenuMutation() throws {
        continueAfterFailure = false
        try prepare()
        let app = XCUIApplication(bundleIdentifier: "com.itorah.gsd")
        app.launchArguments = [
            "--demo-seed", "-AppleLanguages", hebrew ? "(he)" : "(en)",
            "-AppleLocale", hebrew ? "he_IL" : "en_US"
        ]
        defer { app.terminate() }
        do {
            try openWorkspace(in: app)
            let canvas = graph(in: app)
            let fit = app.buttons["task-workspace.graph.fit"].firstMatch
            try require(fit.waitForExistence(timeout: 10) && fit.isHittable, "The original Flow Fit control is unavailable.")
            fit.tap()
            let baseline = try stableGeometry(in: app)
            let beforeVisible = visibleNodes(baseline, in: app)
            try require(beforeVisible.count >= 3, "Fit must expose three real hittable Flow task buttons.")
            try capture(app, "01-flow-fit", geometry: baseline)
            try checked("nativeFlowFitBaseline")

            try require(canvas.isHittable, "The real Flow canvas must receive the two-finger gesture.")
            canvas.pinch(withScale: scale, velocity: 1)
            let zoomed = try stableGeometry(in: app)
            let zoomedVisible = visibleNodes(zoomed, in: app)
            let witnesses = beforeVisible.filter { old in zoomedVisible.contains { $0.id == old.id } }
            try capture(app, "02-flow-native-pinch", geometry: zoomed)
            try verifyPinch(baseline, zoomed, witnesses: witnesses)
            try checked("nativeFlowPinchScaledNodePairs")

            let panned = try panBackground(from: zoomed, baseline: baseline, witnesses: witnesses, in: app)
            try checked("nativeFlowPanMovedWitnessesTogether")
            let visibleAfterPan = visibleNodes(panned, in: app)
            let selected = try unwrap(visibleAfterPan.filter { candidate in
                witnesses.contains { $0.id == candidate.id }
            }.min { distance($0.frame, panned.canvas) < distance($1.frame, panned.canvas) },
            "A measured witness must remain hittable for the post-transform canonical edit.")
            let taskID = String(selected.id.dropFirst("task-workspace.open.".count))
            let updatedTitle = try editObservedTask(selected, in: app)
            // Offscreen Flow nodes are culled during camera motion. Restore the
            // native Fit view and require every original value, with only this
            // already observed canonical title edit, before continuing.
            try require(fit.exists && fit.isHittable, "The original Fit action must remain available after the transformed edit.")
            fit.tap()
            let restored = try stableGeometry(in: app)
            var expectedTitles = baseline.nodes.mapValues(\.title)
            expectedTitles[selected.id] = updatedTitle
            try require(restored.nodes.mapValues(\.title) == expectedTitles
                        && restored.completionLabels == baseline.completionLabels,
                        "Fit must restore every baseline task ID, title and completion value; only the intentional canonical title edit may differ.")
            receipt["restoredAllTaskValues"] = [
                "expectedTitles": expectedTitles, "actualTitles": restored.nodes.mapValues(\.title),
                "baselineCompletionLabels": baseline.completionLabels,
                "actualCompletionLabels": restored.completionLabels
            ]
            try persist()
            try tapMode("table", in: app)
            try filterTask(updatedTitle, in: app)
            let tableOpen = app.buttons[selected.id].firstMatch
            try require(tableOpen.waitForExistence(timeout: 10) && tableOpen.label == updatedTitle,
                        "The same canonical task ID must contain the title saved through the transformed Flow button.")
            try capture(app, "05-flow-edit-table-readback")
            try checked("flowTransformedHitTargetSavedCanonicalTitle")

            let lane = app.buttons["task-workspace.lane." + taskID].firstMatch
            try require(lane.waitForExistence(timeout: 10), "The edited task's actual Table lane is missing.")
            let previousLane = lane.label
            let schedule = hebrew ? "לתכנן" : "Schedule"
            let doFirst = hebrew ? "לביצוע מיידי" : "Do First"
            let destinationID = previousLane == schedule ? "urgent-important" : "not-urgent-important"
            let destinationTitle = previousLane == schedule ? doFirst : schedule
            try require(previousLane != destinationTitle, "The Board action must change the canonical lane.")
            try tapMode("board", in: app)
            let menu = try revealBoardMenu(for: taskID, in: app)
            try capture(app, "06-board-before-menu")
            menu.tap()
            let choice = app.buttons["task-workspace.lane-choice." + taskID + "." + destinationID].firstMatch
            try require(choice.waitForExistence(timeout: 10) && choice.isHittable,
                        "The actual Board card menu must expose the requested different lane.")
            try capture(app, "07-board-open-menu")
            choice.tap()
            try require(choice.waitForNonExistence(timeout: 10), "The Board menu must close after the actual move.")
            try tapMode("table", in: app)
            let moved = app.buttons["task-workspace.lane." + taskID].firstMatch
            try require(moved.waitForExistence(timeout: 10), "The moved canonical task must remain in Table.")
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", destinationTitle), object: moved)
            try require(XCTWaiter.wait(for: [expectation], timeout: 10) == .completed,
                        "The Board menu action must update the same canonical task's lane.")
            try require(app.buttons[selected.id].firstMatch.label == updatedTitle, "A lane move must preserve the edited title.")
            receipt["canonicalTask"] = [
                "taskID": taskID, "originalTitle": selected.title, "updatedTitle": updatedTitle,
                "previousLane": previousLane, "destinationLaneID": destinationID, "destinationLane": destinationTitle
            ]
            try capture(app, "08-board-menu-table-readback")
            try checked("nativeBoardMenuChangedCanonicalLane")

            app.buttons[selected.id].firstMatch.tap()
            let title = app.textFields["editor-title"]
            try require(title.waitForExistence(timeout: 10) && title.value as? String == updatedTitle,
                        "Reopening must show the same edited canonical task.")
            let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
            let selectedQuadrant = editor.buttons.matching(NSPredicate(format: "label CONTAINS %@", destinationTitle)).firstMatch
            try require(selectedQuadrant.waitForExistence(timeout: 10) && selectedQuadrant.isSelected,
                        "The canonical editor must confirm the lane selected through the actual Board menu.")
            try capture(app, "09-board-menu-canonical-editor")
            app.buttons["editor-cancel"].tap()
            try require(title.waitForNonExistence(timeout: 10), "The canonical editor must dismiss normally.")
            try checked("boardMoveConfirmedInCanonicalEditor")
            try require(checks == [
                "nativeFlowFitBaseline", "nativeFlowPinchScaledNodePairs",
                "nativeFlowPanMovedWitnessesTogether", "flowTransformedHitTargetSavedCanonicalTitle",
                "nativeBoardMenuChangedCanonicalLane", "boardMoveConfirmedInCanonicalEditor"
            ], "Every supplemental acceptance condition must complete exactly once.")
            receipt["passed"] = true
            receipt["finishedUTC"] = ISO8601DateFormatter().string(from: Date())
            try persist()
        } catch {
            receipt["failure"] = String(describing: error)
            do { try capture(app, "99-failure") }
            catch { receipt["failureCaptureError"] = String(describing: error) }
            try persist()
            throw error
        }
    }

    private func prepare() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["GSD_SYSTEM_SURFACE_FRESH_SIMULATOR"] == "1",
              let source = env["GSD_SYSTEM_SURFACE_APP_SOURCE"],
              source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              let simulator = env["GSD_SYSTEM_SURFACE_SIMULATOR_UDID"], UUID(uuidString: simulator) != nil,
              let root = env["GSD_SYSTEM_SURFACE_ARTIFACTS"], root.hasPrefix("/"),
              let language = env["GSD_TEST_LANGUAGE"], ["en", "he"].contains(language),
              let family = env["GSD_FLOW_BOARD_DEVICE_FAMILY"], ["phone", "tablet"].contains(family) else {
            throw Failure.condition("Missing owned simulator, source, artifacts, language or device-family contract.")
        }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try require(isPad || UIDevice.current.userInterfaceIdiom == .phone, "An actual iPhone or iPad simulator is required.")
        try require(family == (isPad ? "tablet" : "phone"), "The requested and actual device families differ.")
        if let actual = env["SIMULATOR_UDID"] {
            try require(actual.lowercased() == simulator.lowercased(), "The actual simulator differs from the owned contract.")
        }
        hebrew = language == "he"
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        artifacts = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("flow-board-native-\(family)-\(language)", isDirectory: true)
        try require(!FileManager.default.fileExists(atPath: artifacts.path), "Evidence is append-only; use a new artifact root.")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        receipt = [
            "schemaVersion": 1, "sourceSHA": source, "simulator": simulator,
            "language": language, "deviceFamily": family, "scope": "flow_native_pinch_pan_edit_and_board_menu",
            "demoSeed": true, "inMemoryStore": true, "diskPersistenceAcceptance": false,
            "personalAccountAcceptance": false, "requestedPinchScale": Double(scale),
            "scaleTolerance": 0.06, "geometryTolerancePoints": Double(tolerance),
            "passed": false, "startedUTC": ISO8601DateFormatter().string(from: Date())
        ]
        try persist()
    }

    private func openWorkspace(in app: XCUIApplication) throws {
        app.launch()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try require(isPad ? app.frame.width > app.frame.height : app.frame.height > app.frame.width,
                    "The app must use tablet landscape or phone portrait as requested.")
        let entry = isPad
            ? app.descendants(matching: .any).matching(identifier: "gsd.sidebar.workspace").firstMatch
            : app.tabBars.buttons[hebrew ? "מרחב משימות" : "Workspace"]
        try require(entry.waitForExistence(timeout: 20) && entry.isHittable, "The actual Workspace navigation is unavailable.")
        entry.tap()
        try require(app.descendants(matching: .any).matching(identifier: "task-workspace")
            .firstMatch.waitForExistence(timeout: 15), "The actual workspace did not open.")
        try tapMode("graph", in: app)
        try require(graph(in: app).waitForExistence(timeout: 10), "The original Flow canvas is unavailable.")
    }

    private func verifyPinch(_ before: Geometry, _ after: Geometry, witnesses: [Node]) throws {
        try require(witnesses.count >= 3, "Pinch must retain three real hittable Flow witnesses.")
        try require(frameDifference(before.canvas, after.canvas) <= tolerance, "Pinch must not resize the canvas.")
        try requireVisibleTaskValues(before, after)
        var pairs: [[String: Any]] = []
        for (index, a) in witnesses.enumerated() {
            for b in witnesses.dropFirst(index + 1) where distance(a.frame, b.frame) >= 64 {
                let a1 = try unwrap(after.nodes[a.id], "Missing first pinch witness.")
                let b1 = try unwrap(after.nodes[b.id], "Missing second pinch witness.")
                let oldDistance = distance(a.frame, b.frame)
                let newDistance = distance(a1.frame, b1.frame)
                pairs.append(["ids": [a.id, b.id], "beforePoints": Double(oldDistance),
                              "afterPoints": Double(newDistance), "scale": Double(newDistance / oldDistance)])
            }
        }
        receipt["pinchPairs"] = pairs
        try persist()
        try require(pairs.count >= 2, "Two distinct separated node pairs must independently measure the native pinch.")
        for pair in pairs {
            let observed = try unwrap(pair["scale"] as? Double, "Missing observed pinch scale.")
            try require(observed.isFinite && observed > 1.05,
                        "Every measured Flow pair must show a real opening zoom; raw two-finger agreement is a separate mandatory host gate.")
        }
        try recordNativePinch([
            "pairs": pairs, "beforeCanvas": frameJSON(before.canvas), "afterCanvas": frameJSON(after.canvas),
            "minimumPairDistancePoints": 64, "witnessIDs": witnesses.map(\.id).sorted()
        ])
        // Flow card/action frames scale with the actual rendered cards. Network's fixed 44pt rule does not apply.
    }

    private func panBackground(from before: Geometry, baseline: Geometry, witnesses: [Node], in app: XCUIApplication) throws -> Geometry {
        let canvas = graph(in: app)
        let viewport = visibleViewport(before.canvas, in: app)
        let safeArea = CGRect(x: viewport.minX + 24, y: viewport.minY + 80,
                              width: viewport.width - 48, height: viewport.height - 184)
        try require(safeArea.width > 80 && safeArea.height > 80, "The real Flow viewport must expose background for panning.")
        // Group actual measured title/completion/port targets into conservative node exclusion rectangles.
        // Padding also excludes the card body below its title and native connector hit regions.
        var taskBounds: [String: CGRect] = [:]
        var exclusions: [CGRect] = []
        let prefixes = ["task-workspace.open.", "task-workspace.complete.",
                        "task-workspace.graph.handle.in.", "task-workspace.graph.handle.out."]
        for (id, frame) in before.actionFrames {
            if let prefix = prefixes.first(where: { id.hasPrefix($0) }) {
                let task = String(id.dropFirst(prefix.count))
                taskBounds[task] = taskBounds[task].map { $0.union(frame) } ?? frame
            } else { exclusions.append(frame.insetBy(dx: -12, dy: -12)) }
        }
        exclusions += taskBounds.values.map { $0.insetBy(dx: -24, dy: -max(24, $0.height * 0.45)) }
        var candidates: [CGPoint] = []
        for row in 1..<10 {
            for column in 1..<10 {
                let point = CGPoint(x: safeArea.minX + safeArea.width * CGFloat(column) / 10,
                                    y: safeArea.minY + safeArea.height * CGFloat(row) / 10)
                if !exclusions.contains(where: { $0.contains(point) }) { candidates.append(point) }
            }
        }
        let start = try unwrap(candidates.min {
            hypot($0.x - safeArea.midX, $0.y - safeArea.midY) < hypot($1.x - safeArea.midX, $1.y - safeArea.midY)
        }, "No measured empty Flow background point is available for a real pan.")
        let end = CGPoint(x: start.x + (start.x < safeArea.midX ? 48 : -48), y: start.y)
        try require(viewport.contains(start) && viewport.contains(end), "The observed pan path must remain inside the viewport.")
        receipt["panGesture"] = [
            "start": ["x": Double(start.x), "y": Double(start.y)],
            "end": ["x": Double(end.x), "y": Double(end.y)],
            "excludedNodeBounds": taskBounds.values.map(frameJSON)
        ]
        try persist()
        let origin = canvas.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: start.x - before.canvas.minX, dy: start.y - before.canvas.minY))
            .press(forDuration: 0.05, thenDragTo:
                origin.withOffset(CGVector(dx: end.x - before.canvas.minX, dy: end.y - before.canvas.minY)))
        let after = try stableGeometry(in: app)
        try capture(app, "03-flow-native-pan", geometry: after)
        try requireVisibleTaskValues(baseline, after)
        try require(frameDifference(before.canvas, after.canvas) <= tolerance, "Panning must not resize the canvas.")
        let visible = visibleNodes(after, in: app)
        let retained = witnesses.filter { old in visible.contains { $0.id == old.id } }
        try require(retained.count >= 3, "A real pan must retain three hittable witnesses.")
        var translations: [[String: Any]] = []
        var vectors: [CGVector] = []
        for old in retained {
            let p0 = try unwrap(before.nodes[old.id], "Missing pre-pan witness.")
            let p1 = try unwrap(after.nodes[old.id], "Missing post-pan witness.")
            let vector = CGVector(dx: p1.frame.midX - p0.frame.midX, dy: p1.frame.midY - p0.frame.midY)
            vectors.append(vector)
            translations.append(["id": old.id, "dx": Double(vector.dx), "dy": Double(vector.dy)])
            try require(abs(p1.frame.width - p0.frame.width) <= tolerance
                        && abs(p1.frame.height - p0.frame.height) <= tolerance, "Panning must preserve rendered task sizes.")
        }
        receipt["panTranslations"] = translations
        try persist()
        let reference = try unwrap(vectors.first, "Missing measured pan vector.")
        try require(hypot(reference.dx, reference.dy) > 24, "A real pan must move the rendered graph by more than 24 points.")
        try require((end.x - start.x) * reference.dx > 0 && abs(reference.dy) <= tolerance,
                    "The graph must translate in the direction of the actual horizontal gesture.")
        for vector in vectors {
            try require(abs(vector.dx - reference.dx) <= tolerance && abs(vector.dy - reference.dy) <= tolerance,
                        "All witness nodes must move together; dragging one task is not a canvas pan.")
        }
        for (index, a) in retained.enumerated() {
            for b in retained.dropFirst(index + 1) {
                let a0 = try unwrap(before.nodes[a.id], "Missing pre-pan pair.")
                let b0 = try unwrap(before.nodes[b.id], "Missing pre-pan pair.")
                let a1 = try unwrap(after.nodes[a.id], "Missing post-pan pair.")
                let b1 = try unwrap(after.nodes[b.id], "Missing post-pan pair.")
                try require(abs(distance(a0.frame, b0.frame) - distance(a1.frame, b1.frame)) <= tolerance,
                            "The native background pan must preserve pair distances and zoom.")
            }
        }
        return after
    }

    private func editObservedTask(_ selected: Node, in app: XCUIApplication) throws -> String {
        let node = app.buttons[selected.id].firstMatch
        try require(node.exists && node.isHittable && node.label == selected.title,
                    "The transformed native task button must still identify the observed task.")
        node.tap()
        let title = app.textFields["editor-title"]
        try require(title.waitForExistence(timeout: 10) && title.value as? String == selected.title,
                    "The transformed Flow hit target must open its exact canonical task.")
        try capture(app, "04-flow-canonical-editor-before-edit")
        title.tap()
        let marker = "GSD-TOUCH"
        title.typeText(" " + marker)
        let edited = try unwrap(title.value as? String, "The actual edited title is unavailable.")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try require(edited != selected.title && edited.contains(marker), "A real text entry must change the canonical editor draft.")
        let save = app.buttons["editor-save"]
        try require(save.waitForExistence(timeout: 10) && save.isEnabled && save.isHittable, "Canonical Save must be enabled and hittable.")
        save.tap()
        try require(title.waitForNonExistence(timeout: 10), "Saving the real edit must dismiss the canonical editor.")
        return edited
    }

    private func filterTask(_ title: String, in app: XCUIApplication) throws {
        let search = app.textFields["task-workspace.search"].firstMatch
        try require(search.waitForExistence(timeout: 10) && search.isHittable, "The actual workspace search is unavailable.")
        let clear = app.buttons[hebrew ? "ניקוי חיפוש" : "Clear search"].firstMatch
        if clear.exists { clear.tap() }
        search.tap()
        search.typeText(title + "\n")
        try require(search.value as? String == title, "Search must contain the exact edited task title.")
        if app.keyboards.firstMatch.exists {
            let hide = app.buttons[hebrew ? "הסתרת המקלדת" : "Hide keyboard"].firstMatch
            if hide.exists && hide.isHittable { hide.tap() }
            else {
                let bar = app.navigationBars.firstMatch
                try require(bar.exists && bar.isHittable, "An observed navigation bar is needed to dismiss the keyboard.")
                bar.tap()
            }
        }
        try require(!app.keyboards.firstMatch.exists, "The keyboard must be dismissed before native Board interactions.")
    }

    private func revealBoardMenu(for taskID: String, in app: XCUIApplication) throws -> XCUIElement {
        let board = app.scrollViews["task-workspace.board"].firstMatch
        try require(board.waitForExistence(timeout: 10), "The real horizontal Board scroll view is missing.")
        let menu = app.buttons["task-workspace.board.actions." + taskID].firstMatch
        for _ in 0..<8 {
            let viewport = visibleViewport(board.frame, in: app).insetBy(dx: 2, dy: 2)
            if menu.exists && !menu.frame.isEmpty {
                if viewport.contains(menu.frame) {
                    try require(menu.isHittable, "The observed Board menu must be hittable before tapping.")
                    return menu
                }
                if menu.frame.midX > viewport.midX { board.swipeLeft() } else { board.swipeRight() }
            } else { throw Failure.condition("The filtered edited task must materialize its actual Board menu.") }
        }
        throw Failure.condition("The actual Board card menu did not become fully visible after bounded horizontal scrolling.")
    }

    private func stableGeometry(in app: XCUIApplication) throws -> Geometry {
        var previous: Geometry?
        var stable = 0
        for _ in 0..<8 {
            let value = try geometry(in: app)
            if let previous, Set(previous.nodes.keys) == Set(value.nodes.keys),
               frameDifference(previous.canvas, value.canvas) <= 0.5,
               previous.nodes.allSatisfy({ id, node in
                   value.nodes[id].map { frameDifference(node.frame, $0.frame) <= 0.5 } ?? false
               }) {
                stable += 1
                if stable == 2 { return value }
            } else { stable = 0 }
            previous = value
        }
        try capture(app, "98-unsettled-flow-geometry", geometry: previous)
        throw Failure.condition("Flow geometry did not settle within eight native snapshots.")
    }

    private func geometry(in app: XCUIApplication) throws -> Geometry {
        let canvas = graph(in: app)
        try require(canvas.exists && !canvas.frame.isEmpty, "The actual Flow canvas must have physical bounds.")
        let snapshot: any XCUIElementSnapshot = try canvas.snapshot()
        var pending = snapshot.children
        var nodes: [String: Node] = [:]
        var actions: [String: CGRect] = [:]
        var completion: [String: String] = [:]
        while let item = pending.popLast() {
            let id = item.identifier
            if id.hasPrefix("task-workspace.open.") {
                try require(nodes[id] == nil && !item.frame.isEmpty && !item.label.isEmpty,
                            "Flow task IDs, native frames and titles must be unique and available.")
                nodes[id] = Node(id: id, title: item.label, frame: item.frame)
                actions[id] = item.frame
            } else if id.hasPrefix("task-workspace.complete.") {
                completion[id] = item.label
                actions[id] = item.frame
            } else {
                if id.hasPrefix("task-workspace.graph.") && id != "task-workspace.graph.canvas"
                    && !item.frame.isEmpty { actions[id] = item.frame }
                pending.append(contentsOf: item.children)
            }
        }
        try require(nodes.count >= 3, "The real Flow fixture must expose at least three measured tasks.")
        return Geometry(canvas: canvas.frame, nodes: nodes, actionFrames: actions, completionLabels: completion)
    }

    private func requireVisibleTaskValues(_ baseline: Geometry, _ actual: Geometry) throws {
        try require(actual.nodes.allSatisfy { id, node in baseline.nodes[id]?.title == node.title }
                    && actual.completionLabels.allSatisfy { id, value in baseline.completionLabels[id] == value },
                    "Every node and completion value materialized during a viewport gesture must retain its baseline canonical identity and value.")
    }

    private func visibleNodes(_ geometry: Geometry, in app: XCUIApplication) -> [Node] {
        let viewport = visibleViewport(geometry.canvas, in: app)
        let controls = geometry.actionFrames.filter { id, _ in
            ["task-workspace.graph.fit", "task-workspace.graph.focus", "task-workspace.graph.arrange"].contains(id)
        }.map(\.value)
        return geometry.nodes.values.sorted { $0.id < $1.id }.filter { node in
            viewport.contains(node.frame) && !controls.contains(where: { $0.intersects(node.frame) })
                && app.buttons[node.id].firstMatch.isHittable
        }
    }

    private func tapMode(_ mode: String, in app: XCUIApplication) throws {
        let id = "task-workspace.tab." + mode
        let button = app.buttons[id].firstMatch
        try require(button.waitForExistence(timeout: 10), "The requested native presentation control is missing.")
        let strips = app.scrollViews.containing(.button, identifier: id).allElementsBoundByIndex.filter { !$0.frame.isEmpty }
        let strip = try unwrap(strips.min { $0.frame.height < $1.frame.height }, "The native presentation strip is missing.")
        for _ in 0..<4 {
            let viewport = strip.frame.intersection(app.frame)
            if !button.frame.isEmpty && viewport.contains(button.frame) { break }
            if button.frame.midX > viewport.midX { strip.swipeLeft() } else { strip.swipeRight() }
        }
        try require(!button.frame.isEmpty && strip.frame.intersection(app.frame).contains(button.frame),
                    "The presentation control must be physically visible before hit testing.")
        try require(button.isHittable, "The observed presentation control must be hittable.")
        button.tap()
    }

    private func graph(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "task-workspace.graph.canvas").firstMatch
    }
    private func visibleViewport(_ frame: CGRect, in app: XCUIApplication) -> CGRect {
        var result = frame.intersection(app.frame)
        for bar in app.tabBars.allElementsBoundByIndex where bar.frame.intersects(result) {
            result.size.height = max(0, min(result.maxY, bar.frame.minY) - result.minY)
        }
        return result
    }
    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }
    private func frameDifference(_ a: CGRect, _ b: CGRect) -> CGFloat {
        [abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height)].max() ?? 0
    }
    private func frameJSON(_ frame: CGRect) -> [String: Double] {
        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
    }

    // The host must decode this same test's original two-finger event before it
    // can accept the run. XCTest's nominal scale is retained as input metadata.
    private func recordNativePinch(_ values: [String: Any]) throws {
        var observation = values
        observation["schemaVersion"] = 1
        observation["kind"] = "Flow"
        observation["sourceSHA"] = receipt["sourceSHA"]
        observation["simulator"] = receipt["simulator"]
        observation["requestedScale"] = 1.2
        observation["requestedVelocity"] = 1.0
        observation["maximumRelativeError"] = 0.06 / Double(scale)
        observation["observedAtUnixSeconds"] = Date().timeIntervalSince1970
        let payload = try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
        let destination = artifacts.appendingPathComponent("native-pinch-measured-output.json")
        try require(!FileManager.default.fileExists(atPath: destination.path), "Native pinch measurement must be append-only.")
        try payload.write(to: destination, options: .atomic)
        let attachment = XCTAttachment(data: payload, uniformTypeIdentifier: "public.json")
        attachment.name = "GSD Flow native pinch measured output"
        attachment.lifetime = .keepAlways
        add(attachment)
        receipt["rawPinchInputGateRequired"] = true
        receipt["nativePinchMeasuredOutput"] = observation
        try persist()
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.condition(message) }
    }
    private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure.condition(message) }
        return value
    }
    private func checked(_ name: String) throws { checks.append(name); try persist() }
    private func persist() throws {
        receipt["checks"] = checks
        receipt["measurements"] = measurements
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifacts.appendingPathComponent("flow-board-native-acceptance.json"), options: .atomic)
    }
    private func capture(_ app: XCUIApplication, _ name: String, geometry: Geometry? = nil) throws {
        let screen = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screen)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try screen.pngRepresentation.write(to: artifacts.appendingPathComponent(name + ".png"), options: .atomic)
        let observed = app.debugDescription
        let hierarchy = XCTAttachment(string: observed)
        hierarchy.name = name + "-observed-elements"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        try observed.write(to: artifacts.appendingPathComponent(name + "-observed-elements.txt"), atomically: true, encoding: .utf8)
        if let geometry {
            measurements.append([
                "stage": name, "canvas": frameJSON(geometry.canvas),
                "nodes": geometry.nodes.values.sorted { $0.id < $1.id }.map {
                    ["id": $0.id, "title": $0.title, "frame": frameJSON($0.frame)] as [String: Any]
                },
                "actionFrames": geometry.actionFrames.mapValues(frameJSON),
                "completionLabels": geometry.completionLabels
            ])
        }
        try persist()
    }
}
