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
        try enterMarker(addedMarker, in: addHost)
        try capture(addHost, "04-share-compose-add")
        try tapComposeAction("הוספה", in: addHost)
        app.activate()
        try captureRaw("05-after-add-before-query")
        try requireMatrix(app)
        let addedID = try uniqueCard(app, containing: addedMarker).identifier
        try require(addedID != originalID,
                    "Share Add must create a distinct task instead of replacing the source task.")
        try shareAssertion("addCreatedExactlyOne")
        try capture(app, "05-added-in-gsd")
        try relaunch(app, captureName: "06-add-after-relaunch")
        try require(try uniqueCard(app, containing: addedMarker).identifier == addedID,
                    "The added task identity changed across a normal relaunch.")
        let preservedOriginal = app.descendants(matching: .any).matching(identifier: originalID)
        try require(preservedOriginal.firstMatch.waitForExistence(timeout: 20)
                    && preservedOriginal.count == 1
                    && preservedOriginal.firstMatch.label.contains(sourceTitle)
                    && !preservedOriginal.firstMatch.label.contains(addedMarker),
                    "Share Add must preserve the original task and its title after a normal relaunch.")
        try shareAssertion("addedTaskPersisted")

        let cancelHost = try openShareCompose(app, originalID: originalID, phase: "07-cancel")
        try shareAssertion("extensionOpenedForCancel")
        try enterMarker(cancelMarker, in: cancelHost)
        try capture(cancelHost, "08-share-compose-cancel")
        try tapComposeAction("ביטול", in: cancelHost)
        app.activate()
        try captureRaw("09-after-cancel-before-query")
        try requireMatrix(app)
        try requireNoCard(app, containing: cancelMarker)
        try shareAssertion("cancelCreatedNone")
        try capture(app, "09-after-cancel")
        try relaunch(app, captureName: "10-cancel-after-relaunch")
        try requireNoCard(app, containing: cancelMarker)
        try require(try uniqueCard(app, containing: addedMarker).identifier == addedID,
                    "Cancel must leave the previously added task intact.")
        try shareAssertion("cancelNoneAfterRelaunch")
    }

    private func normalApplication() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: appBundle)
        app.launchArguments = ["-AppleLanguages", "(he)", "-AppleLocale", "he_IL"]
        return app
    }

    private func requireMatrix(_ app: XCUIApplication) throws {
        let field = app.textFields["capture-field"]
        if !field.exists {
            let skip = app.buttons["דילוג"]
            if skip.waitForExistence(timeout: 10) {
                try require(skip.isHittable, "The normal onboarding Skip action is obscured.")
                skip.tap()
            }
        }
        try require(field.waitForExistence(timeout: 30), "Normal GSD did not reach the Matrix capture field.")
        try require(field.isEnabled, "The Matrix capture field is disabled.")
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

    private func requireNoCard(_ app: XCUIApplication, containing marker: String) throws {
        let query = cards(app, containing: marker)
        try require(!query.firstMatch.waitForExistence(timeout: 8),
                    "Cancel unexpectedly created a task containing synthetic marker \(marker).")
        try require(query.count == 0, "Cancelled synthetic task is present.")
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
        let activity = try uniqueSourceNamedButton("GSD", roots: roots)
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

    private func uniqueSourceNamedButton(_ title: String, roots: [XCUIApplication]) throws -> XCUIElement {
        for root in roots {
            let matches = root.buttons.matching(NSPredicate(format: "label == %@", title))
            if matches.firstMatch.waitForExistence(timeout: 5) {
                try require(matches.count == 1 && matches.firstMatch.isHittable,
                            "Source-named activity \(title) is ambiguous or obscured; no guessed system action is used.")
                return matches.firstMatch
            }
        }
        throw SystemSurfaceFailure(message: "The real activity sheet exposes no hittable GSD button. Extension availability/selector remains incomplete; inspect its captured hierarchy before adding a system selector.")
    }

    private func enterMarker(_ marker: String, in host: XCUIApplication) throws {
        let fields = host.textFields.matching(NSPredicate(format: "label == %@", "כותרת"))
        let textViews = host.textViews.matching(NSPredicate(format: "label == %@", "כותרת"))
        try require(fields.count + textViews.count == 1, "The source-defined Share title field is missing or ambiguous.")
        let title = fields.count == 1 ? fields.firstMatch : textViews.firstMatch
        try require(title.isHittable, "The Share title field is obscured.")
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
