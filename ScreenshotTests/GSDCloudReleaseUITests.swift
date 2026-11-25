import Foundation
import UIKit
import XCTest

private struct UIAcceptanceFailure: LocalizedError {
    let message: String
    let file: String
    let line: UInt

    var errorDescription: String? { "\(file):\(line): \(message)" }
}

// Recording an XCTest assertion with continueAfterFailure=false can interrupt
// an async test before its invocation unwinds. Throw without recording first,
// so the existing strict account teardown can run on the normal error path.
private func requireAcceptance(_ condition: Bool, _ message: String,
                               file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition else {
        throw UIAcceptanceFailure(message: message, file: String(describing: file), line: line)
    }
}

private func requireAcceptanceValue<T>(_ value: T?, _ message: String,
                                       file: StaticString = #fileID, line: UInt = #line) throws -> T {
    guard let value else {
        throw UIAcceptanceFailure(message: message, file: String(describing: file), line: line)
    }
    return value
}

/// Release acceptance on disposable simulators. Uses the real UI, TaskStore,
/// Keychain session and cloud endpoint; no app-only test authentication backdoor.
/// Scope: selected simulator screens, tab/sidebar RTL geometry, one chart range change,
/// and the Matrix element-description audit. This is not a VoiceOver focus/speech audit
/// or complete gesture, text-clipping, orientation, or manual-layout-direction coverage.
/// The widget test is an in-app view harness, not a WidgetKit timeline/deep-link test.
/// Share, Watch, Watch widgets, real Siri, system notifications, and physical devices
/// require separate runtime evidence. Cloud signup/sign-out/sign-in/deletion use the Hebrew
/// iPad simulator UI; personal ChatGPT authorization and plan inference are not exercised.
@MainActor
final class GSDCloudReleaseUITests: XCTestCase {
    private var language: String { ProcessInfo.processInfo.environment["GSD_TEST_LANGUAGE"] ?? "en" }
    private var hebrew: Bool { language == "he" }
    private func label(_ english: String, _ he: String) -> String { hebrew ? he : english }
    private var navigationAttempt = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    private func application(demo: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (demo ? ["--demo-seed"] : []) +
            ["-AppleLanguages", "(\(language))", "-AppleLocale", hebrew ? "he_IL" : "en_US"]
        return app
    }

    private func navigation(_ app: XCUIApplication, _ title: String) throws -> XCUIElement {
        let bar = app.tabBars.firstMatch
        if bar.exists { return bar.buttons[title].firstMatch }
        let sidebarIDs = [
            label("Matrix", "מטריצה"): "gsd.sidebar.matrix",
            label("Dashboard", "לוח בקרה"): "gsd.sidebar.dashboard",
            label("Saved", "שמורים"): "gsd.sidebar.saved",
            label("Archive", "ארכיון"): "gsd.sidebar.archive",
            label("Settings", "הגדרות"): "gsd.sidebar.settings"
        ]
        let identifier = try requireAcceptanceValue(sidebarIDs[title], "Unknown sidebar destination: \(title)")
        // SwiftUI propagates a row identifier to its decorative children. Resolve
        // the owning native Cell; the first matching descendant can be an Image.
        let rows = app.cells.containing(.any, identifier: identifier)
        try requireAcceptance(rows.firstMatch.waitForExistence(timeout: 15),
                              "Missing sidebar row: \(title)")
        try requireAcceptance(rows.count == 1, "Ambiguous sidebar row: \(title)")
        return rows.firstMatch
    }

    private func navigate(_ app: XCUIApplication, _ title: String, test: String = #function) throws {
        navigationAttempt += 1
        let checkpointName = "00-navigation-\(test.prefix(6))-\(navigationAttempt)"
        var checkpoint = try beginNavigationCheckpoint(checkpointName, destination: title)
        let item = try navigation(app, title)
        let exists = item.waitForExistence(timeout: 15)
        checkpoint?["stage"] = "existence-wait-returned"
        checkpoint?["exists"] = exists
        try saveNavigationCheckpoint(checkpoint, name: checkpointName)
        try requireAcceptance(exists, "Missing navigation item: \(title)")
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"), object: item)
        let result = XCTWaiter.wait(for: [hittable], timeout: 10)
        checkpoint?["stage"] = "hittability-wait-returned"
        checkpoint?["hittabilityWaitResult"] = result.rawValue
        try saveNavigationCheckpoint(checkpoint, name: checkpointName)
        try requireAcceptance(result == .completed, "Navigation item is obscured: \(title)")
        item.tap()
    }

    private func beginNavigationCheckpoint(_ name: String, destination: String) throws -> [String: Any]? {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        // Persist the screen before the first remote AX query. Never request a fresh
        // hierarchy/frame after a timeout; that request can stall for the same reason.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(language)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let destination = ProcessInfo.processInfo.environment["GSD_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let image = screenshot.image
        let pixels = try requireAcceptanceValue(image.cgImage, "Navigation screenshot has no bitmap")
        let swapsAxes: Bool
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let checkpoint: [String: Any] = [
            "schemaVersion": 1, "diagnosticOnly": true, "captureSource": "XCUIScreen.main",
            "name": name, "language": language, "destination": destination, "stage": "before-AX-query",
            "deviceOrientation": XCUIDevice.shared.orientation.rawValue,
            "imageOrientation": image.imageOrientation.rawValue,
            "pixelWidth": pixels.width, "pixelHeight": pixels.height,
            "displayedWidth": swapsAxes ? pixels.height : pixels.width,
            "displayedHeight": swapsAxes ? pixels.width : pixels.height
        ]
        try saveNavigationCheckpoint(checkpoint, name: name)
        return checkpoint
    }

    private func saveNavigationCheckpoint(_ checkpoint: [String: Any]?, name: String) throws {
        guard let checkpoint else { return }
        let data = try JSONSerialization.data(withJSONObject: checkpoint, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(language)-\(name)-\(checkpoint["stage"] as? String ?? "unknown")"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let destination = ProcessInfo.processInfo.environment["GSD_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try data.write(to: directory.appendingPathComponent(name + ".navigation.json"))
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) throws {
        // App-only captures were cropped on landscape iPad. Keep one unmodified
        // full-screen capture for both the attachment and the exported evidence.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(language)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // AX-derived application/window frames can stall; keep the raw screen first.
        if let destination = ProcessInfo.processInfo.environment["GSD_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let image = screenshot.image
        let pixels = try requireAcceptanceValue(image.cgImage, "Full-screen screenshot has no bitmap")
        let swapsAxes: Bool
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let displayedWidth = swapsAxes ? pixels.height : pixels.width
        let displayedHeight = swapsAxes ? pixels.width : pixels.height
        let appFrame = app.frame
        let orientationMatches = (displayedWidth > displayedHeight) == (appFrame.width > appFrame.height)
        let geometry: [String: Any] = [
            "schemaVersion": 1,
            "captureSource": "XCUIScreen.main",
            "name": name,
            "language": language,
            "appFrame": captureFrame(appFrame),
            "windowFrames": app.windows.allElementsBoundByIndex.map { captureFrame($0.frame) },
            "deviceOrientation": XCUIDevice.shared.orientation.rawValue,
            "imageOrientation": image.imageOrientation.rawValue,
            "pixelWidth": pixels.width,
            "pixelHeight": pixels.height,
            "displayedWidth": displayedWidth,
            "displayedHeight": displayedHeight,
            "orientationMatchesApp": orientationMatches
        ]
        if let destination = ProcessInfo.processInfo.environment["GSD_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(name + ".geometry.json"))
        }
        // Persist the raw failure evidence before checking its displayed orientation.
        try requireAcceptance(appFrame.width > 0, "App frame width is empty during capture")
        try requireAcceptance(appFrame.height > 0, "App frame height is empty during capture")
        try requireAcceptance(orientationMatches, "Full-screen screenshot orientation disagrees with app frame: \(name)")
    }

    private func captureFrame(_ frame: CGRect) -> [String: Double] {
        ["x": Double(frame.minX), "y": Double(frame.minY),
         "width": Double(frame.width), "height": Double(frame.height)]
    }

    private func accessibilityTextWithoutBidiControls(_ text: String) -> String {
        // Preserve every visible character, punctuation mark and digit. Localized
        // interpolation may surround values with Unicode direction controls.
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x061C, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069: false
            default: true
            }
        }))
    }

    private func captureSeededRecurringLabel(_ rawLabel: String) throws {
        // Called only for the built-in row in the disposable --demo-seed app.
        // Persist the original label before checking it; no account or user data.
        let receipt: [String: Any] = [
            "schemaVersion": 1,
            "language": language,
            "identifier": "browse-view-recurring",
            "rawLabel": rawLabel,
            "unicodeScalars": rawLabel.unicodeScalars.map { String(format: "U+%04X", $0.value) }
        ]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(language)-05-recurring-accessibility-label"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let destination = ProcessInfo.processInfo.environment["GSD_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("05-recurring-accessibility-label.json"))
        }
    }

    private func tapContextBackdrop(_ app: XCUIApplication, menuAction: XCUIElement) throws {
        // Resolve a coordinate through the visible menu's native window, not the
        // application root. Keep one physical tap and the caller's dismissal gate.
        let preview = app.otherElements.matching(
            NSPredicate(format: "label == %@", label("Preview", "תצוגה מקדימה"))
        ).firstMatch
        let menu = app.collectionViews.containing(.button, identifier: menuAction.label).firstMatch
        let window = app.windows.containing(.button, identifier: menuAction.label).firstMatch
        try requireAcceptance(preview.exists && menu.exists && window.exists,
                              "Context menu preview, collection, or owning window missing")
        try requireAcceptance(menuAction.isHittable, "Context menu anchor is not hittable")
        let windowFrame = window.frame
        let previewFrame = preview.frame
        let actionFrame = menuAction.frame
        let menuFrames = menu.buttons.allElementsBoundByIndex.map { $0.frame }
            .filter { !$0.isEmpty && !$0.isNull && $0.intersects(windowFrame) }
        try requireAcceptance(!menuFrames.isEmpty, "Context menu action frames missing")
        let menuFrame = menuFrames.reduce(CGRect.null) { $0.union($1) }
        let excluded = previewFrame.union(menuFrame).insetBy(dx: -24, dy: -24)
        let viewport = windowFrame.insetBy(dx: 24, dy: 24)
        let backdrop = CGRect(x: viewport.minX, y: viewport.minY,
                              width: viewport.width, height: excluded.minY - viewport.minY)
        try requireAcceptance(backdrop.width >= 44 && backdrop.height >= 44,
                              "Measured context-menu backdrop has no usable interior")
        let point = CGPoint(x: min(max(previewFrame.midX, backdrop.minX + 22), backdrop.maxX - 22),
                            y: backdrop.midY)
        try requireAcceptance(viewport.contains(point) && !excluded.contains(point),
                              "Context backdrop point overlaps menu/preview or leaves the window")
        let geometry: [String: Any] = [
            "schemaVersion": 1, "language": language,
            "anchorIdentifier": menuAction.identifier, "anchorLabel": menuAction.label,
            "windowFrame": captureFrame(windowFrame), "previewFrame": captureFrame(previewFrame),
            "menuFrame": captureFrame(menuFrame), "actionFrame": captureFrame(actionFrame),
            "backdropFrame": captureFrame(backdrop), "excludedFrame": captureFrame(excluded),
            "point": ["x": Double(point.x), "y": Double(point.y)]
        ]
        let data = try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(language)-03-context-backdrop-observed-elements"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let coordinate = measuredNativeCoordinate(
            on: menuAction, at: point,
            observationName: "\(language)-03-context-backdrop-native-coordinate") else {
            throw UIAcceptanceFailure(message: "Native context coordinate disagrees with measured backdrop",
                                      file: #fileID, line: #line)
        }
        guard let windowCoordinate = measuredNativeCoordinate(
            on: window, at: point,
            observationName: "\(language)-03-context-backdrop-window-coordinate") else {
            throw UIAcceptanceFailure(message: "Owning window coordinate could not be measured",
                                      file: #fileID, line: #line)
        }
        let actionPoint = coordinate.screenPoint
        let windowPoint = windowCoordinate.screenPoint
        let agreement = XCTAttachment(string:
            "displayTarget=\(point) actionNative=\(actionPoint) windowNative=\(windowPoint)")
        agreement.name = "\(language)-03-context-backdrop-coordinate-agreement"
        agreement.lifetime = .keepAlways
        add(agreement)
        try requireAcceptance(abs(actionPoint.x - windowPoint.x) < 1
                              && abs(actionPoint.y - windowPoint.y) < 1,
                              "Native action and owning window disagree on the backdrop target")
        coordinate.tap()
    }

    func test01LocalizedNavigationEditorChartsAndRTL() throws {
        let app = application(demo: true)
        app.launch()
        let matrix = label("Matrix", "מטריצה")
        let settings = label("Settings", "הגדרות")
        try navigate(app, matrix)
        let card = app.descendants(matching: .any).matching(identifier: "task-card-demo-deck").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Seeded Matrix content missing")
        XCTAssertTrue(app.textFields["capture-field"].exists)
        let matrixItem = try navigation(app, matrix)
        let settingsItem = try navigation(app, settings)
        XCTAssertTrue(settingsItem.exists)
        try capture(app, "01-matrix-diagnostic-before-assertion")
        if app.tabBars.firstMatch.exists {
            if hebrew {
                XCTAssertGreaterThan(matrixItem.frame.midX, settingsItem.frame.midX, "Hebrew tab order must mirror")
            } else {
                XCTAssertLessThan(matrixItem.frame.midX, settingsItem.frame.midX, "English tab order must remain LTR")
            }
        } else {
            if hebrew {
                XCTAssertGreaterThan(matrixItem.frame.midX, app.frame.midX, "Hebrew sidebar must be at the right")
            } else {
                XCTAssertLessThan(matrixItem.frame.midX, app.frame.midX, "English sidebar must be at the left")
            }
        }
        try capture(app, "01-matrix")
        try app.performAccessibilityAudit(for: [.sufficientElementDescription])
        card.tap()
        let cancel = app.buttons["editor-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), "Task editor did not open")
        XCTAssertEqual(cancel.label, label("Cancel", "ביטול"))
        let form = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5), "Task editor form is missing")
        XCTAssertTrue(form.isHittable, "Task editor form cannot receive gestures")
        form.swipeUp()
        let save = app.buttons["editor-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Editor save action disappeared after scroll")
        XCTAssertEqual(save.label, label("Save", "שמירה"))
        XCTAssertTrue(save.isEnabled, "Seeded task must remain saveable after scrolling")
        XCTAssertTrue(save.isHittable, "Editor save action is obscured after scrolling")
        try capture(app, "02-editor")
        cancel.tap()
        card.press(forDuration: 1)
        let completeAction = app.buttons[label("Complete", "סימון כהושלמה")]
        XCTAssertTrue(completeAction.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[label("Delete", "מחיקה")].exists)
        try capture(app, "03-context-menu")
        if hebrew && UIDevice.current.userInterfaceIdiom == .pad {
            try tapContextBackdrop(app, menuAction: completeAction)
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.50)).tap()
        }
        XCTAssertTrue(completeAction.waitForNonExistence(timeout: 5), "Context menu did not dismiss")
        try navigate(app, label("Dashboard", "לוח בקרה"))
        try capture(app, "04-dashboard-diagnostic-before-assertion")
        XCTAssertTrue(app.staticTexts[label("Completion Trend", "מגמת השלמה")]
            .waitForExistence(timeout: 10), "Dashboard chart section did not open")
        let dashboardScroll = app.scrollViews.firstMatch
        XCTAssertTrue(dashboardScroll.waitForExistence(timeout: 5), "Dashboard content is missing")
        let thirtyDays = app.segmentedControls.buttons[label("30d", "30 יום")].firstMatch
        for _ in 0..<3 where !thirtyDays.isHittable { dashboardScroll.swipeUp() }
        XCTAssertTrue(thirtyDays.waitForExistence(timeout: 5), "Dashboard range picker is missing")
        XCTAssertTrue(thirtyDays.isHittable, "Dashboard range picker is obscured")
        let sevenDayChart = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", label("Completion trend over 7 days", "מגמת השלמה לאורך 7 ימים"))).firstMatch
        XCTAssertTrue(sevenDayChart.waitForExistence(timeout: 5), "Seven-day chart is missing")
        thirtyDays.tap()
        let thirtyDayChart = app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", label("Completion trend over 30 days", "מגמת השלמה לאורך 30 ימים"))).firstMatch
        XCTAssertTrue(thirtyDayChart.waitForExistence(timeout: 5), "Chart did not respond to its range control")
        try capture(app, "04-dashboard")
        if UIDevice.current.userInterfaceIdiom == .pad {
            let quadrants = ["urgent-important", "not-urgent-important",
                             "urgent-not-important", "not-urgent-not-important"]
            let values = quadrants.map { app.staticTexts["dashboard.quadrant.value." + $0].firstMatch }
            for _ in 0..<3 where !values.allSatisfy({ $0.isHittable }) { dashboardScroll.swipeUp() }
            let assistant = app.buttons["hanlin.assistant.open"].firstMatch
            try capture(app, "04-quadrant-values-diagnostic-before-assertion")
            XCTAssertTrue(assistant.waitForExistence(timeout: 5), "Dashboard assistant is missing")
            XCTAssertTrue(assistant.isHittable, "Dashboard assistant is obscured")
            for (value, count) in zip(values, ["3", "3", "2", "2"]) {
                XCTAssertTrue(value.waitForExistence(timeout: 5), "Dashboard legend value is missing")
                XCTAssertEqual(accessibilityTextWithoutBidiControls(value.label), count, "Seeded quadrant value changed")
                XCTAssertTrue(value.isHittable, "Dashboard legend value is obscured")
                XCTAssertTrue(dashboardScroll.frame.contains(value.frame), "Dashboard legend value is clipped")
                XCTAssertFalse(value.frame.intersects(assistant.frame),
                               "Dashboard assistant covers a quadrant legend value")
            }
            try capture(app, "04-quadrant-values")
        }
        if app.tabBars.firstMatch.exists {
            // Scrolling collapses the compact tab bar; scrolling back reveals its destinations.
            dashboardScroll.swipeDown()
            try navigate(app, label("Browse", "עיון"))
            let savedLink = app.descendants(matching: .any).matching(identifier: "browse-saved").firstMatch
            XCTAssertTrue(savedLink.waitForExistence(timeout: 8), "Browse list did not open")
            XCTAssertTrue(savedLink.isHittable, "Browse content is obscured")
            // Locate the actual link independently from localized interpolation controls.
            let recurring = app.buttons["browse-view-recurring"].firstMatch
            for _ in 0..<3 where !recurring.isHittable { app.swipeUp() }
            let assistant = app.buttons["hanlin.assistant.open"].firstMatch
            try capture(app, "05-browse-diagnostic-before-assertion")
            XCTAssertTrue(recurring.waitForExistence(timeout: 5), "Recurring Tasks row is missing")
            let rawRecurringLabel = recurring.label
            try captureSeededRecurringLabel(rawRecurringLabel)
            XCTAssertEqual(accessibilityTextWithoutBidiControls(rawRecurringLabel),
                           label("Recurring Tasks, 1 tasks", "משימות חוזרות, מספר המשימות: 1"),
                           "Recurring Tasks accessibility label must contain its localized name and count")
            XCTAssertTrue(recurring.isHittable, "Recurring Tasks row cannot be reached")
            XCTAssertTrue(assistant.waitForExistence(timeout: 5), "Browse assistant action is missing")
            XCTAssertTrue(assistant.isHittable, "Browse assistant action is obscured")
            XCTAssertFalse(recurring.frame.intersects(assistant.frame),
                           "Browse assistant covers the Recurring Tasks row")
            try capture(app, "05-browse")
            recurring.tap()
            XCTAssertTrue(app.navigationBars[label("Recurring Tasks", "משימות חוזרות")]
                .waitForExistence(timeout: 8), "Recurring Tasks row did not open its destination")
            try capture(app, "05-recurring-tasks-opened")
        } else {
            // Regular iPad has no Browse tab. Its sidebar browses the Library directly.
            try navigate(app, label("Saved", "שמורים"))
            let savedLibrary = app.descendants(matching: .any).matching(identifier: "saved-library").firstMatch
            XCTAssertTrue(savedLibrary.waitForExistence(timeout: 8), "Sidebar did not open the Saved library")
            try capture(app, "05-browse")
        }
        if app.tabBars.firstMatch.exists {
            // Reveal the compact tab bar after scrolling to the lower Browse row.
            app.swipeDown()
        }
        try navigate(app, settings)
        let account = app.buttons["gsd.cloud.open"]
        for _ in 0..<4 where !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        try capture(app, "06-settings")
        account.tap()
        XCTAssertTrue(app.textFields["gsd.cloud.email"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["gsd.cloud.password"].exists)
        XCTAssertTrue(app.buttons["gsd.cloud.submit"].exists)
        try capture(app, "07-account-sign-in")
    }


    /// Covers provider copy and the original Hanlin SDK/provider-to-host execution
    /// path. Only provider HTTP is deterministic; task writes still require the UI
    /// approval and flow through the canonical store before their live card appears.
    func test04LocalizedHanlinProvidersAndChatGPTAccount() throws {
        let app = application(demo: true)
        app.launchArguments.append("--gsd-native-hanlin-fixture")
        app.launch()
        try navigate(app, label("Matrix", "מטריצה"))
        let assistant = app.buttons[label("Open Hanlin task AI assistant", "פתיחת עוזר המשימות של Hanlin")].firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 15))
        assistant.tap()

        let modelTitle = label("Hanlin model settings", "הגדרות המודל של Hanlin")
        let settings = app.navigationBars[modelTitle]
        // A fresh provider configuration opens this sheet automatically.
        if !settings.waitForExistence(timeout: 5) {
            let model = app.buttons[label("Model", "מודל")].firstMatch
            XCTAssertTrue(model.waitForExistence(timeout: 5))
            model.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        try capture(app, "12-hanlin-model-settings")

        let providerName = label("Provider", "ספק")
        let provider = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", providerName)).firstMatch
        if provider.exists {
            provider.tap()
        } else {
            let currentProvider = app.buttons["OpenRouter"].firstMatch
            XCTAssertTrue(currentProvider.waitForExistence(timeout: 5), "Provider picker is not reachable")
            currentProvider.tap()
        }
        let plan = app.buttons[label("ChatGPT plan", "מכסת ChatGPT")].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["OpenRouter"].exists, "OpenRouter option must remain available")
        XCTAssertTrue(app.buttons["OpenAI"].exists, "OpenAI API option must remain available")
        try capture(app, "13-hanlin-provider-options")
        plan.tap()

        let accountSettings = app.buttons["hanlin.chatgpt.settings"]
        XCTAssertTrue(accountSettings.waitForExistence(timeout: 5))
        XCTAssertEqual(accountSettings.label, label("Continue with ChatGPT", "המשך עם ChatGPT"))
        accountSettings.tap()
        XCTAssertTrue(app.navigationBars[label("ChatGPT account", "חשבון ChatGPT")].waitForExistence(timeout: 5))
        let status = app.descendants(matching: .any).matching(identifier: "chatgpt.account.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        try capture(app, "14-chatgpt-account-diagnostic-before-assertion")
        XCTAssertEqual(status.label, label(
            "Continue with ChatGPT to use your plan for eligible AI requests.",
            "יש לבחור ״המשך עם ChatGPT״ כדי להשתמש במכסה שלך עבור בקשות AI הזכאיות לכך."))
        let continueButton = app.buttons["chatgpt.continue"]
        XCTAssertTrue(continueButton.exists)
        XCTAssertEqual(continueButton.label, label("Continue with ChatGPT", "המשך עם ChatGPT"))
        XCTAssertFalse(app.alerts[label("You're using your ChatGPT plan", "השימוש נעשה במכסת ChatGPT שלך")].exists,
                       "An unauthenticated fixture must not claim active ChatGPT plan use")
        try capture(app, "14-chatgpt-account-before-consent")
        // The actual authorization button is intentionally not activated.
        app.buttons[label("Done", "סיום")].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        app.buttons[label("Cancel", "ביטול")].firstMatch.tap()

        XCTAssertTrue(app.staticTexts[label("Task AI assistant", "עוזר המשימות")].waitForExistence(timeout: 5))
        try capture(app, "15-hanlin-assistant")
        app.buttons["MCP"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars[label("ChatGPT and GSD Cloud", "ChatGPT ו־GSD Cloud")].waitForExistence(timeout: 5))
        let plugin = app.links[label("Open GSD Tasks in ChatGPT", "פתיחת GSD Tasks ב־ChatGPT")].firstMatch
        let pluginButton = app.buttons[label("Open GSD Tasks in ChatGPT", "פתיחת GSD Tasks ב־ChatGPT")].firstMatch
        XCTAssertTrue(plugin.exists || pluginButton.exists, "Cloud plugin connection entry is missing")
        try capture(app, "16-cloud-plugin-connection")
        app.buttons[label("Done", "סיום")].firstMatch.tap()

        let workspaceEntry = app.buttons["gsd.assistant.workspace"]
        XCTAssertTrue(workspaceEntry.waitForExistence(timeout: 10))
        workspaceEntry.tap()
        let workspace = app.descendants(matching: .any).matching(identifier: "task-workspace").firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        try capture(app, "17-hanlin-live-workspace")
        app.buttons["task-workspace.create"].tap()
        XCTAssertTrue(app.textFields["editor-title"].waitForExistence(timeout: 10))
        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        app.buttons[label("Close", "סגירה")].firstMatch.tap()
        XCTAssertTrue(workspaceEntry.waitForExistence(timeout: 10))

        // Send through the real composer. The provider fixture requests create_task,
        // consumes its actual result ID, then requests show_task_workspace. It cannot
        // return final text until both real tool results satisfy its strict contract.
        let prompt = app.descendants(matching: .any).matching(identifier: "gsd.assistant.prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        prompt.tap()
        prompt.typeText("Create the Hanlin native workspace acceptance task and show it in a table.")
        app.buttons["gsd.assistant.send"].tap()
        let approval = app.buttons["gsd.assistant.allow-change"].firstMatch
        XCTAssertTrue(approval.waitForExistence(timeout: 20), "The real host write must request consent")
        try capture(app, "18-hanlin-create-approval")
        approval.tap()
        let ready = app.staticTexts["Hanlin native workspace ready."].firstMatch
        XCTAssertTrue(ready.waitForExistence(timeout: 30), "The original SDK did not consume both real tool results")
        let expand = app.buttons["gsd.assistant.expand-workspace"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 10), "The real show_task_workspace result did not render its card")
        let conversation = app.scrollViews["gsd.assistant.conversation"].firstMatch
        XCTAssertTrue(conversation.exists)
        for _ in 0..<6 where !expand.isHittable { conversation.swipeUp() }
        XCTAssertTrue(expand.isHittable)
        let createdTitle = "Hanlin native workspace acceptance"
        let inlineCreated = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "task-workspace.open.", createdTitle)).firstMatch
        XCTAssertTrue(inlineCreated.waitForExistence(timeout: 10))
        XCTAssertTrue(inlineCreated.isHittable, "The embedded card must expose its real task together with Expand")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Sending a task request must release the composer keyboard")
        try capture(app, "19-hanlin-real-tool-workspace-card")
        expand.tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        let created = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "task-workspace.open.", createdTitle)).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 10), "The expanded card lost the actual created task")
        XCTAssertTrue(created.isHittable)
        try capture(app, "20-hanlin-expanded-created-task")
        created.tap()
        let editor = app.textFields["editor-title"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, createdTitle, "The card must open the canonical created task")
        try capture(app, "21-hanlin-created-task-canonical-editor")
        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        app.buttons[label("Close", "סגירה")].firstMatch.tap()
        XCTAssertTrue(workspaceEntry.waitForExistence(timeout: 10))
        app.buttons[label("Close", "סגירה")].firstMatch.tap()
        app.terminate()
    }

    /// Uses the existing real widget view harness. This proves rendered strings
    /// and layout, not the separate SpringBoard WidgetKit timeline lifecycle.
    func test03LocalizedWidgetView() throws {
        let app = application(demo: false)
        app.launchArguments.insert("--demo-home", at: 0)
        app.launch()
        let screen = app.descendants(matching: .any).matching(identifier: "demo-home-screen").firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 15))
        let heading = app.staticTexts[label("Today's Focus", "המיקוד להיום")].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "Widget header was not localized")
        let overdue = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", label("overdue", "באיחור"))).firstMatch
        XCTAssertTrue(overdue.exists, "Widget due-state accessibility text was not localized")
        try capture(app, "11-widget-view")
        app.terminate()
    }

    private func pasteCloudPassword(_ value: String, into field: XCUIElement) throws {
        // A fresh simulator's pasteboard service can reject its first write.
        // Verify delivery on both sides of the standard paste gesture before
        // proceeding; do not mistake a secure field's placeholder for input.
        let pasteboard = UIPasteboard.general
        defer { pasteboard.items = [] }
        for _ in 0..<3 {
            pasteboard.setItems([["public.utf8-plain-text": value]], options: [
                .localOnly: true, .expirationDate: Date().addingTimeInterval(300)
            ])
            let clipboardReady = XCTNSPredicateExpectation(
                predicate: NSPredicate { object, _ in
                    (object as? UIPasteboard)?.string == value
                }, object: pasteboard)
            guard XCTWaiter.wait(for: [clipboardReady], timeout: 5) == .completed else { continue }
            try requireAcceptance(field.waitForExistence(timeout: 5),
                                  "Native secure input disappeared before paste")
            try requireAcceptance(field.wait(for: \.isHittable, toEqual: true, timeout: 5),
                                  "Native secure input is obscured before paste")
            field.tap()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey("v", modifierFlags: .command)
            let inputReady = XCTNSPredicateExpectation(
                predicate: NSPredicate { object, _ in
                    guard let input = object as? XCUIElement,
                          let entered = input.value as? String else { return false }
                    return entered != input.placeholderValue && entered.count == value.count
                }, object: field)
            if XCTWaiter.wait(for: [inputReady], timeout: 8) == .completed { return }
        }
        try requireAcceptance(false, "Generated fixture password did not reach the native secure input")
    }

    func test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload() async throws {
        guard ProcessInfo.processInfo.environment["GSD_CLOUD_SYSTEM_TEST"] == "1" else {
            throw XCTSkip("Live cloud acceptance requires explicit CI opt-in")
        }
        let base = ProcessInfo.processInfo.environment["GSD_CLOUD_TEST_BASE"] ??
            "https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud"
        let baseURL = try requireAcceptanceValue(URL(string: base), "Invalid cloud acceptance base URL")
        let fixture = CloudFixture(base: baseURL)
        // Register cleanup before any native signup work; the fixture never creates an account by API.
        addTeardownBlock { try await fixture.removeAccount() }
        let app = application(demo: false)
        app.launch()
        let skip = app.buttons[label("Skip", "דילוג")]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        try navigate(app, label("Settings", "הגדרות"))
        let open = app.buttons["gsd.cloud.open"]
        for _ in 0..<4 where !open.isHittable { app.swipeUp() }
        try requireAcceptance(open.waitForExistence(timeout: 10), "Native cloud account entry is missing")
        open.tap()
        let mode = app.segmentedControls["gsd.cloud.mode"]
        try requireAcceptance(mode.waitForExistence(timeout: 5), "Native account mode picker is missing")
        mode.buttons[label("Create account", "יצירת חשבון")].tap()
        let email = app.textFields["gsd.cloud.email"]
        try requireAcceptance(email.waitForExistence(timeout: 5), "Native cloud email field is missing")
        email.tap()
        email.typeText(fixture.email)
        let password = app.secureTextFields["gsd.cloud.password"]
        try pasteCloudPassword(fixture.password, into: password)
        let confirmation = app.secureTextFields["gsd.cloud.confirmation"]
        try requireAcceptance(confirmation.waitForExistence(timeout: 5), "Native signup confirmation is missing")
        try pasteCloudPassword(fixture.password, into: confirmation)
        let submit = app.buttons["gsd.cloud.submit"]
        try requireAcceptance(submit.label == label("Create GSD account", "יצירת חשבון GSD"), "Native signup action label is not localized")
        if !submit.wait(for: \.isEnabled, toEqual: true, timeout: 8) {
            let emailEntered = (email.value as? String) == fixture.email
            let passwordLength = (password.value as? String)?.count ?? 0
            let confirmationLength = (confirmation.value as? String)?.count ?? 0
            try requireAcceptance(false, "Valid native signup must enable submission " +
                "(email entered: \(emailEntered), secure field lengths: \(passwordLength), \(confirmationLength))")
        }
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        try requireAcceptance(submit.isHittable, "Native signup action is obscured")
        submit.tap()
        try requireAcceptance(email.waitForNonExistence(timeout: 30), "Native cloud signup did not finish")
        let signedIn = app.descendants(matching: .any).matching(identifier: "gsd.cloud.signed-in").firstMatch
        try requireAcceptance(signedIn.waitForExistence(timeout: 10), "Native signup did not establish a session")
        try capture(app, "08-account-created")
        // Authenticate only the account just created by the app, for server assertions and cleanup.
        try await fixture.authenticateExistingAccount()
        let signOut = app.buttons["gsd.cloud.sign-out"]
        try requireAcceptance(signOut.waitForExistence(timeout: 5), "Native sign-out action is missing")
        for _ in 0..<3 where !signOut.isHittable { app.swipeUp() }
        try requireAcceptance(signOut.isHittable, "Native sign-out action is obscured")
        signOut.tap()
        try requireAcceptance(signedIn.waitForNonExistence(timeout: 10), "Native sign-out did not clear the account UI")
        try requireAcceptance(open.waitForExistence(timeout: 10), "Native sign-in action did not return after sign-out")
        try capture(app, "08-account-signed-out")
        open.tap()
        try requireAcceptance(mode.waitForExistence(timeout: 5), "Native account mode picker is missing after sign-out")
        mode.buttons[label("Sign in", "התחברות")].tap()
        try requireAcceptance(email.waitForExistence(timeout: 5), "Native cloud email field is missing")
        try requireAcceptance(!confirmation.exists, "Ordinary sign-in must not require signup confirmation")
        email.tap()
        email.typeText(fixture.email)
        try pasteCloudPassword(fixture.password, into: password)
        try requireAcceptance(submit.label == label("Sign in to GSD Cloud", "התחברות ל־GSD Cloud"), "Native sign-in action label is not localized")
        try requireAcceptance(submit.isEnabled, "Valid native sign-in must enable submission")
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        try requireAcceptance(submit.isHittable, "Native sign-in action is obscured")
        submit.tap()
        try requireAcceptance(email.waitForNonExistence(timeout: 30), "Cloud sign-in did not finish")
        try requireAcceptance(signedIn.waitForExistence(timeout: 10), "Native sign-in did not restore the same account session")
        try capture(app, "08-account-connected")
        app.terminate()
        try requireAcceptance(app.state == .notRunning, "Server mutation must occur while native app is closed")
        let serverTitle = "Cloud closed app " + UUID().uuidString.prefix(8)
        let serverID = try await fixture.createTask(title: serverTitle)
        app.launch()
        try navigate(app, label("Matrix", "מטריצה"))
        let serverCard = app.descendants(matching: .any).matching(identifier: "task-card-" + serverID).firstMatch
        try requireAcceptance(serverCard.waitForExistence(timeout: 45), "Cloud task missing after closed-app mutation/relaunch")
        try requireAcceptance(serverCard.label.contains(serverTitle), "Closed-app task title differs from the fixture task")
        try capture(app, "09-closed-app-cloud-task")
        let localTitle = "Native upload " + UUID().uuidString.prefix(8)
        let field = app.textFields["capture-field"]
        try requireAcceptance(field.exists, "Native Matrix capture field is missing")
        field.tap()
        field.typeText(localTitle + " !!\n")
        let uploaded = try await fixture.waitForTask(title: localTitle)
        try requireAcceptance(uploaded, "Native TaskStore mutation did not reach Oracle")
        app.terminate()
        app.launch()
        try navigate(app, label("Matrix", "מטריצה"))
        let localCard = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'task-card-' AND label CONTAINS %@", localTitle)).firstMatch
        try requireAcceptance(localCard.waitForExistence(timeout: 30), "Local/cloud task did not persist across relaunch")
        try capture(app, "10-cloud-round-trip")

        // Delete only this same disposable account through the real native confirmation.
        try await fixture.verifyCurrentOwner()
        try navigate(app, label("Settings", "הגדרות"))
        let deleteAccount = app.buttons[label("Delete Account…", "מחיקת חשבון…")].firstMatch
        for _ in 0..<4 where !deleteAccount.isHittable { app.swipeUp() }
        try requireAcceptance(signedIn.waitForExistence(timeout: 5), "Account must be signed in before deletion")
        try requireAcceptance(deleteAccount.waitForExistence(timeout: 5), "Native account deletion is missing")
        try requireAcceptance(deleteAccount.isEnabled, "Native account deletion is disabled")
        try requireAcceptance(deleteAccount.isHittable, "Native account deletion is obscured")
        deleteAccount.tap()
        try requireAcceptance(app.staticTexts[label("Delete your account?", "למחוק את החשבון שלך?")]
            .waitForExistence(timeout: 5), "Account deletion confirmation is missing")
        let keepTasks = app.buttons[label("Delete & keep tasks on this device", "מחיקת החשבון ושמירת המשימות במכשיר")].firstMatch
        let eraseEverything = app.buttons[label("Delete & erase everything", "מחיקת החשבון וכל הנתונים")].firstMatch
        try requireAcceptance(keepTasks.waitForExistence(timeout: 5), "Keep-local-tasks choice is missing")
        try requireAcceptance(eraseEverything.waitForExistence(timeout: 5), "Erase-local-tasks choice is missing")
        try requireAcceptance(eraseEverything.isEnabled, "Erase-local-tasks choice is disabled")
        try requireAcceptance(eraseEverything.isHittable, "Erase-local-tasks choice is obscured")
        try capture(app, "17-delete-account-confirmation")
        eraseEverything.tap()
        try requireAcceptance(signedIn.waitForNonExistence(timeout: 30), "Native account deletion did not sign out")
        try requireAcceptance(open.waitForExistence(timeout: 10), "Sign-in must return after account deletion")
        try capture(app, "18-account-deleted-signed-out")
        try navigate(app, label("Matrix", "מטריצה"))
        try requireAcceptance(field.waitForExistence(timeout: 10), "Matrix did not open after account deletion")
        try requireAcceptance(serverCard.waitForNonExistence(timeout: 10), "Server-created task remains after erase")
        try requireAcceptance(localCard.waitForNonExistence(timeout: 10), "Native-created task remains after erase")
        try capture(app, "19-account-deleted-empty-matrix")
        // Public rejections prove credentials stopped working. Exact database/cascade absence
        // is independently checked on Oracle using only the sanitized owner marker below.
        try await fixture.verifyDeletionByApp()
        app.terminate()
    }
}

@MainActor
private final class CloudFixture {
    private struct User: Decodable, Sendable { let id: String }
    private struct Session: Decodable, Sendable { let token: String; let record: User }
    private struct Row: Decodable, Sendable { let task_id: String; let title: String }
    private struct Page: Decodable, Sendable { let items: [Row] }
    let base: URL
    let email = "gsd-native-ci-" + UUID().uuidString.lowercased() + "@example.test"
    let password = UUID().uuidString + "Aa1!"
    private var token: String?
    private var owner: String?
    private var deletionVerified = false
    private let session = URLSession(configuration: .ephemeral)

    init(base: URL) {
        self.base = base
        // Mask before any XCTest typing activity; all credentials belong to this disposable account.
        print("::add-mask::" + password)
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         includeAuthorization: Bool = true,
                         expectedRejection: (status: Int, message: String)? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if includeAuthorization, let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GSDCloudAcceptance", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Missing cloud HTTP response: \(method) \(path)"])
        }
        if let expected = expectedRejection {
            // PocketBase 0.40 uses status, not code. A generic 400/401/404 is insufficient:
            // require the exact endpoint error, empty details, and no successful session payload.
            let error = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard http.statusCode == expected.status,
                  error?["status"] as? Int == expected.status,
                  error?["message"] as? String == expected.message,
                  let details = error?["data"] as? [String: Any], details.isEmpty,
                  error?["token"] == nil, error?["record"] == nil else {
                throw NSError(domain: "GSDCloudAcceptance", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Unexpected cloud rejection: \(method) \(path)"])
            }
        } else if !(200...299).contains(http.statusCode) {
            throw NSError(domain: "GSDCloudAcceptance", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Cloud fixture request failed: \(method) \(path)"])
        }
        return data
    }

    func authenticateExistingAccount() async throws {
        let authData = try await request("api/collections/users/auth-with-password", method: "POST",
                                        body: ["identity": email, "password": password])
        let auth = try JSONDecoder().decode(Session.self, from: authData)
        token = auth.token
        owner = auth.record.id
    }

    func verifyCurrentOwner() async throws {
        let expectedOwner = try requireAcceptanceValue(owner, "Missing fixture owner before deletion")
        _ = try requireAcceptanceValue(token, "Missing fixture token before deletion")
        let data = try await request("api/collections/users/records/" + expectedOwner)
        let current = try JSONDecoder().decode(User.self, from: data)
        guard current.id == expectedOwner else {
            throw NSError(domain: "GSDCloudAcceptance", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Disposable account owner changed before deletion"])
        }
    }

    func verifyDeletionByApp() async throws {
        let deletedOwner = try requireAcceptanceValue(owner, "Missing fixture owner for deletion verification")
        _ = try requireAcceptanceValue(token, "Missing former token for deletion verification")
        guard deletedOwner.range(of: "^[A-Za-z0-9_-]{10,80}$", options: .regularExpression) != nil else {
            throw NSError(domain: "GSDCloudAcceptance", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid disposable owner identifier"])
        }
        _ = try await request("api/collections/users/records/" + deletedOwner,
                              expectedRejection: (404, "The requested resource wasn't found."))
        _ = try await request("api/collections/users/auth-refresh", method: "POST",
                              expectedRejection: (401, "The request requires valid record authorization token."))
        _ = try await request("api/collections/users/auth-with-password", method: "POST",
                              body: ["identity": email, "password": password], includeAuthorization: false,
                              expectedRejection: (400, "Failed to authenticate."))
        // This flag is reachable only after the native UI validations and all three explicit checks.
        // No failed authentication or generic HTTP error can silently skip teardown.
        deletionVerified = true
        token = nil
        owner = nil
        print("GSD_NATIVE_ACCOUNT_DELETION_PUBLIC_PASS owner=" + deletedOwner)
    }

    func removeAccount() async throws {
        defer { session.invalidateAndCancel() }
        if deletionVerified { return }
        // Native validation may fail after registration but before fixture authentication.
        // Recover only this fixture's credentials and propagate every failure, including 400.
        // An authentication failure is not evidence that no account exists.
        if token == nil { try await authenticateExistingAccount() }
        _ = try await request("api/gsd/account", method: "DELETE")
        token = nil
        owner = nil
    }

    func createTask(title: String) async throws -> String {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        let body: [String: Any] = [
            "owner": try requireAcceptanceValue(owner, "Missing fixture owner for task creation"), "task_id": id, "title": title,
            "urgent": true, "important": true, "completed": false, "recurrence": "none",
            "tags": [], "subtasks": [], "dependencies": [], "time_entries": [],
            "client_created_at": now, "client_updated_at": now, "device_id": "gsd-xcui-server"
        ]
        _ = try await request("api/collections/tasks/records", method: "POST", body: body)
        return id
    }

    func waitForTask(title: String) async throws -> Bool {
        for _ in 0..<20 {
            let data = try await request("api/collections/tasks/records")
            if try JSONDecoder().decode(Page.self, from: data).items.contains(where: { $0.title == title }) {
                return true
            }
            try await Task.sleep(for: .seconds(2))
        }
        return false
    }
}
