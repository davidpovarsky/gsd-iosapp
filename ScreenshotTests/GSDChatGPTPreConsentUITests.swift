import Foundation
import UIKit
import XCTest

/// Opens the real, unmodified sign-in entry point without entering credentials or granting access.
@MainActor
final class GSDChatGPTPreConsentUITests: XCTestCase {
    private var appSourceSHA = ""
    private let signedOut = "Continue with ChatGPT to use your plan for eligible AI requests."
    private let cancelled = "ChatGPT sign-in was cancelled."
    private var output: URL?
    private var receipt: [String: Any] = [:]
    private var systemPromptContinuedForCurrentAttempt = false

    private struct Incomplete: Error {
        let reason: String
    }

    private struct BrowserSurface {
        let cancel: XCUIElement
        let webView: XCUIElement
        let originEvidence: String
    }

    private func preparePreConsentTest() throws {
        #if targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["GSD_SIWC_PRECONSENT_ARTIFACTS"], directory.hasPrefix("/"),
              let simulator = environment["GSD_SIWC_PRECONSENT_SIMULATOR_UDID"],
              UUID(uuidString: simulator) != nil,
              environment["GSD_SIWC_PRECONSENT_FRESH_SIMULATOR"] == "1",
              let verifiedSource = environment["GSD_SIWC_PRECONSENT_APP_SOURCE"],
              verifiedSource.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              environment["GSD_TEST_LANGUAGE"] == "en" else {
            throw Incomplete(reason: "Fresh owned English simulator and exact product provenance are required.")
        }
        appSourceSHA = verifiedSource
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        output = destination
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        receipt = [
            "schemaVersion": 1, "appSourceSHA": appSourceSHA, "simulatorID": simulator,
            "scope": "native_preconsent_start_and_cancel_only", "language": "en",
            "probePassed": false, "authorizationSucceeded": false, "grantVerified": false,
            "entitlementVerified": false, "inferenceInvokedByProbe": false,
            "browserScreenshotsRequestedByProbe": false, "fullHierarchyRequestedByProbe": false,
            "signInPageVerified": false, "pageContentClassification": "not_observed",
            "continueActivated": false, "officialBrowserObserved": false,
            "ordinaryCancellationObserved": false, "disconnectedAfterCancel": false,
            "retryContinueActivated": false, "retryOpeningObserved": false, "officialBrowserObservedOnRetry": false,
            "ordinaryRetryCancellationObserved": false, "disconnectedAfterRetryCancel": false,
            "disconnectedAfterRelaunch": false, "outcome": "incomplete"
        ]
        try saveReceipt()
        #else
        throw Incomplete(reason: "This probe is restricted to an owned disposable simulator.")
        #endif
    }

    func test00ContinueOpensOfficialBrowserAndCancels() throws {
        try preparePreConsentTest()
        let app = XCUIApplication(bundleIdentifier: "com.itorah.gsd")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer { app.terminate() }
        do {
            try openAccount(app)
            try requireDisconnected(app, expectedStatus: signedOut)
            try saveAppScreenshot("01-disconnected-before-start")
            try saveChromeDiagnostics([app], name: "before-continue")
            app.buttons["chatgpt.continue"].tap()
            receipt["continueActivated"] = true
            try saveReceipt()

            let surface = try observeSignIn(app)
            let publicError = publicErrorMarker(in: surface.webView)
            if let publicError {
                receipt["publicErrorMarker"] = publicError
                receipt["pageContentClassification"] = "allowlisted_error_marker_observed"
            }
            surface.cancel.tap()
            try require(wait(15) { self.status(app).exists && self.status(app).label == self.cancelled },
                        "The observed browser Cancel did not return the native cancellation state.")
            receipt["ordinaryCancellationObserved"] = true
            try requireDisconnected(app, expectedStatus: cancelled)
            receipt["disconnectedAfterCancel"] = true
            try saveAppScreenshot("02-disconnected-after-cancel")

            // Retry from this same native account presentation before testing persistence.
            app.buttons["chatgpt.continue"].tap()
            receipt["retryContinueActivated"] = true
            try saveReceipt()
            try require(wait(15) {
                self.status(app).exists && self.status(app).label == "Opening secure ChatGPT sign-in…" &&
                    !app.buttons["chatgpt.continue"].isEnabled
            }, "Retry did not enter a new native opening/busy state.")
            receipt["retryOpeningObserved"] = true
            try saveReceipt()
            let retrySurface = try observeSignIn(app)
            receipt["officialBrowserObservedOnRetry"] = true
            let retryPublicError = publicErrorMarker(in: retrySurface.webView)
            if let retryPublicError {
                receipt["publicErrorMarker"] = retryPublicError
                receipt["pageContentClassification"] = "allowlisted_error_marker_observed"
            }
            retrySurface.cancel.tap()
            try require(wait(15) { self.status(app).exists && self.status(app).label == self.cancelled },
                        "The retried browser dismissal did not return the native cancellation state.")
            receipt["ordinaryRetryCancellationObserved"] = true
            try requireDisconnected(app, expectedStatus: cancelled)
            receipt["disconnectedAfterRetryCancel"] = true
            try saveAppScreenshot("03-disconnected-after-retry-cancel")

            app.terminate()
            try openAccount(app)
            try requireDisconnected(app, expectedStatus: signedOut)
            receipt["disconnectedAfterRelaunch"] = true
            try saveAppScreenshot("03-disconnected-after-relaunch")
            try require(publicError == nil && retryPublicError == nil,
                        "The official page exposed a public error; sign-in is not accepted.")
            receipt["probePassed"] = true
            receipt["outcome"] = "official_browser_opened_cancelled_and_disconnected"
            try saveReceipt()
        } catch {
            receipt["probePassed"] = false
            receipt["outcome"] = receipt["publicErrorMarker"] == nil ? "incomplete" : "official_public_error"
            receipt["failure"] = (error as? Incomplete)?.reason ?? "Probe could not complete."
            try saveReceipt()
            throw error
        }
    }

    private func openAccount(_ app: XCUIApplication) throws {
        app.launch()
        // Matrix remains in the accessibility tree underneath normal onboarding.
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) {
            try tap(skip, "Normal onboarding Skip is unavailable.")
            try require(skip.waitForNonExistence(timeout: 10), "Normal onboarding did not dismiss.")
        }
        let field = app.textFields["capture-field"]
        try require(field.waitForExistence(timeout: 30), "Normal GSD did not reach Matrix.")
        try require(field.wait(for: \.isHittable, toEqual: true, timeout: 10), "Normal Matrix is obscured.")
        try openAssistantWhenReady(app)
        let modelSettings = app.navigationBars["Hanlin model settings"]
        if !modelSettings.waitForExistence(timeout: 5) {
            try tap(app.buttons["Model"].firstMatch, "Hanlin model settings are unavailable.")
        }
        try require(modelSettings.waitForExistence(timeout: 5), "Hanlin model settings did not open.")
        let provider = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Provider")).firstMatch
        if provider.exists { try tap(provider, "Provider picker is unavailable.") }
        else { try tap(app.buttons["OpenRouter"].firstMatch, "Provider picker is unavailable.") }
        try tap(app.buttons["ChatGPT plan"].firstMatch, "ChatGPT plan provider is unavailable.")
        try tap(app.buttons["hanlin.chatgpt.settings"], "The native ChatGPT account entry is unavailable.")
        try require(app.navigationBars["ChatGPT account"].waitForExistence(timeout: 10),
                    "The native ChatGPT account screen did not open.")
    }

    private func dismissKeyboardIntroductionIfPresent() throws {
        // The normal first-keyboard introduction is owned by SpringBoard, not sign-in.
        // Its exact native container was observed on a fresh simulator.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let containers = springboard.otherElements
            .matching(identifier: "UIContinuousPathIntroductionView")
            .allElementsBoundByAccessibilityElement.filter { $0.exists }
        guard !containers.isEmpty else { return }
        try require(containers.count == 1, "Keyboard introduction ownership is ambiguous.")
        let introduction = containers[0]
        let buttons = introduction.buttons.allElementsBoundByAccessibilityElement.filter {
            $0.exists && $0.isEnabled && $0.isHittable
                && ($0.label == "Continue" || $0.label == "המשך")
        }
        try require(buttons.count == 1, "The native keyboard introduction has no unique ready Continue control.")
        try tap(buttons[0], "The native keyboard introduction could not be dismissed.")
        try require(introduction.waitForNonExistence(timeout: 10), "The native keyboard introduction remained visible.")
    }

    private func openAssistantWhenReady(_ app: XCUIApplication) throws {
        try dismissKeyboardIntroductionIfPresent()
        let query = app.buttons.matching(identifier: "hanlin.assistant.open")
        var readyAssistant: XCUIElement?
        let ready = wait(15) {
            let readyCandidates = query.allElementsBoundByAccessibilityElement.filter {
                $0.exists && $0.isEnabled && $0.isHittable
            }
            guard readyCandidates.count == 1, let candidate = readyCandidates.first else { return false }
            readyAssistant = candidate
            return true
        }
        guard ready, let readyAssistant else {
            try saveAssistantStartupDiagnostics(app, candidates: query.allElementsBoundByAccessibilityElement)
            throw Incomplete(reason: "The unique Hanlin assistant control did not become enabled and hittable.")
        }
        try tap(readyAssistant, "Hanlin assistant became unavailable before activation.")
    }

    private func saveAssistantStartupDiagnostics(_ app: XCUIApplication, candidates: [XCUIElement]) throws {
        guard let output else { throw Incomplete(reason: "Private artifact output is unavailable.") }
        // This path runs before Continue. Record only known native control state, never a full tree.
        let nativeOnly = app.state == .runningForeground && app.webViews.count == 0
        if nativeOnly { try saveAppScreenshot("00-native-assistant-unavailable") }
        let controls: [[String: Any]] = candidates.prefix(8).map { element in
            guard element.exists else { return ["exists": false] }
            let frame = element.frame
            return [
                "exists": true, "type": Int(element.elementType.rawValue),
                "isEnabled": element.isEnabled, "isHittable": element.isHittable,
                "frame": [frame.minX, frame.minY, frame.width, frame.height]
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "appSourceSHA": appSourceSHA,
            "stage": "native_matrix_before_current_attempt",
            "queryIdentifier": "hanlin.assistant.open", "candidateCount": candidates.count,
            "controls": controls, "nativeScreenshotRecorded": nativeOnly,
            "browserScreenshotRequested": false, "fullHierarchyRequested": false
        ], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("assistant-startup-diagnostics.json"), options: .atomic)
    }

    private func requireDisconnected(_ app: XCUIApplication, expectedStatus: String) throws {
        try require(wait(10) { self.status(app).exists && self.status(app).label == expectedStatus },
                    "The expected disconnected account status is absent.")
        let button = app.buttons["chatgpt.continue"]
        try require(button.exists && button.isEnabled && button.isHittable,
                    "Ordinary Continue is not available in the disconnected state.")
        try require(!app.alerts["You're using your ChatGPT plan"].exists &&
                    !app.buttons["Enable ChatGPT plan use"].exists &&
                    !app.staticTexts["Saved ChatGPT accounts"].exists &&
                    !app.staticTexts["Available ChatGPT models"].exists,
                    "Unexpected saved account or plan state is visible.")
        let usage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Manage ChatGPT usage")).firstMatch
        for _ in 0..<3 where !usage.isHittable { app.swipeUp() }
        try require(usage.exists && usage.isHittable, "The account footer could not be inspected.")
        try require(!app.buttons["Sign out of ChatGPT"].exists,
                    "An active ChatGPT registration appeared without this probe granting access.")
        for _ in 0..<3 where !button.isHittable { app.swipeDown() }
        try require(button.isHittable, "Ordinary Continue did not remain reachable.")
    }

    private func observeSignIn(_ app: XCUIApplication) throws -> BrowserSurface {
        systemPromptContinuedForCurrentAttempt = false
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let owners = [app, springboard]
        let deadline = Date().addingTimeInterval(60)
        repeat {
            for (index, owner) in owners.enumerated() {
                if let surface = observedBrowser(in: owner, named: index == 0 ? "gsd_app" : "springboard") {
                    receipt["officialBrowserObserved"] = true
                    receipt["observedOfficialHost"] = "auth.openai.com"
                    receipt["expectedAuthorizationOrigin"] = "https://auth.openai.com"
                    receipt["originEvidence"] = surface.originEvidence
                    if surface.originEvidence == "visible_https_url" {
                        receipt["observedOrigin"] = "https://auth.openai.com"
                    } else {
                        receipt.removeValue(forKey: "observedOrigin")
                    }
                    receipt["publicState"] = "official_browser_visible"
                    receipt["pageContentClassification"] = "unclassified"
                    try saveReceipt()
                    return surface
                }
            }
            try permitObservedSystemPrompt(owners)
            if status(app).exists {
                let value = status(app).label
                if value.hasPrefix("ChatGPT sign-in failed:") || value == cancelled {
                    receipt["publicState"] = nativeFailureState(value)
                    throw Incomplete(reason: "Native authorization ended before an official browser was observed.")
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        try saveChromeDiagnostics(owners, name: "unresolved-browser")
        throw Incomplete(reason: "Official browser chrome and an unambiguous Cancel were not observed.")
    }

    private func permitObservedSystemPrompt(_ owners: [XCUIApplication]) throws {
        guard !systemPromptContinuedForCurrentAttempt,
              !owners.contains(where: { $0.state != .notRunning && $0.webViews.count > 0 }) else { return }
        for owner in owners where owner.state != .notRunning {
            guard owner.alerts.count == 1 else { continue }
            let alert = owner.alerts.element(boundBy: 0)
            let text = alert.staticTexts.allElementsBoundByIndex.prefix(8).map(\.label).joined(separator: " ")
            let domain = text.range(of: #"(?i)(?:^|[\s"'“”])(?:auth\.)?openai\.com(?:[\s"'“”]|$)"#,
                                    options: .regularExpression) != nil
            guard domain && text.localizedCaseInsensitiveContains("wants to use") &&
                  text.localizedCaseInsensitiveContains("to sign in") else { continue }
            let proceed = alert.buttons.matching(NSPredicate(format: "label == %@", "Continue"))
            let cancel = alert.buttons.matching(NSPredicate(format: "label == %@", "Cancel"))
            try require(alert.buttons.count == 2 && proceed.count == 1 && cancel.count == 1,
                        "The observed OpenAI system prompt has unknown actions.")
            try require(proceed.element(boundBy: 0).isHittable && cancel.element(boundBy: 0).isHittable,
                        "The observed OpenAI system prompt is not usable.")
            receipt["systemPromptObserved"] = true
            receipt["systemPromptDomain"] = "openai.com"
            receipt["systemPromptContinued"] = true
            systemPromptContinuedForCurrentAttempt = true
            try saveReceipt()
            // Only this native two-button alert is continued. No web-page action is invoked.
            proceed.element(boundBy: 0).tap()
            return
        }
    }

    private func observedBrowser(in owner: XCUIApplication, named name: String) -> BrowserSurface? {
        var summary: [String: Any] = [
            "ownerState": Int(owner.state.rawValue), "webViewCount": 0, "nativeBrowserBarCount": 0,
            "nativeBrowserBarsInspected": 0, "exactCancelObserved": false,
            "uniqueHittableCancelObserved": false, "officialHostChromeObserved": false
        ]
        defer {
            var owners = receipt["browserObservationSummary"] as? [String: [String: Any]] ?? [:]
            owners[name] = summary
            receipt["browserObservationSummary"] = owners
        }
        guard owner.state != .notRunning else { return nil }
        let webViews = owner.webViews
        let webCount = webViews.count
        summary["webViewCount"] = webCount
        // Actual native AX evidence: TopBrowserBar has direct Close/URL button children.
        // The app's underlying settings Cancel is in a different NavigationBar.
        let bars = owner.otherElements.matching(identifier: "TopBrowserBar")
            .allElementsBoundByAccessibilityElement
        summary["nativeBrowserBarCount"] = bars.count
        guard bars.count == 1, let bar = bars.first, bar.exists else { return nil }
        summary["nativeBrowserBarsInspected"] = 1
        let cancels = bar.children(matching: .button).matching(identifier: "Close")
            .allElementsBoundByAccessibilityElement
        let addresses = bar.children(matching: .button).matching(identifier: "URL")
            .allElementsBoundByAccessibilityElement
        guard cancels.count == 1, addresses.count == 1,
              let cancel = cancels.first, let address = addresses.first,
              cancel.exists, address.exists, cancel.label == "Cancel", address.label == "Address" else { return nil }
        summary["exactCancelObserved"] = true
        let evidence = officialHostInChrome(address)
        summary["officialHostChromeObserved"] = evidence != nil
        guard cancel.isHittable, address.isHittable,
              bar.frame.contains(cancel.frame), bar.frame.contains(address.frame) else { return nil }
        summary["uniqueHittableCancelObserved"] = true
        guard let evidence, webCount > 0 else { return nil }
        let webView = webViews.firstMatch
        guard webView.exists, !webView.frame.isEmpty else { return nil }
        return .init(cancel: cancel, webView: webView, originEvidence: evidence)
    }

    private func normalizedNativeChromeText(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The observed native Address value starts with one left-to-right formatting mark.
        return value.hasPrefix("\u{200E}")
            ? String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) : value
    }

    private func officialHostInChrome(_ bar: XCUIElement) -> String? {
        // Only browser navigation chrome is inspected; fields inside the web page are never read.
        let nodes = [bar] + Array(bar.staticTexts.allElementsBoundByIndex.prefix(10)) +
            Array(bar.buttons.allElementsBoundByIndex.prefix(10)) +
            Array(bar.textFields.allElementsBoundByIndex.prefix(2))
        var visibleHostOnly = false
        for node in nodes {
            for raw in [node.label, node.value as? String ?? ""] {
                let value = normalizedNativeChromeText(raw)
                if value.lowercased() == "auth.openai.com" { visibleHostOnly = true }
                if let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
                   url.host?.lowercased() == "auth.openai.com", url.user == nil, url.password == nil,
                   url.port == nil || url.port == 443 {
                    return "visible_https_url"
                }
            }
        }
        return visibleHostOnly ? "visible_host_only" : nil
    }

    private func saveChromeDiagnostics(_ owners: [XCUIApplication], name: String) throws {
        var records: [[String: Any]] = []
        try writeChromeDiagnostics(records, name: name)
        for (ownerIndex, owner) in owners.enumerated() where owner.state != .notRunning {
            let recordIndex = records.count
            records.append([
                "ownerIndex": ownerIndex, "ownerState": Int(owner.state.rawValue),
                "webViewCount": owner.webViews.count,
                "nativeContainers": [[String: Any]](),
                "unscopedDismissCandidates": [[String: Any]]()
            ])
            try writeChromeDiagnostics(records, name: name)
            let actions = owner.buttons.matching(NSPredicate(
                format: "label IN %@ OR identifier IN %@",
                ["Close", "Cancel", "Done"] as NSArray,
                ["Close", "Cancel", "Done", "chatgpt.continue"] as NSArray))
            var candidates: [[String: Any]] = []
            // Bind to actual AX elements: index-bound floating toolbars can change mid-query.
            for action in actions.allElementsBoundByAccessibilityElement.prefix(12) where action.exists {
                candidates.append(unscopedDismissCandidate(action))
                records[recordIndex]["unscopedDismissCandidates"] = candidates
                try writeChromeDiagnostics(records, name: name)
            }
            var containers: [[String: Any]] = []
            for (kind, query) in [
                ("nativeBrowserBar", owner.otherElements.matching(identifier: "TopBrowserBar")),
                ("navigationBar", owner.navigationBars), ("toolbar", owner.toolbars)
            ] {
                let elements = Array(query.allElementsBoundByAccessibilityElement.prefix(8))
                for (index, container) in elements.enumerated() where container.exists {
                    var record = chromeControl(container)
                    record["kind"] = kind
                    record["index"] = index
                    record["controls"] = [[String: Any]]()
                    containers.append(record)
                    records[recordIndex]["nativeContainers"] = containers
                    try writeChromeDiagnostics(records, name: name)
                    // Before Continue, container identity/geometry is sufficient for the baseline.
                    guard name != "before-continue" else { continue }
                    let controls = Array(container.buttons.allElementsBoundByAccessibilityElement.prefix(16)) +
                        Array(container.staticTexts.allElementsBoundByAccessibilityElement.prefix(12)) +
                        Array(container.textFields.allElementsBoundByAccessibilityElement.prefix(3)) +
                        Array(container.otherElements.allElementsBoundByAccessibilityElement.prefix(8))
                    var controlRecords: [[String: Any]] = []
                    for control in controls where control.exists {
                        controlRecords.append(chromeControl(control))
                        record["controls"] = controlRecords
                        containers[containers.count - 1] = record
                        records[recordIndex]["nativeContainers"] = containers
                        try writeChromeDiagnostics(records, name: name)
                    }
                }
            }
        }
    }

    private func writeChromeDiagnostics(_ records: [[String: Any]], name: String) throws {
        guard let output else { throw Incomplete(reason: "Private artifact output is unavailable.") }
        // Persist each completed record before another dynamic native query can fail.
        // Global candidates are unscoped; only allowlisted labels and geometry survive.
        // No browser screenshot or full debug hierarchy is requested.
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "appSourceSHA": appSourceSHA, "owners": records,
            "arbitraryPageValuesRecorded": false, "browserScreenshotRequested": false
        ], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent(name + "-chrome.json"), options: .atomic)
    }

    private func chromeControl(_ element: XCUIElement) -> [String: Any] {
        let frame = element.frame
        return [
            "type": Int(element.elementType.rawValue),
            "identifier": safeChromeString(element.identifier),
            "label": safeChromeString(element.label),
            "value": safeChromeString(element.value as? String ?? ""),
            "isHittable": element.isHittable,
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        ]
    }

    private func unscopedDismissCandidate(_ element: XCUIElement) -> [String: Any] {
        let frame = element.frame
        let label = element.label
        let allowed = ["Close", "Cancel", "Done", "Continue with ChatGPT"]
        return [
            "scope": "unscoped_candidate",
            "type": Int(element.elementType.rawValue),
            "label": allowed.contains(label) ? label : "[redacted]",
            "isHittable": element.isHittable,
            "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        ]
    }

    private func safeChromeString(_ raw: String) -> String {
        let value = normalizedNativeChromeText(raw)
        let officialHosts = ["auth.openai.com", "openai.com", "chatgpt.com"]
        if let url = URLComponents(string: value),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host?.lowercased(), officialHosts.contains(host),
           url.user == nil, url.password == nil {
            return (url.scheme?.lowercased() ?? "https") + "://" + host
        }
        let knownLabels = [
            "", "Close", "Cancel", "Done", "Continue", "Continue with ChatGPT",
            "GSD", "Matrix", "Task AI assistant", "Hanlin model settings", "ChatGPT account",
            "Back", "Forward", "Reload", "Stop", "Address", "URL", "Website",
            "Website Information", "Secure", "Search", "Show Completed", "Edit",
            "MCP", "Model", "Toolbar", "TopBrowserBar", "auth.openai.com", "openai.com", "chatgpt.com"
        ]
        return knownLabels.contains(value) ? value : "[redacted]"
    }

    private func publicErrorMarker(in webView: XCUIElement) -> String? {
        // Persist only a constant matched marker, never the surrounding page text or request data.
        let markers = [
            "invalid_request", "invalid_client", "unauthorized_client", "invalid_scope",
            "unsupported_response_type", "access_denied", "server_error", "temporarily_unavailable",
            "Something went wrong", "Unable to sign in", "An error occurred"
        ]
        for marker in markers {
            let matches = webView.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", marker))
            if matches.count > 0 { return marker }
        }
        return nil
    }

    private func nativeFailureState(_ value: String) -> String {
        if value == cancelled { return "cancelled_before_browser_observation" }
        if value == "ChatGPT sign-in failed: The secure ChatGPT sign-in window could not open." {
            return "secure_window_unavailable"
        }
        if value == "ChatGPT sign-in failed: ChatGPT sign-in timed out. Please try again." {
            return "native_authorization_timed_out"
        }
        return "native_sign_in_failed_unclassified"
    }

    private func status(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chatgpt.account.status").firstMatch
    }

    private func tap(_ element: XCUIElement, _ reason: String) throws {
        try require(element.waitForExistence(timeout: 10), reason)
        try require(wait(10) { element.exists && element.isEnabled && element.isHittable }, reason)
        element.tap()
    }

    private func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Incomplete(reason: reason) }
    }

    private func saveAppScreenshot(_ name: String) throws {
        guard let output else { throw Incomplete(reason: "Private artifact output is unavailable.") }
        // Called only before activation or after exact native disconnected-state checks.
        // Browser screenshots, attachments and debugDescription are deliberately never requested.
        try XCUIScreen.main.screenshot().pngRepresentation.write(
            to: output.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func saveReceipt() throws {
        guard let output else { throw Incomplete(reason: "Private artifact output is unavailable.") }
        receipt["observedAt"] = ISO8601DateFormatter().string(from: Date())
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("siwc-preconsent-observation.json"), options: .atomic)
    }
}
