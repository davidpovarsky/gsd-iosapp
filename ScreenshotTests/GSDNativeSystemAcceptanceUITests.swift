import Foundation
import UIKit
import XCTest

private struct NativeSurfaceFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs only on a fresh, runner-owned simulator with the separately verified release app.
/// Discovery never stands in for an invoked Shortcut or an installed WidgetKit timeline.
@MainActor
final class GSDNativeSystemAcceptanceUITests: XCTestCase {
    private var artifacts = URL(fileURLWithPath: "/")
    private var proof: [String: Any] = [:]
    private let app = XCUIApplication(bundleIdentifier: "com.itorah.gsd")
    private let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func test00DiscoverCreateTaskActionEditor() throws {
        try prepare("shortcut-discovery")
        app.launch()
        try requireMatrix()
        XCUIDevice.shared.press(.home)
        try require(app.state != .runningForeground, "GSD must be backgrounded before Shortcuts.")
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        shortcuts.activate()
        let introduction = shortcuts.buttons["המשך"]
        if introduction.waitForExistence(timeout: 5) {
            try require(introduction.isHittable, "Shortcuts introduction is obscured.")
            introduction.tap()
            try require(introduction.waitForNonExistence(timeout: 10), "Shortcuts introduction remains.")
        }
        let create = shortcuts.buttons["main.button.newshortcut"]
        try require(create.waitForExistence(timeout: 10) && create.isHittable, "Observed New Shortcut button is unavailable.")
        create.tap()
        try capture(shortcuts, "01-action-picker")
        let search = shortcuts.searchFields["חיפוש"].firstMatch
        try require(search.waitForExistence(timeout: 10) && search.isHittable, "Observed action search is unavailable.")
        search.tap()
        try dismissObservedKeyboardIntroduction()
        search.typeText("GSD")
        try capture(shortcuts, "02-gsd-action-search")
        let action = label("יצירת משימה", in: shortcuts)
        if !action.waitForExistence(timeout: 8) {
            let category = label("GSD", in: shortcuts)
            try require(category.waitForExistence(timeout: 10) && category.isHittable, "GSD action/category is absent.")
            category.tap()
            try capture(shortcuts, "03-gsd-action-category")
        }
        try require(action.waitForExistence(timeout: 15) && action.isHittable, "Registered Create Task action is absent.")
        action.tap()
        try capture(shortcuts, "04-create-task-editor")
        proof["actionEditorOpened"] = true
        proof["scope"] = "action_editor_discovery_only"
        try persist()
        shortcuts.terminate()
        app.terminate()
    }

    func test01RealWidgetTimelineRefreshAndTaskTap() throws {
        try prepare("widget")
        let nonce = String(UUID().uuidString.prefix(8))
        let initialTitle = "GSD-Widget-A-" + nonce
        let updatedTitle = "GSD-Widget-B-" + nonce
        proof["initialTitle"] = initialTitle
        proof["updatedTitle"] = updatedTitle
        try persist()
        app.launch()
        try requireMatrix()
        let input = app.textFields["capture-field"]
        input.tap()
        try dismissObservedKeyboardIntroduction()
        input.typeText(initialTitle + " !!\n")
        let card = try uniqueCard(initialTitle)
        let cardID = card.identifier
        try require(card.label.contains("לביצוע מיידי") && !card.label.contains("!!"), "Capture shorthand did not create a Do First task.")
        proof["taskCardID"] = cardID
        try capture(app, "10-widget-source-task")

        XCUIDevice.shared.press(.home)
        try require(home.wait(for: .runningForeground, timeout: 10), "SpringBoard is not foreground.")
        let icon = home.icons.matching(identifier: "GSD").firstMatch
        for _ in 0..<2 where !icon.isHittable { home.swipeRight() }
        try require(icon.exists && icon.isHittable, "Observed GSD Home icon is unavailable.")
        icon.press(forDuration: 1.2)
        let medium = home.buttons["וידג׳ט בינוני"]
        try require(medium.waitForExistence(timeout: 10) && medium.isHittable, "Observed medium WidgetKit control is unavailable.")
        try capture(home, "11-widget-size-control")
        medium.tap()
        XCUIDevice.shared.press(.home)
        try capture(home, "11b-after-widget-placement")
        let initialRow = label(initialTitle, in: home)
        try require(initialRow.waitForExistence(timeout: 90)
                    && initialRow.wait(for: \.isHittable, toEqual: true, timeout: 10), "Installed Home widget did not display the real task.")
        try capture(home, "12-installed-widget-initial")
        proof["installedWidgetDisplayedInitialTask"] = true
        try persist()

        app.activate()
        try requireMatrix()
        let saved = try uniqueCard(initialTitle)
        try require(saved.identifier == cardID, "Task identity changed before update.")
        saved.tap()
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        try require(editor.waitForExistence(timeout: 10), "Task editor did not open.")
        let title = app.textFields.matching(NSPredicate(format: "value == %@", initialTitle)).firstMatch
        try require(title.waitForExistence(timeout: 10) && title.isHittable, "The task title field is unavailable.")
        title.tap()
        title.typeKey("a", modifierFlags: .command)
        title.typeText(updatedTitle)
        try require(title.value as? String == updatedTitle, "Native title edit did not contain the exact new value.")
        let save = app.buttons["editor-save"]
        try require(save.exists && save.isEnabled && save.isHittable, "Native Save is unavailable.")
        save.tap()
        try require(editor.waitForNonExistence(timeout: 15), "Task editor did not save.")
        let changed = try uniqueCard(updatedTitle)
        try require(changed.identifier == cardID, "Editing created a different task.")
        try capture(app, "13-widget-source-updated")

        XCUIDevice.shared.press(.home)
        try require(home.wait(for: .runningForeground, timeout: 10), "SpringBoard is not foreground after edit.")
        let updatedRow = label(updatedTitle, in: home)
        try require(updatedRow.waitForExistence(timeout: 90)
                    && updatedRow.wait(for: \.isHittable, toEqual: true, timeout: 10), "The installed widget did not refresh from the app's normal snapshot path.")
        try require(!label(initialTitle, in: home).exists, "The installed widget retained the stale title.")
        try capture(home, "14-installed-widget-refreshed")
        proof["realWidgetTimelineRefreshObserved"] = true
        try persist()
        updatedRow.tap()
        try require(app.wait(for: .runningForeground, timeout: 15), "Widget tap did not open GSD.")
        try require(editor.waitForExistence(timeout: 15), "Widget row tap did not open the task editor.")
        let destination = app.textFields.matching(NSPredicate(format: "value == %@", updatedTitle)).firstMatch
        try require(destination.waitForExistence(timeout: 10), "Widget tap opened a different destination.")
        try capture(app, "15-widget-row-task-editor")
        proof["widgetRowOpenedExactTask"] = true
        proof["scope"] = "real_home_widget_timeline_refresh_and_row_deep_link"
        proof["passed"] = true
        try persist()
        app.terminate()
    }


    func test02RunRegisteredCreateTaskShortcutAndVerifyPersistence() throws {
        try prepare("shortcut-invocation")
        let nonce = String(UUID().uuidString.prefix(8))
        let title = "GSD-Shortcut-" + nonce
        let shorthand = title + " !!"
        let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
        proof["scope"] = "registered_app_shortcut_background_create_and_persistence"
        proof["expectedTitle"] = title
        proof["taskParameter"] = shorthand
        proof["createdTaskVisibleAfterInvocation"] = false
        proof["persistedAfterRelaunch"] = false
        try persist()

        do {
            app.launch()
            try requireMatrix()
            let existing = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'task-card-' AND label BEGINSWITH %@", title + ", "))
            try require(existing.count == 0, "Synthetic Shortcut task unexpectedly exists before invocation.")
            app.terminate()
            try require(app.wait(for: .notRunning, timeout: 10), "GSD did not terminate before the background invocation.")
            proof["appNotRunningBeforeShortcut"] = true

            shortcuts.activate()
            let introduction = shortcuts.buttons["המשך"]
            if introduction.waitForExistence(timeout: 5) {
                try require(introduction.isHittable, "Observed Shortcuts introduction is obscured.")
                introduction.tap()
                try require(introduction.waitForNonExistence(timeout: 10), "Shortcuts introduction remains.")
            }
            try capture(shortcuts, "30-shortcuts-entry")
            let library = shortcuts.buttons.matching(NSPredicate(
                format: "identifier == %@ AND label == %@", "BackButton", "ספריה"))
            try require(library.firstMatch.waitForExistence(timeout: 10)
                        && library.count == 1 && library.firstMatch.isHittable,
                        "Observed Library navigation is unavailable.")
            library.firstMatch.tap()
            try capture(shortcuts, "31-shortcuts-library")

            // The app name and shortcut title are the production AppShortcuts metadata.
            // Unknown system ownership fails with a capture instead of a guessed identifier.
            let appRows = shortcuts.cells.containing(.staticText, identifier: "GSD")
            for _ in 0..<3 where !appRows.firstMatch.isHittable { shortcuts.swipeUp() }
            try capture(shortcuts, "32-gsd-app-shortcut-row")
            try require(appRows.count == 1 && appRows.firstMatch.isHittable,
                        "One native GSD App Shortcuts row is required.")
            appRows.firstMatch.tap()
            try capture(shortcuts, "33-registered-gsd-shortcuts")
            let actions = shortcuts.buttons.matching(NSPredicate(
                format: "label BEGINSWITH %@", "הוספת משימה"))
            try require(actions.firstMatch.waitForExistence(timeout: 15),
                        "Registered Add Task App Shortcut is absent.")
            let visibleActions = actions.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.isHittable }
            try require(visibleActions.count == 1, "Registered Add Task control is not uniquely owned.")
            let action = visibleActions[0]
            proof["registeredAppShortcutLabel"] = action.label
            proof["registeredAppShortcutIdentifier"] = action.identifier
            try requireAppOutsideForeground("GSD became foreground before the Shortcut ran.")
            action.tap()
            try capture(shortcuts, "34-required-task-prompt")

            // CreateTaskIntent has one required String parameter. Select the native field
            // by its unique role in this prompt, never by the value that the test will enter.
            let fields = shortcuts.textFields
            try require(fields.firstMatch.waitForExistence(timeout: 15) && fields.count == 1,
                        "The required Task prompt must expose one native text field.")
            let taskField = fields.firstMatch
            try require(taskField.wait(for: \.isHittable, toEqual: true, timeout: 10),
                        "The required Task field is obscured.")
            proof["requiredTaskControl"] = [
                "identifier": taskField.identifier,
                "label": taskField.label,
                "elementType": "textField"
            ]
            taskField.tap()
            try dismissObservedKeyboardIntroduction()
            taskField.typeText(shorthand)
            try require(taskField.value as? String == shorthand,
                        "The native required Task input does not contain the exact shorthand.")
            try requireAppOutsideForeground("GSD became foreground while entering the Task parameter.")
            try capture(shortcuts, "35-required-task-entered")
            taskField.typeText("\n")
            try require(taskField.waitForNonExistence(timeout: 30),
                        "Native keyboard submission did not complete the required Task prompt.")
            try require(shortcuts.state == .runningForeground, "Shortcuts must own the completed invocation UI.")
            let invocationAppState = try requireAppOutsideForeground(
                "CreateTask must execute with GSD in a known nonforeground state.")
            proof["requiredTaskSubmittedFromShortcuts"] = true
            proof["appStateAfterShortcut"] = invocationAppState.rawValue
            try capture(shortcuts, "36-shortcut-returned")

            app.activate()
            try requireMatrix()
            let created = try uniqueCard(title)
            try require(created.label.contains("לביצוע מיידי") && !created.label.contains("!!"),
                        "The actual Shortcut did not apply the Do First shorthand.")
            let taskID = created.identifier
            proof["taskCardID"] = taskID
            proof["createdTaskVisibleAfterInvocation"] = true
            try capture(app, "37-shortcut-created-task")

            app.terminate()
            try require(app.wait(for: .notRunning, timeout: 10), "GSD did not terminate before persistence verification.")
            app.launch()
            try requireMatrix()
            let persisted = try uniqueCard(title)
            try require(persisted.identifier == taskID
                        && persisted.label.contains("לביצוע מיידי") && !persisted.label.contains("!!"),
                        "The same Shortcut-created task did not persist after normal relaunch.")
            try capture(app, "38-shortcut-task-after-relaunch")
            proof["persistedAfterRelaunch"] = true
            proof["shortcutInvoked"] = true
            proof["passed"] = true
            try persist()
            shortcuts.terminate()
            app.terminate()
        } catch {
            proof["failure"] = String(describing: error)
            try? capture(shortcuts, "99-shortcuts-failure")
            try? capture(home, "99-system-owner-failure")
            try? persist()
            throw error
        }
    }

    @discardableResult
    private func requireAppOutsideForeground(_ message: String) throws -> XCUIApplication.State {
        let state = app.state
        switch state {
        case .notRunning, .runningBackground, .runningBackgroundSuspended:
            return state
        default:
            throw NativeSurfaceFailure(message: message)
        }
    }

    private func prepare(_ name: String) throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw NativeSurfaceFailure(message: "Owned simulator required.")
        #else
        let env = ProcessInfo.processInfo.environment
        guard env["GSD_SYSTEM_ACCEPTANCE_FRESH_SIMULATOR"] == "1",
              let id = env["GSD_SYSTEM_ACCEPTANCE_SIMULATOR_UDID"], UUID(uuidString: id) != nil,
              let source = env["GSD_SYSTEM_ACCEPTANCE_APP_SOURCE"], source.count == 40,
              let path = env["GSD_SYSTEM_ACCEPTANCE_ARTIFACTS"], path.hasPrefix("/"),
              env["GSD_TEST_LANGUAGE"] == "he" else {
            throw NativeSurfaceFailure(message: "Missing owned simulator/source/artifact contract.")
        }
        artifacts = URL(fileURLWithPath: path).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        app.launchArguments = ["-AppleLanguages", "(he)", "-AppleLocale", "he_IL"]
        XCUIDevice.shared.orientation = .portrait
        proof = ["schemaVersion": 1, "productionSourceSHA": source, "simulatorID": id,
                 "passed": false, "shortcutInvoked": false, "personalAccountUsed": false,
                 "siriVerified": false, "voiceOverSpeechVerified": false, "watchConnectivityVerified": false]
        try persist()
        #endif
    }

    private func requireMatrix() throws {
        let skip = app.buttons["דילוג"]
        if skip.waitForExistence(timeout: 5) && skip.isHittable {
            skip.tap()
            try require(skip.waitForNonExistence(timeout: 10), "Onboarding did not dismiss.")
        }
        let field = app.textFields["capture-field"]
        try require(field.waitForExistence(timeout: 30), "Ordinary GSD launch did not reach Matrix.")
        try dismissObservedKeyboardIntroduction()
        try require(field.wait(for: \.isHittable, toEqual: true, timeout: 10), "Matrix capture is obscured.")
    }

    private func dismissObservedKeyboardIntroduction() throws {
        let intro = home.otherElements["UIContinuousPathIntroductionView"]
        guard intro.exists else { return }
        let explanation = intro.staticTexts["ניתן להאיץ את ההקלדה באמצעות החלקת האצבע על האותיות בנתיב הקלדה כדי ליצור מילה."]
        let button = intro.buttons["המשך"]
        try require(explanation.exists && button.isHittable, "Observed keyboard introduction changed.")
        button.tap()
        try require(intro.waitForNonExistence(timeout: 10), "Keyboard introduction did not dismiss.")
    }

    private func uniqueCard(_ title: String) throws -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'task-card-' AND label BEGINSWITH %@", title + ", "))
        try require(matches.firstMatch.waitForExistence(timeout: 20) && matches.count == 1, "Expected one exact native task card.")
        return matches.firstMatch
    }

    private func label(_ value: String, in host: XCUIApplication) -> XCUIElement {
        host.descendants(matching: .any).matching(NSPredicate(format: "label == %@", value)).firstMatch
    }

    private func capture(_ host: XCUIApplication, _ name: String) throws {
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: artifacts.appendingPathComponent(name + ".png"))
        try host.debugDescription.write(to: artifacts.appendingPathComponent(name + ".hierarchy.txt"), atomically: true, encoding: .utf8)
        proof["lastCapture"] = name
        try persist()
    }

    private func persist() throws {
        let data = try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifacts.appendingPathComponent("observation.json"), options: .atomic)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NativeSurfaceFailure(message: message) }
    }
}
