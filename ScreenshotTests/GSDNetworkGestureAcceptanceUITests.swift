import Foundation
import UIKit
import XCTest

/// Additive native gesture evidence. The original Workspace and package suites remain separate gates.
@MainActor
final class GSDNetworkGestureAcceptanceUITests: XCTestCase {
    private enum Failure: Error { case condition(String) }
    private struct Node {
        let id: String
        let title: String
        let frame: CGRect
    }
    private struct Geometry {
        let canvas: CGRect
        let nodes: [String: Node]
    }

    private let requestedScale: CGFloat = 1.2
    private let geometryTolerance: CGFloat = 2
    private let minimumPairDistance: CGFloat = 64
    private let scaleTolerance: CGFloat = 0.06
    private var hebrew = false
    private var artifacts = URL(fileURLWithPath: "/")
    private var receipt: [String: Any] = [:]
    private var checks: [String] = []
    private var measurements: [[String: Any]] = []

    func testNativePinchPreservesViewportAcrossTaskSelection() throws {
        continueAfterFailure = false
        try prepare()
        let app = XCUIApplication(bundleIdentifier: "com.itorah.gsd")
        app.launchArguments = [
            "--demo-seed", "-AppleLanguages", hebrew ? "(he)" : "(en)",
            "-AppleLocale", hebrew ? "he_IL" : "en_US"
        ]
        defer { app.terminate() }
        do {
            try openNetwork(in: app)
            try exercisePinchAndSelection(in: app)
            try require(checks == [
                "stableNativeFitBaseline", "nativePinchScaledObservedNodePairs",
                "firstSelectionPreservedViewport", "secondSelectionPreservedViewport",
                "fitRestoredOriginalViewport"
            ], "Every supplemental acceptance condition must complete exactly once.")
            receipt["passed"] = true
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
              let simulator = env["GSD_SYSTEM_SURFACE_SIMULATOR_UDID"],
              UUID(uuidString: simulator) != nil,
              let root = env["GSD_SYSTEM_SURFACE_ARTIFACTS"], root.hasPrefix("/"),
              let language = env["GSD_TEST_LANGUAGE"], ["en", "he"].contains(language),
              let family = env["GSD_NETWORK_DEVICE_FAMILY"], ["phone", "tablet"].contains(family) else {
            throw Failure.condition("Missing owned simulator, app source, artifact, language, or device-family contract.")
        }
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try require(isPad || UIDevice.current.userInterfaceIdiom == .phone, "An iPhone or iPad is required.")
        try require(family == (isPad ? "tablet" : "phone"), "The actual native device family differs from the contract.")
        if let actualSimulator = env["SIMULATOR_UDID"] {
            try require(actualSimulator.lowercased() == simulator.lowercased(), "The actual simulator differs from the contract.")
        }
        hebrew = language == "he"
        XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
        artifacts = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("network-native-\(family)-\(language)", isDirectory: true)
        try require(!FileManager.default.fileExists(atPath: artifacts.path), "Network evidence is append-only; use a fresh artifact root.")
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        receipt = [
            "schemaVersion": 1, "sourceSHA": source, "simulator": simulator,
            "language": language, "deviceFamily": family,
            "scope": "native_network_pinch_selection_footer_and_fit",
            "demoSeed": true, "inMemoryStore": true, "diskPersistenceAcceptance": false,
            "personalAccountAcceptance": false, "requestedPinchScale": Double(requestedScale),
            "scaleTolerance": Double(scaleTolerance), "geometryTolerancePoints": Double(geometryTolerance),
            "passed": false, "startedUTC": ISO8601DateFormatter().string(from: Date())
        ]
        try persist()
    }

    private func openNetwork(in app: XCUIApplication) throws {
        app.launch()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        try require(isPad ? app.frame.width > app.frame.height : app.frame.height > app.frame.width,
                    "The native app must use the requested tablet-landscape or phone-portrait configuration.")
        let entry = isPad
            ? app.descendants(matching: .any).matching(identifier: "gsd.sidebar.workspace").firstMatch
            : app.tabBars.buttons[hebrew ? "מרחב משימות" : "Workspace"]
        try require(entry.waitForExistence(timeout: 20) && entry.isHittable, "The actual Workspace navigation is unavailable.")
        entry.tap()
        try require(app.descendants(matching: .any).matching(identifier: "task-workspace")
            .firstMatch.waitForExistence(timeout: 15), "The real task workspace did not open.")
        try revealNetworkMode(in: app)
        let canvas = network(in: app)
        try require(canvas.waitForExistence(timeout: 10), "The native Network canvas is missing.")
        let fit = app.buttons["task-workspace.network.fit"].firstMatch
        try require(fit.waitForExistence(timeout: 10) && fit.isHittable, "The native Fit control is unavailable.")
        fit.tap()
        receipt["orientation"] = XCUIDevice.shared.orientation.rawValue
        receipt["appFrame"] = frameJSON(app.frame)
    }

    private func exercisePinchAndSelection(in app: XCUIApplication) throws {
        let canvas = network(in: app)
        let baseline = try stableGeometry(in: app)
        let beforeVisible = visibleNodes(baseline, in: app)
        let initialTitle = app.staticTexts["task-workspace.network.selected-title"].firstMatch
        try require(!initialTitle.exists || initialTitle.label.isEmpty,
                    "The fresh Network must start without an accessible selected title.")
        try require(beforeVisible.count >= 3, "Fit must expose at least three actual hittable task nodes.")
        try capture(app, "01-fit-baseline", geometry: baseline)
        try checked("stableNativeFitBaseline")

        // Node buttons remain 44 points. Their center distances, not their widths, prove camera magnification.
        try require(canvas.isHittable, "The actual Network canvas must receive the two-finger pinch.")
        canvas.pinch(withScale: requestedScale, velocity: 1.0)
        let zoomed = try stableGeometry(in: app)
        let afterVisible = visibleNodes(zoomed, in: app)
        let witnesses = beforeVisible.filter { before in afterVisible.contains { $0.id == before.id } }
        try capture(app, "02-after-native-pinch", geometry: zoomed)
        try verifyPinch(baseline: baseline, zoomed: zoomed, witnesses: witnesses)
        try checked("nativePinchScaledObservedNodePairs")

        let titles = witnesses.sorted { ($0.title.count, $0.id) < ($1.title.count, $1.id) }
        guard let first = titles.first, let second = titles.last, first.id != second.id,
              first.title != second.title else {
            throw Failure.condition("Two distinct observed task titles are required for selection transitions.")
        }
        receipt["selectedNativeNodeIDs"] = [first.id, second.id]
        receipt["canonicalTaskIDs"] = [first.id, second.id].map {
            String($0.dropFirst("task-workspace.open.".count))
        }
        receipt["selectedTitles"] = [first.title, second.title]
        try inspectSelection(first, stage: "03-first-selection", reference: zoomed, witnesses: witnesses, in: app)
        try checked("firstSelectionPreservedViewport")
        try inspectSelection(second, stage: "04-second-selection", reference: zoomed, witnesses: witnesses, in: app)
        try checked("secondSelectionPreservedViewport")

        let fit = app.buttons["task-workspace.network.fit"].firstMatch
        try require(fit.isHittable, "Fit must remain usable after both task selections.")
        fit.tap()
        let fitted = try stableGeometry(in: app)
        try capture(app, "05-fit-restored", geometry: fitted)
        try requireUnchanged(reference: baseline, actual: fitted, ids: witnesses.map(\.id),
                             context: "Fit must recover the original measured viewport.")
        try checked("fitRestoredOriginalViewport")
    }

    private func verifyPinch(baseline: Geometry, zoomed: Geometry, witnesses: [Node]) throws {
        try require(witnesses.count >= 3, "The native pinch must retain three actually hittable witness nodes.")
        try require(frameDifference(baseline.canvas, zoomed.canvas) <= geometryTolerance,
                    "Pinching must magnify the camera without resizing its canvas.")
        var pairs: [[String: Any]] = []
        for (index, left) in witnesses.enumerated() {
            for right in witnesses.dropFirst(index + 1) {
                let distanceBefore = distance(left.frame, right.frame)
                guard distanceBefore >= minimumPairDistance else { continue }
                guard let afterLeft = zoomed.nodes[left.id], let afterRight = zoomed.nodes[right.id] else {
                    throw Failure.condition("A measured native witness disappeared after pinch.")
                }
                let distanceAfter = distance(afterLeft.frame, afterRight.frame)
                let ratio = distanceAfter / distanceBefore
                pairs.append(["ids": [left.id, right.id], "beforePoints": Double(distanceBefore),
                              "afterPoints": Double(distanceAfter), "observedScale": Double(ratio)])
            }
        }
        receipt["pinchPairs"] = pairs
        try persist()
        try require(pairs.count >= 2, "Two separated native node pairs must independently measure the pinch.")
        for pair in pairs {
            guard let ratio = pair["observedScale"] as? Double else {
                throw Failure.condition("A native pair scale measurement is missing.")
            }
            try require(abs(ratio - Double(requestedScale)) <= Double(scaleTolerance),
                        "Every observed pair must reflect the requested 1.2x pinch; a clamp, pan, or automatic Fit is not a zoom pass.")
        }
        for before in witnesses {
            guard let after = zoomed.nodes[before.id] else { throw Failure.condition("Missing native task witness.") }
            try require(abs(before.frame.width - after.frame.width) <= geometryTolerance
                        && abs(before.frame.height - after.frame.height) <= geometryTolerance,
                        "Native task hit regions must retain their size while camera distances magnify.")
        }
    }

    private func inspectSelection(_ selected: Node, stage: String, reference: Geometry,
                                  witnesses: [Node], in app: XCUIApplication) throws {
        let node = app.buttons[selected.id].firstMatch
        try require(node.exists && node.label == selected.title && node.isHittable,
                    "Selection must tap the exact observed native task and title.")
        node.tap()
        let title = app.textFields["editor-title"]
        try require(title.waitForExistence(timeout: 10) && title.value as? String == selected.title,
                    "The native node must open its exact canonical task title.")
        try capture(app, stage + "-canonical-editor")
        let cancel = app.buttons["editor-cancel"]
        try require(cancel.isHittable, "The read-only canonical editor must expose Cancel.")
        cancel.tap()
        try require(title.waitForNonExistence(timeout: 10) && network(in: app).waitForExistence(timeout: 10),
                    "Cancel must return to the same Network.")
        let restored = try stableGeometry(in: app)
        let footer = app.staticTexts["task-workspace.network.selected-title"].firstMatch
        try require(footer.waitForExistence(timeout: 10) && footer.label == selected.title,
                    "The selected-title footer must contain the exact task title after Cancel.")
        try require(!footer.frame.isEmpty && app.frame.contains(footer.frame)
                    && footer.frame.minY >= restored.canvas.maxY - geometryTolerance,
                    "The selected title must remain visible below, and outside, the canvas.")
        for bar in app.tabBars.allElementsBoundByIndex where !bar.frame.isEmpty {
            let overlap = footer.frame.intersection(bar.frame)
            try require(overlap.isNull || overlap.height <= geometryTolerance,
                        "The native tab bar must not cover the selected title.")
        }
        receipt[stage + "Footer"] = ["id": footer.identifier, "title": footer.label, "frame": frameJSON(footer.frame)]
        try capture(app, stage + "-footer", geometry: restored)
        try requireUnchanged(reference: reference, actual: restored, ids: witnesses.map(\.id),
                             context: "Changing the selected title must preserve the zoomed camera and reserved canvas.")
    }

    private func stableGeometry(in app: XCUIApplication) throws -> Geometry {
        var previous: Geometry?
        var consecutive = 0
        for _ in 0..<8 {
            let current = try geometry(in: app)
            if let previous, Set(previous.nodes.keys) == Set(current.nodes.keys),
               frameDifference(previous.canvas, current.canvas) <= 0.5,
               previous.nodes.allSatisfy({ id, node in
                   current.nodes[id].map { frameDifference(node.frame, $0.frame) <= 0.5 } ?? false
               }) {
                consecutive += 1
                if consecutive == 2 { return current }
            } else { consecutive = 0 }
            previous = current
        }
        try capture(app, "98-unsettled-native-geometry", geometry: previous)
        throw Failure.condition("Native Network geometry did not settle within eight measured snapshots.")
    }

    private func geometry(in app: XCUIApplication) throws -> Geometry {
        let canvas = network(in: app)
        try require(canvas.exists && !canvas.frame.isEmpty, "The native Network canvas must have physical geometry.")
        let snapshot: any XCUIElementSnapshot = try canvas.snapshot()
        var pending = snapshot.children
        var nodes: [String: Node] = [:]
        while let item = pending.popLast() {
            if item.identifier.hasPrefix("task-workspace.open.") {
                try require(nodes[item.identifier] == nil, "Native Network task identities must be unique.")
                try require(!item.frame.isEmpty && !item.label.isEmpty, "A native node must expose its real frame and title.")
                nodes[item.identifier] = Node(id: item.identifier, title: item.label, frame: item.frame)
            } else { pending.append(contentsOf: item.children) }
        }
        try require(nodes.count >= 3, "The real demo graph must contain at least three measured task nodes.")
        return Geometry(canvas: canvas.frame, nodes: nodes)
    }

    private func visibleNodes(_ measured: Geometry, in app: XCUIApplication) -> [Node] {
        let fit = app.buttons["task-workspace.network.fit"].firstMatch.frame
        return measured.nodes.values.sorted { $0.id < $1.id }.filter { node in
            guard measured.canvas.contains(node.frame), app.frame.contains(node.frame),
                  !fit.intersects(node.frame) else { return false }
            // Ask for hittability only after the physical bounds are inside the viewport.
            return app.buttons[node.id].firstMatch.isHittable
        }
    }

    private func requireUnchanged(reference: Geometry, actual: Geometry, ids: [String],
                                  context: String) throws {
        try require(frameDifference(reference.canvas, actual.canvas) <= geometryTolerance, context + " Canvas changed.")
        for id in ids {
            guard let before = reference.nodes[id], let after = actual.nodes[id] else {
                throw Failure.condition(context + " A native witness disappeared.")
            }
            try require(before.title == after.title, context + " A task title changed.")
            try require(frameDifference(before.frame, after.frame) <= geometryTolerance,
                        context + " Native node geometry changed: " + id)
        }
    }

    private func revealNetworkMode(in app: XCUIApplication) throws {
        let identifier = "task-workspace.tab.network"
        let button = app.buttons[identifier].firstMatch
        try require(button.waitForExistence(timeout: 10), "The Network presentation control is missing.")
        let strips = app.scrollViews.containing(.button, identifier: identifier)
            .allElementsBoundByIndex.filter { !$0.frame.isEmpty }
        guard let strip = strips.min(by: { $0.frame.height < $1.frame.height }) else {
            throw Failure.condition("The observed presentation strip is missing.")
        }
        for _ in 0..<4 {
            let viewport = strip.frame.intersection(app.frame)
            if !button.frame.isEmpty && viewport.contains(button.frame) { break }
            if button.frame.midX > viewport.midX { strip.swipeLeft() } else { strip.swipeRight() }
        }
        try require(strip.frame.intersection(app.frame).contains(button.frame) && !button.frame.isEmpty,
                    "The Network presentation control must be physically visible.")
        try require(button.isHittable, "The Network presentation control must be hittable.")
        button.tap()
    }

    private func network(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "task-workspace.network.canvas").firstMatch
    }

    private func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = a.midX - b.midX
        let dy = a.midY - b.midY
        return (dx * dx + dy * dy).squareRoot()
    }

    private func frameDifference(_ a: CGRect, _ b: CGRect) -> CGFloat {
        [abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height)].max() ?? 0
    }

    private func frameJSON(_ frame: CGRect) -> [String: Double] {
        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.condition(message) }
    }

    private func checked(_ name: String) throws {
        checks.append(name)
        try persist()
    }

    private func persist() throws {
        receipt["checks"] = checks
        receipt["measurements"] = measurements
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifacts.appendingPathComponent("network-native-acceptance.json"), options: .atomic)
    }

    private func capture(_ app: XCUIApplication, _ name: String, geometry: Geometry? = nil) throws {
        let screenshot = XCUIScreen.main.screenshot()
        let image = XCTAttachment(screenshot: screenshot)
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        try screenshot.pngRepresentation.write(to: artifacts.appendingPathComponent(name + ".png"), options: .atomic)
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
                }
            ])
        }
        try persist()
    }
}
