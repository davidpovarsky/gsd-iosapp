import Foundation
import UIKit
import XCTest

/// Release acceptance on disposable simulators. Uses the real UI, TaskStore,
/// Keychain session and cloud endpoint; no app-only test authentication backdoor.
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
        if form.exists { form.swipeUp() }
        XCTAssertTrue(app.buttons["editor-save"].exists, "Editor save action disappeared after scroll")
        try capture(app, "02-editor")
        cancel.tap()
        card.press(forDuration: 1)
        XCTAssertTrue(app.buttons[label("Complete", "סימון כהושלמה")].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[label("Delete", "מחיקה")].exists)
        try capture(app, "03-context-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.05)).tap()
        navigate(app, label("Dashboard", "לוח בקרה"))
        try capture(app, "04-dashboard")
        navigate(app, label("Browse", "עיון"))
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
        try await fixture.createAccount()
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
        let email = app.textFields["gsd.cloud.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap()
        email.typeText(fixture.email)
        let password = app.secureTextFields["gsd.cloud.password"]
        password.tap()
        password.typeText(fixture.password)
        app.buttons["gsd.cloud.submit"].tap()
        XCTAssertTrue(email.waitForNonExistence(timeout: 30), "Cloud sign-in did not finish")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "gsd.cloud.signed-in").firstMatch.waitForExistence(timeout: 10))
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

    init(base: URL) { self.base = base }

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

    func createAccount() async throws {
        // Ephemeral fixture only. The GitHub command masks XCTest typing activities in CI.
        print("::add-mask::" + password)
        let userData = try await request("api/collections/users/records", method: "POST",
                                        body: ["email": email, "password": password, "passwordConfirm": password])
        owner = try JSONDecoder().decode(User.self, from: userData).id
        let authData = try await request("api/collections/users/auth-with-password", method: "POST",
                                        body: ["identity": email, "password": password])
        let auth = try JSONDecoder().decode(Session.self, from: authData)
        token = auth.token
        owner = auth.record.id
    }

    func removeAccount() async throws {
        guard token != nil else { return }
        _ = try await request("api/gsd/account", method: "DELETE")
        token = nil
        owner = nil
        session.invalidateAndCancel()
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
