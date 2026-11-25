import Foundation
import UIKit
import XCTest

private struct SystemSurfaceFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Supplemental tests against the separately installed, hash-verified app from the runner receipt.
/// Discovery is explicitly incomplete coverage. Only the real text-share path below
/// can become passed; it does not prove web-URL activation, WidgetKit, Siri or VoiceOver.
@MainActor
final class GSDSystemSurfaceUITests: XCTestCase {
    private let appBundle = "com.itorah.gsd"
    private let springboardBundle = "com.apple.springboard"
    private let safariBundle = "com.apple.mobilesafari"
    private let shortcutsBundle = "com.apple.shortcuts"
    private var sourceSHA = ""
    private var artifacts = URL(fileURLWithPath: "/")
    private var installedBundles = Set<String>()
    private var observations: [String: Any] = [:]

    // XCTest setup is nonisolated; prepare from each MainActor test before UI access.
    private func prepareSystemSurfaceTest() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw SystemSurfaceFailure(message: "This supplemental class is simulator-only.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let verifiedSource = environment["GSD_SYSTEM_SURFACE_APP_SOURCE"],
              verifiedSource.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              environment["GSD_SYSTEM_SURFACE_FRESH_SIMULATOR"] == "1",
              let marker = environment["GSD_SYSTEM_SURFACE_SIMULATOR_UDID"],
              UUID(uuidString: marker) != nil,
              let path = environment["GSD_SYSTEM_SURFACE_ARTIFACTS"], path.hasPrefix("/"),
              let inventory = environment["GSD_SYSTEM_INSTALLED_BUNDLE_IDS"]?.data(using: .utf8),
              let bundleIDs = try JSONSerialization.jsonObject(with: inventory) as? [String] else {
            throw SystemSurfaceFailure(message: "Missing owned-simulator/artifact/installed-app runner contract.")
        }
        sourceSHA = verifiedSource
        // The marker is provenance, not device authorization. The separate runner owns
        // creation, installed-product hashes, OS locale and deletion of this simulator.
        try require(environment["GSD_TEST_LANGUAGE"] == "he", "The initial supplemental profile must be Hebrew.")
        try require(UIDevice.current.userInterfaceIdiom == .phone, "The initial supplemental profile must be iPhone.")
        installedBundles = Set(bundleIDs)
        try require(installedBundles.contains(appBundle), "GSD is absent from the installed-app inventory.")
        artifacts = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try loadObservations(simulatorID: marker)
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    func test00RecordSystemSurfaceDiscovery() throws {
        try prepareSystemSurfaceTest()
        // No guessed widget-gallery, Safari-share or Shortcuts action selectors.
        XCUIDevice.shared.press(.home)
        try captureRaw("00-home-screen")
        let springboard = XCUIApplication(bundleIdentifier: springboardBundle)
        let homeListed = installedBundles.contains(springboardBundle)
        let homeObserved = springboard.wait(for: .runningForeground, timeout: 10)
        try observe("widgetKit", status: "incomplete", details: [
            "systemHostInInventory": homeListed, "hostForegroundObserved": homeObserved,
            "observedHostState": springboard.state.rawValue, "galleryOpened": false,
            "timelineObserved": false, "refreshObserved": false, "tapVerified": false,
            "reason": homeObserved ? "Home screen discovery only." : "Home press did not yield an observed foreground SpringBoard."
        ])
        if homeObserved { try captureHierarchy(springboard, "00-home-screen") }
        try discoverHost(safariBundle, surface: "shareWebURL", name: "00-safari-initial")
        try discoverHost(shortcutsBundle, surface: "shortcuts", name: "00-shortcuts-initial")
        try observe("voiceOver", status: "unknown", details: [
            "reason": "No focus-navigation or spoken-output interaction has been performed."
        ])
        observations["discoveryRecorded"] = true
        try persist()
    }

    func test01TextShareExtensionRoundTripAndCancellation() throws {
        try prepareSystemSurfaceTest()
        observations["discoveryOnly"] = false
        try observe("shareText", status: "incomplete", details: [
            "payloadKind": "String from the existing task ShareLink",
            "assertions": [
                "sourceCreated": false, "activitySheetOpened": false,
                "extensionOpenedForAdd": false, "addCreatedExactlyOne": false,
                "addedTaskPersisted": false, "extensionOpenedForCancel": false,
                "cancelCreatedNone": false, "cancelNoneAfterRelaunch": false
            ]
        ])
        let app = normalApplication()
        defer { app.terminate() }
        do {
            try runTextShare(app)
            try observe("shareText", status: "passed", details: [
                "reason": "Actual extension Add/Cancel and native persistence assertions completed."
            ])
        } catch {
            try observe("shareText", status: "incomplete", details: [
                "failure": error.localizedDescription
            ])
            throw error
        }
    }

    func test02DiscoverOwnedSystemControls() throws {
        try prepareSystemSurfaceTest()
        let app = normalApplication()
        app.launch()
        try requireMatrix(app)
        app.terminate()
        XCUIDevice.shared.press(.home)

        let springboard = XCUIApplication(bundleIdentifier: springboardBundle)
        let icon = springboard.icons.matching(identifier: "GSD").firstMatch
        for _ in 0..<2 where !icon.isHittable { springboard.swipeRight() }
        let iconAvailable = icon.exists && icon.isHittable
        if iconAvailable { icon.press(forDuration: 1.2) }
        try capture(springboard, "20-observed-gsd-home-controls")
        XCUIDevice.shared.press(.home)

        try require(installedBundles.contains(shortcutsBundle), "Shortcuts is absent from this owned simulator.")
        let shortcuts = XCUIApplication(bundleIdentifier: shortcutsBundle)
        shortcuts.activate()
        let continueButton = shortcuts.buttons["המשך"]
        if continueButton.waitForExistence(timeout: 5) {
            try require(continueButton.isHittable, "The observed Shortcuts introduction is obscured.")
            continueButton.tap()
            try require(continueButton.waitForNonExistence(timeout: 10), "The Shortcuts introduction did not dismiss.")
        }
        try capture(shortcuts, "21-shortcuts-after-introduction")
        let create = shortcuts.buttons["main.button.newshortcut"]
        try require(create.waitForExistence(timeout: 10) && create.isHittable,
                    "The observed New Shortcut control is unavailable.")
        create.tap()
        try capture(shortcuts, "22-shortcuts-action-picker")
        try writeJSON([
            "schemaVersion": 1, "appSourceSHA": sourceSHA,
            "scope": "observed_owned_system_controls_only",
            "gsdHomeIconLongPressObserved": iconAvailable,
            "shortcutEditorOpened": true,
            "widgetTimelineVerified": false, "shortcutInvoked": false,
            "personalAccountUsed": false
        ], name: "system-control-discovery.json")
        shortcuts.terminate()
    }

    private func runTextShare(_ app: XCUIApplication) throws {
        let token = String(UUID().uuidString.prefix(8))
        let sourceTitle = "בדיקת שיתוף GSD " + token
        let addedMarker = "Added-" + token
        let cancelMarker = "Cancel-" + token
        observations["syntheticMarkers"] = [sourceTitle, addedMarker, cancelMarker]
        try persist()
        app.launch()
        try captureRaw("01-normal-launch")
        try requireMatrix(app)
        let captureField = app.textFields["capture-field"]
        captureField.tap()
        captureField.typeText(sourceTitle + " !!\n")
        let original = try uniqueCard(app, containing: sourceTitle)
        let originalID = original.identifier
        try require(originalID.hasPrefix("task-card-"), "The source task has no actual task-card identifier.")
        try shareAssertion("sourceCreated")
        try capture(app, "02-created-source-task")

        let addHost = try openShareCompose(app, originalID: originalID, phase: "03-add")
        try shareAssertion("extensionOpenedForAdd")
        try addHost.performAccessibilityAudit(for: [.sufficientElementDescription])
        try observe("accessibility", status: "passed", details: [
            "scope": "sufficientElementDescription on the actual visible Share compose host",
            "voiceOverFocusOrSpeechVerified": false
        ])
        try enterMarker(addedMarker, expectedSourceTitle: sourceTitle, phase: "04-add", in: addHost)
        try capture(addHost, "04-share-compose-add")
        try tapComposeAction("הוספה", in: addHost)
        app.activate()
        try captureRaw("05-after-add-before-query")
        try requireMatrix(app)
        let afterAdd = try matrixCards(app, phase: "05-add-all-quadrants", waitingFor: addedMarker)
        let addedID = try uniqueMatrixCardID(afterAdd, containing: addedMarker)
        try require(addedID != originalID,
                    "Share Add must create a distinct task instead of replacing the source task.")
        try shareAssertion("addCreatedExactlyOne")
        try capture(app, "05-added-in-gsd")
        try relaunch(app, captureName: "06-add-after-relaunch")
        let afterAddRelaunch = try matrixCards(app, phase: "06-relaunch-all-quadrants", waitingFor: addedMarker)
        try require(try uniqueMatrixCardID(afterAddRelaunch, containing: addedMarker) == addedID,
                    "The added task identity changed across a normal relaunch.")
        // The shared title intentionally includes the source title, so identify the original
        // by its captured task ID, never by a title-contains query after another task exists.
        guard let preservedOriginal = afterAddRelaunch[originalID] else {
            throw SystemSurfaceFailure(message: "The original task is absent after Share Add and relaunch.")
        }
        try require(preservedOriginal.contains(sourceTitle) && !preservedOriginal.contains(addedMarker),
                    "Share Add must preserve the original task and its title after a normal relaunch.")
        try shareAssertion("addedTaskPersisted")

        let cancelHost = try openShareCompose(app, originalID: originalID, phase: "07-cancel")
        try shareAssertion("extensionOpenedForCancel")
        try enterMarker(cancelMarker, expectedSourceTitle: sourceTitle, phase: "08-cancel", in: cancelHost)
        try capture(cancelHost, "08-share-compose-cancel")
        try tapComposeAction("ביטול", in: cancelHost)
        app.activate()
        try captureRaw("09-after-cancel-before-query")
        try dismissCancelledActivitySheet(app)
        try requireMatrix(app)
        _ = try requireNoCard(app, containing: cancelMarker, phase: "09-cancel-all-quadrants")
        try shareAssertion("cancelCreatedNone")
        try capture(app, "09-after-cancel")
        try relaunch(app, captureName: "10-cancel-after-relaunch")
        let afterCancelRelaunch = try requireNoCard(
            app, containing: cancelMarker, phase: "10-cancel-relaunch-all-quadrants", waitingFor: addedMarker)
        try require(try uniqueMatrixCardID(afterCancelRelaunch, containing: addedMarker) == addedID,
                    "Cancel must leave the previously added task intact.")
        try shareAssertion("cancelNoneAfterRelaunch")
    }

    private func normalApplication() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: appBundle)
        app.launchArguments = ["-AppleLanguages", "(he)", "-AppleLocale", "he_IL"]
        return app
    }

    private func requireMatrix(_ app: XCUIApplication) throws {
        // Matrix remains in the accessibility tree underneath normal onboarding.
        let skip = app.buttons["דילוג"]
        if skip.waitForExistence(timeout: 5) {
            try require(skip.isHittable, "The normal onboarding Skip action is obscured.")
            skip.tap()
            try require(skip.waitForNonExistence(timeout: 10), "Normal onboarding did not dismiss.")
        }
        let field = app.textFields["capture-field"]
        try require(field.waitForExistence(timeout: 30), "Normal GSD did not reach the Matrix capture field.")
        try require(field.isEnabled, "The Matrix capture field is disabled.")
        try require(field.wait(for: \.isHittable, toEqual: true, timeout: 10),
                    "The Matrix capture field is obscured.")
    }

    private func dismissCancelledActivitySheet(_ app: XCUIApplication) throws {
        // Cancel returns to the observed native activity sheet on this runtime.
        // Dismiss that sheet before checking the host Matrix and persisted tasks.
        let sheets = app.otherElements.matching(identifier: "ActivityListView")
        guard sheets.firstMatch.waitForExistence(timeout: 3) else { return }
        try require(sheets.count == 1, "The returned native activity sheet is ambiguous.")
        let sheet = sheets.firstMatch
        try capture(app, "09-cancel-returned-activity-sheet")
        let dismissRegions = app.otherElements.matching(identifier: "PopoverDismissRegion")
        try require(dismissRegions.firstMatch.waitForExistence(timeout: 10),
                    "The native activity popover dismissal region is missing.")
        try require(dismissRegions.count == 1, "The native activity popover dismissal region is ambiguous.")
        let dismissRegion = dismissRegions.firstMatch
        try require(dismissRegion.wait(for: \.isHittable, toEqual: true, timeout: 10),
                    "The native activity popover dismissal region is obscured.")
        dismissRegion.tap()
        try require(sheet.waitForNonExistence(timeout: 10),
                    "The returned native activity sheet did not dismiss after tapping its dismissal region.")
        try capture(app, "09-after-activity-sheet-dismissal")
    }

    private func cards(_ app: XCUIApplication, containing marker: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'task-card-' AND label CONTAINS %@", marker))
    }

    private func uniqueCard(_ app: XCUIApplication, containing marker: String) throws -> XCUIElement {
        let query = cards(app, containing: marker)
        try require(query.firstMatch.waitForExistence(timeout: 20), "No task card contains synthetic marker \(marker).")
        try require(query.count == 1, "Expected exactly one task card for synthetic marker \(marker); found \(query.count).")
        return query.firstMatch
    }

    private func requireNoCard(_ app: XCUIApplication, containing marker: String,
                               phase: String, waitingFor existingMarker: String? = nil) throws -> [String: String] {
        let query = cards(app, containing: marker)
        try require(!query.firstMatch.waitForExistence(timeout: 8),
                    "Cancel unexpectedly created a task containing synthetic marker \(marker).")
        let allCards = try matrixCards(app, phase: phase, waitingFor: existingMarker)
        try require(allCards.values.allSatisfy { !$0.contains(marker) },
                    "Cancelled synthetic task is present in the fully traversed Matrix.")
        return allCards
    }

    private func uniqueMatrixCardID(_ labels: [String: String], containing marker: String) throws -> String {
        let matches = labels.filter { $0.value.contains(marker) }.map(\.key)
        guard matches.count == 1, let id = matches.first else {
            throw SystemSurfaceFailure(message: "Expected exactly one Matrix task ID for synthetic marker \(marker); found \(matches.count).")
        }
        return id
    }

    /// A SwiftUI List materializes only nearby rows. Share intentionally defaults to Q4, below
    /// the initial Q1/Q2 viewport, so both positive and negative assertions must visit every
    /// quadrant. These are ordinary native scroll gestures on the observed Matrix CollectionView.
    private func matrixCards(_ app: XCUIApplication, phase: String,
                             waitingFor marker: String? = nil) throws -> [String: String] {
        let list = try scrollMatrixToTop(app)
        let quadrantLabels = ["לביצוע מיידי", "לתכנן", "להעביר לאחרים", "לוותר"]
        var seenQuadrants = Set<String>()
        var labels: [String: String] = [:]
        var previousViewport: [String]?
        var checkpoints: [[String: Any]] = []
        var reachedBottom = false

        for step in 0...8 {
            let headings = quadrantLabels.filter { title in
                list.staticTexts.matching(NSPredicate(format: "label == %@", title))
                    .allElementsBoundByAccessibilityElement.contains { $0.exists && $0.isHittable }
            }
            seenQuadrants.formUnion(headings)
            let visibleCards = list.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'task-card-'"))
                .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
            for card in visibleCards {
                let id = card.identifier
                let label = card.label
                if let prior = labels[id] {
                    try require(prior == label, "A task changed while the Matrix was being traversed.")
                }
                labels[id] = label
            }
            // Include visible cell positions, not only task IDs: consecutive rows may be empty.
            var viewport = list.cells.allElementsBoundByAccessibilityElement
                .filter { $0.exists && $0.isHittable }
                .map { cell in
                    let frame = cell.frame
                    return "cell:\(Int(frame.minY.rounded())):\(Int(frame.height.rounded()))"
                }
            try require(!viewport.isEmpty, "The observed Matrix has no hittable native cells.")
            viewport += visibleCards.map { "task:\($0.identifier):\(Int($0.frame.minY.rounded()))" }
            for title in headings {
                viewport += list.staticTexts.matching(NSPredicate(format: "label == %@", title))
                    .allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
                    .map { "heading:\(title):\(Int($0.frame.minY.rounded()))" }
            }
            viewport.sort()
            checkpoints.append([
                "step": step, "visibleQuadrants": headings,
                "visibleTaskIDs": visibleCards.map(\.identifier).sorted(),
                "visibleCellFrames": viewport
            ])
            // At least one upward gesture must leave the viewport unchanged, with Q4 visible
            // and every preceding quadrant observed. An arbitrary swipe count is not coverage.
            if step > 0, viewport == previousViewport,
               headings.contains("לוותר"), seenQuadrants == Set(quadrantLabels) {
                reachedBottom = true
            }
            try writeJSON([
                "allQuadrantsObserved": seenQuadrants == Set(quadrantLabels),
                "bottomObserved": reachedBottom, "checkpoints": checkpoints,
                "uniqueTaskIDs": labels.keys.sorted()
            ], name: phase + ".matrix-traversal.json")
            if reachedBottom { break }
            previousViewport = viewport
            if step < 8 { try scrollMatrixContent(app, list: list, swipingUp: true, phase: phase + "-scroll-\(step)") }
        }
        try capture(app, phase)
        try require(reachedBottom,
                    "Bounded native scrolling did not establish every Matrix quadrant and its bottom.")
        if let marker, !labels.values.contains(where: { $0.contains(marker) }) {
            // Retain the original 20-second positive readiness wait, now at the observed Q4
            // viewport where the default Share task belongs. Re-scan all quadrants if it lands.
            try require(cards(app, containing: marker).firstMatch.waitForExistence(timeout: 20),
                        "No task card contains synthetic marker \(marker) after traversing the Matrix.")
            return try matrixCards(app, phase: phase + "-after-wait")
        }
        return labels
    }

    private func scrollMatrixToTop(_ app: XCUIApplication) throws -> XCUIElement {
        // The app reloads its canonical store after the extension returns.
        // Keep a resolving query while that update replaces native list elements,
        // instead of holding an accessibility-identity snapshot across the update.
        let lists = app.collectionViews
        let list = lists.firstMatch
        guard list.waitForExistence(timeout: 15), lists.count == 1 else {
            try capture(app, "matrix-list-identity-failure")
            throw SystemSurfaceFailure(message: "The observed Matrix CollectionView is not unique.")
        }
        // Share dismissal exposed a visible list whose wrapper had no computed
        // hit point. Establish readiness on actual native content, then prove
        // scrolling and persistence through the existing outcome assertions.
        let deadline = Date().addingTimeInterval(15)
        var contentReady = false
        repeat {
            let viewport = try matrixContentViewport(app, list: list)
            contentReady = !matrixScrollAnchors(list, viewport: viewport).isEmpty
            if contentReady { break }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        guard contentReady else {
            try capture(app, "matrix-content-hittability-failure")
            throw SystemSurfaceFailure(message: "The observed Matrix has no visible hittable native content.")
        }
        for step in 0...6 {
            let today = list.staticTexts.matching(NSPredicate(format: "label == %@", "היום, 0 מתוך 3"))
                .allElementsBoundByAccessibilityElement.contains { $0.exists && $0.isHittable }
            let first = list.staticTexts.matching(NSPredicate(format: "label == %@", "לביצוע מיידי"))
                .allElementsBoundByAccessibilityElement.contains { $0.exists && $0.isHittable }
            if today && first { return list }
            if step < 6 { try scrollMatrixContent(app, list: list, swipingUp: false, phase: "matrix-to-top-\(step)") }
        }
        throw SystemSurfaceFailure(message: "Bounded native scrolling did not reveal the Matrix Today and Q1 headings.")
    }

    private func matrixContentViewport(_ app: XCUIApplication, list: XCUIElement) throws -> CGRect {
        let visible = list.frame.intersection(app.frame)
        try require(!visible.isNull && !visible.isEmpty, "The Matrix list has no visible screen intersection.")
        var top = visible.minY
        var bottom = visible.maxY
        let navigation = app.navigationBars.firstMatch
        if navigation.exists { top = max(top, navigation.frame.maxY) }
        let captureField = app.textFields["capture-field"]
        if captureField.exists { top = max(top, captureField.frame.maxY) }
        let tabs = app.tabBars.firstMatch
        if tabs.exists { bottom = min(bottom, tabs.frame.minY) }
        try require(visible.width > 60 && bottom - top > 104,
                    "The observed Matrix content viewport is too small for a contained native scroll.")
        let viewport = CGRect(x: visible.minX + 8, y: top + 8,
                              width: visible.width - 16, height: bottom - top - 16)
        return viewport
    }

    private func matrixScrollAnchors(_ list: XCUIElement, viewport: CGRect)
        -> [(element: XCUIElement, frame: CGRect)] {
        // Prefer noninteractive native section labels over draggable task rows.
        // All labels below are already required by the Matrix traversal.
        let headings = list.staticTexts.matching(NSPredicate(format: "label IN %@",
            ["היום, 0 מתוך 3", "לביצוע מיידי", "לתכנן", "להעביר לאחרים", "לוותר"] as NSArray))
        for query in [headings, list.cells] {
            let anchors = query.allElementsBoundByAccessibilityElement.compactMap { element
                -> (element: XCUIElement, frame: CGRect)? in
                guard element.exists, element.isHittable else { return nil }
                let frame = element.frame
                guard !frame.isEmpty, viewport.contains(frame) else { return nil }
                return (element: element, frame: frame)
            }
            if !anchors.isEmpty { return anchors }
        }
        return []
    }

    private func scrollMatrixContent(_ app: XCUIApplication, list: XCUIElement,
                                     swipingUp: Bool, phase: String) throws {
        let viewport = try matrixContentViewport(app, list: list)
        let anchors = matrixScrollAnchors(list, viewport: viewport).sorted {
            swipingUp ? $0.frame.midY > $1.frame.midY : $0.frame.midY < $1.frame.midY
        }
        let assistant = app.buttons["hanlin.assistant.open"]
        let overlay = assistant.exists ? assistant.frame.insetBy(dx: -2, dy: -2) : .null
        for anchor in anchors {
            let start = CGPoint(x: anchor.frame.midX, y: anchor.frame.midY)
            let endY = swipingUp
                ? max(viewport.minY + 4, start.y - viewport.height * 0.6)
                : min(viewport.maxY - 4, start.y + viewport.height * 0.6)
            let end = CGPoint(x: start.x, y: endY)
            let path = CGRect(x: start.x - 1, y: min(start.y, end.y),
                              width: 2, height: abs(end.y - start.y))
            guard viewport.contains(start), viewport.contains(end),
                  path.height >= 44, !overlay.intersects(path) else { continue }
            try writeJSON([
                "listFrame": NSCoder.string(for: list.frame),
                "viewport": NSCoder.string(for: viewport),
                "anchorFrame": NSCoder.string(for: anchor.frame),
                "anchorLabel": anchor.element.label,
                "anchorIdentifier": anchor.element.identifier,
                "anchorHittable": anchor.element.isHittable,
                "assistantFrame": NSCoder.string(for: overlay),
                "start": NSCoder.string(for: start), "end": NSCoder.string(for: end)
            ], name: phase + ".matrix-scroll.json")
            try require(anchor.element.isHittable,
                        "The observed Matrix scroll origin stopped being hittable.")
            let appFrame = app.frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: start.x - appFrame.minX, dy: start.y - appFrame.minY))
            let to = origin.withOffset(CGVector(dx: end.x - appFrame.minX, dy: end.y - appFrame.minY))
            from.press(forDuration: 0.01, thenDragTo: to)
            return
        }
        try capture(app, phase + "-no-contained-scroll-origin")
        throw SystemSurfaceFailure(message: "No measured hittable Matrix content origin has a contained native scroll path.")
    }

    private func relaunch(_ app: XCUIApplication, captureName: String) throws {
        app.terminate()
        try require(app.state == .notRunning, "Persistence check requires GSD to be terminated.")
        app.launch()
        try captureRaw(captureName + "-before-query")
        try requireMatrix(app)
        try capture(app, captureName)
    }

    private func openShareCompose(_ app: XCUIApplication, originalID: String,
                                  phase: String) throws -> XCUIApplication {
        _ = try scrollMatrixToTop(app)
        let original = app.descendants(matching: .any).matching(identifier: originalID).firstMatch
        try captureRaw(phase + "-before-task-query")
        try require(original.waitForExistence(timeout: 10) && original.isHittable,
                    "The original task cannot receive its Share context-menu gesture.")
        original.press(forDuration: 1)
        let share = app.buttons["שיתוף"]
        try capture(app, phase + "-task-menu")
        try require(share.waitForExistence(timeout: 8) && share.isHittable,
                    "The source-defined Hebrew Share action is unavailable.")
        share.tap()
        try capture(app, phase + "-activity-sheet")
        let roots = try activityRoots(app)
        let activity = try uniqueObservedShareActivity("GSD", roots: roots, phase: phase)
        try shareAssertion("activitySheetOpened")
        activity.tap()
        try captureRaw(phase + "-extension-before-query")
        for root in roots {
            if root.navigationBars["הוספה ל־GSD"].waitForExistence(timeout: 8) {
                try captureHierarchy(root, phase + "-extension")
                return root
            }
        }
        throw SystemSurfaceFailure(message: "GSD activity was selected, but the source-defined Hebrew extension title did not appear. Inspect preserved system evidence.")
    }

    private func activityRoots(_ app: XCUIApplication) throws -> [XCUIApplication] {
        var roots = [app]
        let springboard = XCUIApplication(bundleIdentifier: springboardBundle)
        let state = springboard.state
        let running = state == .runningForeground || state == .runningBackground || state == .runningBackgroundSuspended
        try observe("shareText", status: "incomplete", details: [
            "springboardInInventory": installedBundles.contains(springboardBundle),
            "springboardObservedState": state.rawValue, "springboardRunning": running
        ])
        if running { roots.append(springboard) }
        return roots
    }

    private func uniqueObservedShareActivity(_ title: String, roots: [XCUIApplication], phase: String) throws -> XCUIElement {
        for root in roots {
            // Observed on this driver/runtime: GSD is a shareCell inside ActivityListView.
            let sheets = root.otherElements.matching(identifier: "ActivityListView")
            guard sheets.firstMatch.waitForExistence(timeout: 5) else { continue }
            try require(sheets.count == 1, "The observed activity sheet is ambiguous.")
            let matches = sheets.firstMatch.cells.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", "shareCell", title))
            if matches.firstMatch.waitForExistence(timeout: 5) {
                try require(matches.count == 1 && matches.firstMatch.isHittable,
                            "Observed share activity \(title) is ambiguous or obscured.")
                return matches.firstMatch
            }
        }
        // Retain settled hosts after both lookups, not only the immediate post-menu frame.
        for (index, root) in roots.enumerated() where root.state != .notRunning {
            try capture(root, phase + "-post-wait-root-" + String(index))
        }
        throw SystemSurfaceFailure(message: "The observed activity sheet exposes no hittable GSD shareCell. Inspect its post-wait host hierarchy before adding a system selector.")
    }

    private func enterMarker(_ marker: String, expectedSourceTitle: String, phase: String,
                             in host: XCUIApplication) throws {
        // The actual title keeps this identity whether empty or prefilled.
        let fields = host.textFields.matching(identifier: "share.title")
        let textViews = host.textViews.matching(identifier: "share.title")
        var readyTitle: XCUIElement?
        let deadline = Date().addingTimeInterval(10)
        repeat {
            let candidates = fields.allElementsBoundByAccessibilityElement +
                textViews.allElementsBoundByAccessibilityElement
            if candidates.count == 1, let candidate = candidates.first,
               candidate.exists, candidate.isEnabled, candidate.isHittable {
                readyTitle = candidate
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        // Preserve the settled compose state before checking or changing the synthetic payload.
        try capture(host, phase + "-settled-before-prefill")
        guard let title = readyTitle else {
            throw SystemSurfaceFailure(message: "The unique observed Share title field did not become enabled and hittable.")
        }
        guard let prefilled = title.value as? String, prefilled.contains(expectedSourceTitle) else {
            throw SystemSurfaceFailure(message: "The real Share extension did not prefill the original source-task title.")
        }
        title.tap()
        // Insert a distinct short marker without guessing Select All/system keyboard labels.
        title.typeText(" " + marker)
        guard let value = title.value as? String else {
            throw SystemSurfaceFailure(message: "The edited Share title value is unavailable.")
        }
        try require(value.contains(marker) && value.count <= 80,
                    "The distinct Share title marker was not entered within the normal task-title limit.")
    }

    private func tapComposeAction(_ title: String, in host: XCUIApplication) throws {
        let bar = host.navigationBars["הוספה ל־GSD"]
        let action = bar.buttons[title]
        try require(action.waitForExistence(timeout: 5) && action.isEnabled && action.isHittable,
                    "The source-defined Share action \(title) is unavailable.")
        action.tap()
        try require(bar.waitForNonExistence(timeout: 20), "The real Share extension did not dismiss after \(title).")
    }

    private func discoverHost(_ bundle: String, surface: String, name: String) throws {
        guard installedBundles.contains(bundle) else {
            try observe(surface, status: "incomplete", details: [
                "bundleID": bundle, "hostInInventory": false, "actionExecuted": false,
                "reason": "The owned simulator inventory does not list this host."
            ])
            return
        }
        let host = XCUIApplication(bundleIdentifier: bundle)
        host.launch()
        defer { host.terminate() }
        try captureRaw(name)
        try observe(surface, status: "incomplete", details: [
            "bundleID": bundle, "hostInInventory": true,
            "hostForegroundObserved": host.state == .runningForeground, "actionExecuted": false,
            "reason": "Initial host discovery only; no unobserved OS action selector is guessed."
        ])
        try captureHierarchy(host, name)
    }

    private func capture(_ app: XCUIApplication, _ name: String) throws {
        try captureRaw(name)
        try captureHierarchy(app, name)
    }

    private func captureRaw(_ name: String) throws {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try shot.pngRepresentation.write(to: artifacts.appendingPathComponent(name + ".png"), options: .atomic)
        guard let pixels = shot.image.cgImage else {
            throw SystemSurfaceFailure(message: "Screenshot has no pixel dimensions: \(name)")
        }
        let orientation = shot.image.imageOrientation
        let swapped = [UIImage.Orientation.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        try writeJSON([
            "rawFullScreenCapture": true, "appFrameQueried": false,
            "pixelWidth": pixels.width, "pixelHeight": pixels.height,
            "imageOrientation": orientation.rawValue,
            "displayedWidth": swapped ? pixels.height : pixels.width,
            "displayedHeight": swapped ? pixels.width : pixels.height,
            "deviceOrientation": XCUIDevice.shared.orientation.rawValue
        ], name: name + ".geometry.json")
    }

    private func captureHierarchy(_ app: XCUIApplication, _ name: String) throws {
        try writeJSON(["hierarchyRequestStarted": true, "hierarchyCompleted": false],
                      name: name + ".hierarchy-status.json")
        let tree = app.debugDescription
        try tree.write(to: artifacts.appendingPathComponent(name + ".hierarchy.txt"),
                       atomically: true, encoding: .utf8)
        try writeJSON(["hierarchyRequestStarted": true, "hierarchyCompleted": true,
                       "bytes": tree.utf8.count], name: name + ".hierarchy-status.json")
    }

    private func loadObservations(simulatorID: String) throws {
        let url = artifacts.appendingPathComponent("system-surface-observations.json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard let prior = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  prior["simulatorID"] as? String == simulatorID,
                  prior["appSourceSHA"] as? String == sourceSHA else {
                throw SystemSurfaceFailure(message: "Existing observation receipt belongs to another simulator/source.")
            }
            observations = prior
        } else {
            observations = [
                "schemaVersion": 1, "appSourceSHA": sourceSHA, "simulatorID": simulatorID,
                "language": "he", "discoveryOnly": true, "coverageComplete": false,
                "installedBundleIDs": installedBundles.sorted(),
                "surfaces": [
                    "shareText": ["status": "unknown"],
                    "shareWebURL": ["status": "unknown"],
                    "widgetKit": ["status": "unknown"],
                    "shortcuts": ["status": "unknown"],
                    "accessibility": ["status": "unknown"],
                    "voiceOver": ["status": "unknown"]
                ]
            ]
        }
        try persist()
    }

    private func observe(_ surface: String, status: String, details: [String: Any]) throws {
        var surfaces = observations["surfaces"] as? [String: [String: Any]] ?? [:]
        var current = surfaces[surface] ?? [:]
        current["status"] = status
        for (key, value) in details { current[key] = value }
        surfaces[surface] = current
        observations["surfaces"] = surfaces
        try persist()
    }

    private func shareAssertion(_ name: String) throws {
        let surfaces = observations["surfaces"] as? [String: [String: Any]] ?? [:]
        var assertions = surfaces["shareText"]?["assertions"] as? [String: Bool] ?? [:]
        assertions[name] = true
        try observe("shareText", status: "incomplete", details: ["assertions": assertions])
    }

    private func persist() throws {
        observations["coverageComplete"] = false
        try writeJSON(observations, name: "system-surface-observations.json")
    }

    private func writeJSON(_ object: [String: Any], name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifacts.appendingPathComponent(name), options: .atomic)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SystemSurfaceFailure(message: message) }
    }
}
