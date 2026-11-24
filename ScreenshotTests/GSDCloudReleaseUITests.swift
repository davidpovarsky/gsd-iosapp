import Foundation
import UIKit
import XCTest

/// Release acceptance on disposable simulators. Uses the real UI, TaskStore,
/// Keychain session and cloud endpoint; no app-only test authentication backdoor.
/// Scope: selected simulator screens, tab/sidebar RTL geometry, one chart range change,
/// and the Matrix element-description audit. This is not a VoiceOver focus/speech audit
/// or complete gesture, text-clipping, orientation, or manual-layout-direction coverage.
/// The widget test is an in-app view harness, not a WidgetKit timeline/deep-link test.
/// Share, Watch, Watch widgets, real Siri, system notifications, and physical devices
/// require separate runtime evidence. Cloud signup/sign-out/sign-in use the Hebrew
/// iPad simulator UI; personal ChatGPT authorization and plan inference are not exercised.
@MainActor
final class GSDCloudReleaseUITests: XCTestCase {
    private var language: String { ProcessInfo.processInfo.environment["GSD_TEST_LANGUAGE"] ?? "en" }
    private var hebrew: Bool { language == "he" }
    private func label(_ english: String, _ he: String) -> String { hebrew ? he : english }

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

    private func navigation(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let bar = app.tabBars.firstMatch
        if bar.exists { return bar.buttons[title].firstMatch }
        let button = app.buttons[title].firstMatch
        if button.exists { return button }
        return app.staticTexts[title].firstMatch
    }

    private func navigate(_ app: XCUIApplication, _ title: String) {
        let item = navigation(app, title)
        XCTAssertTrue(item.waitForExistence(timeout: 15), "Missing navigation item: \(title)")
        item.tap()
    }

    private func capture(_ app: XCUIApplication, _ name: String) throws {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(language)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let destination = ProcessInfo.processInfo.environment["GSD_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: destination, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    func test01LocalizedNavigationEditorChartsAndRTL() throws {
        let app = application(demo: true)
        app.launch()
        let matrix = label("Matrix", "מטריצה")
        let settings = label("Settings", "הגדרות")
        navigate(app, matrix)
        let card = app.descendants(matching: .any).matching(identifier: "task-card-demo-deck").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Seeded Matrix content missing")
        XCTAssertTrue(app.textFields["capture-field"].exists)
        let matrixItem = navigation(app, matrix)
        let settingsItem = navigation(app, settings)
        XCTAssertTrue(settingsItem.exists)
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
        XCTAssertTrue(app.buttons[label("Complete", "סימון כהושלמה")].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[label("Delete", "מחיקה")].exists)
        try capture(app, "03-context-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.05)).tap()
        navigate(app, label("Dashboard", "לוח בקרה"))
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
        if app.tabBars.firstMatch.exists {
            // Scrolling collapses the compact tab bar; scrolling back reveals its destinations.
            dashboardScroll.swipeDown()
            navigate(app, label("Browse", "עיון"))
            let savedLink = app.descendants(matching: .any).matching(identifier: "browse-saved").firstMatch
            XCTAssertTrue(savedLink.waitForExistence(timeout: 8), "Browse list did not open")
            XCTAssertTrue(savedLink.isHittable, "Browse content is obscured")
        } else {
            // Regular iPad has no Browse tab. Its sidebar browses the Library directly.
            navigate(app, label("Saved", "שמורים"))
            let savedLibrary = app.descendants(matching: .any).matching(identifier: "saved-library").firstMatch
            XCTAssertTrue(savedLibrary.waitForExistence(timeout: 8), "Sidebar did not open the Saved library")
        }
        try capture(app, "05-browse")
        navigate(app, settings)
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


    /// Covers account/provider copy without starting personal OAuth or consuming AI usage.
    func test04LocalizedHanlinProvidersAndChatGPTAccount() throws {
        let app = application(demo: true)
        app.launch()
        navigate(app, label("Matrix", "מטריצה"))
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

    func test02CloudChangesArriveAfterClosedAppAndLocalChangesUpload() async throws {
        guard ProcessInfo.processInfo.environment["GSD_CLOUD_SYSTEM_TEST"] == "1" else {
            throw XCTSkip("Live cloud acceptance requires explicit CI opt-in")
        }
        let base = ProcessInfo.processInfo.environment["GSD_CLOUD_TEST_BASE"] ??
            "https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud"
        let fixture = CloudFixture(base: URL(string: base)!)
        // Register cleanup before any native signup work; the fixture never creates an account by API.
        addTeardownBlock { try await fixture.removeAccount() }
        let app = application(demo: false)
        app.launch()
        let skip = app.buttons[label("Skip", "דילוג")]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        navigate(app, label("Settings", "הגדרות"))
        let open = app.buttons["gsd.cloud.open"]
        for _ in 0..<4 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let mode = app.segmentedControls["gsd.cloud.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "Native account mode picker is missing")
        mode.buttons[label("Create account", "יצירת חשבון")].tap()
        let email = app.textFields["gsd.cloud.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText(fixture.email)
        let password = app.secureTextFields["gsd.cloud.password"]
        password.tap()
        password.typeText(fixture.password)
        let confirmation = app.secureTextFields["gsd.cloud.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), "Native signup confirmation is missing")
        confirmation.tap()
        confirmation.typeText(fixture.password)
        let submit = app.buttons["gsd.cloud.submit"]
        XCTAssertEqual(submit.label, label("Create GSD account", "יצירת חשבון GSD"))
        XCTAssertTrue(submit.isEnabled, "Valid native signup must enable submission")
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isHittable, "Native signup action is obscured")
        submit.tap()
        XCTAssertTrue(email.waitForNonExistence(timeout: 30), "Native cloud signup did not finish")
        let signedIn = app.descendants(matching: .any).matching(identifier: "gsd.cloud.signed-in").firstMatch
        XCTAssertTrue(signedIn.waitForExistence(timeout: 10), "Native signup did not establish a session")
        try capture(app, "08-account-created")
        // Authenticate only the account just created by the app, for server assertions and cleanup.
        try await fixture.authenticateExistingAccount()
        let signOut = app.buttons["gsd.cloud.sign-out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "Native sign-out action is missing")
        for _ in 0..<3 where !signOut.isHittable { app.swipeUp() }
        XCTAssertTrue(signOut.isHittable, "Native sign-out action is obscured")
        signOut.tap()
        XCTAssertTrue(signedIn.waitForNonExistence(timeout: 10), "Native sign-out did not clear the account UI")
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Native sign-in action did not return after sign-out")
        try capture(app, "08-account-signed-out")
        open.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons[label("Sign in", "התחברות")].tap()
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertFalse(confirmation.exists, "Ordinary sign-in must not require signup confirmation")
        email.tap()
        email.typeText(fixture.email)
        password.tap()
        password.typeText(fixture.password)
        XCTAssertEqual(submit.label, label("Sign in to GSD Cloud", "התחברות ל־GSD Cloud"))
        XCTAssertTrue(submit.isEnabled, "Valid native sign-in must enable submission")
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isHittable, "Native sign-in action is obscured")
        submit.tap()
        XCTAssertTrue(email.waitForNonExistence(timeout: 30), "Cloud sign-in did not finish")
        XCTAssertTrue(signedIn.waitForExistence(timeout: 10), "Native sign-in did not restore the same account session")
        try capture(app, "08-account-connected")
        app.terminate()
        XCTAssertEqual(app.state, .notRunning, "Server mutation must occur while native app is closed")
        let serverTitle = "Cloud closed app " + UUID().uuidString.prefix(8)
        let serverID = try await fixture.createTask(title: serverTitle)
        app.launch()
        navigate(app, label("Matrix", "מטריצה"))
        let serverCard = app.descendants(matching: .any).matching(identifier: "task-card-" + serverID).firstMatch
        XCTAssertTrue(serverCard.waitForExistence(timeout: 45), "Cloud task missing after closed-app mutation/relaunch")
        XCTAssertTrue(serverCard.label.contains(serverTitle))
        try capture(app, "09-closed-app-cloud-task")
        let localTitle = "Native upload " + UUID().uuidString.prefix(8)
        let field = app.textFields["capture-field"]
        XCTAssertTrue(field.exists)
        field.tap()
        field.typeText(localTitle + " !!\n")
        let uploaded = try await fixture.waitForTask(title: localTitle)
        XCTAssertTrue(uploaded, "Native TaskStore mutation did not reach Oracle")
        app.terminate()
        app.launch()
        navigate(app, label("Matrix", "מטריצה"))
        let localCard = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'task-card-' AND label CONTAINS %@", localTitle)).firstMatch
        XCTAssertTrue(localCard.waitForExistence(timeout: 30), "Local/cloud task did not persist across relaunch")
        try capture(app, "10-cloud-round-trip")
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
    private let session = URLSession(configuration: .ephemeral)

    init(base: URL) {
        self.base = base
        // Mask before any XCTest typing activity; all credentials belong to this disposable account.
        print("::add-mask::" + password)
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "GSDCloudAcceptance", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
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

    func removeAccount() async throws {
        defer { session.invalidateAndCancel() }
        // A native assertion may fail after registration but before fixture authentication.
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
            "owner": try XCTUnwrap(owner), "task_id": id, "title": title,
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
