import UIKit
import SwiftUI
import UniformTypeIdentifiers
import GSDModel
import GSDSnapshot
import GSDWire

/// The share-extension entry point (NSExtensionPrincipalClass). Extracts the shared URL or text
/// from the NSItemProvider, then hosts the SwiftUI compose sheet. GRDB-free. On Add it pushes
/// the task straight to PocketBase when it can (signed in, online, a few seconds' budget) and
/// then writes the SharedCapture to the App-Group outbox either way; the app lands it on its next
/// drain — without a second push when the record id is already there (spec §10.3).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let outbox = ShareOutboxStore()
    /// One identity and at most one direct POST for this compose sheet, including retries.
    private let captureTaskID = IDGenerator.generate(size: IDGenerator.Size.task)
    private var didAttemptPush = false
    /// The extension's whole lifetime after Add is a few seconds, so the push gets a hard budget:
    /// a slow or absent network falls through to the outbox rather than a hung sheet.
    private let push = DirectTaskPush(
        client: PocketBaseClient(baseURL: PocketBaseEndpoint.liveBaseURL, session: ShareViewController.shortBudgetSession()),
        token: { SharedTokenKeychain.load() },
        deviceID: { UserDefaults(suiteName: AppGroup.id)?.string(forKey: AppGroup.deviceIDKey) },
        defaultReminder: {
            UserDefaults(suiteName: AppGroup.id)?.object(forKey: AppGroup.defaultReminderKey) as? Int
                ?? AppGroup.fallbackDefaultReminder
        })

    private static func shortBudgetSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false       // offline → fail now, take the outbox path
        return URLSession(configuration: config)
    }

    /// Keep one task identity if the outbox write fails after a remote push. A retry uses the
    /// durable outbox only: the earlier POST may already have landed, and the app's queued
    /// create updates that identity with any edits made after the failure.
    private func saveAndPush(_ capture: SharedCapture) async throws {
        var capture = capture
        capture.taskID = captureTaskID
        capture.remoteRecordID = nil
        if !didAttemptPush, let task = capture.pushedTask() {
            didAttemptPush = true
            if case .pushed(let recordID) = await push.attempt(task) {
                capture.remoteRecordID = recordID
            }
        }
        try outbox.write(capture)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        _Concurrency.Task { [weak self] in
            guard let self else { return }
            let (title, urls) = await self.extractSharedItem()
            self.presentCompose(prefilledTitle: title, urls: urls)
        }
    }

    private func extractSharedItem() async -> (String, [String]) {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        return await ShareInputExtractor.extract(from: items)
    }

    private func presentCompose(prefilledTitle: String, urls: [String]) {
        let composeView = ShareComposeView(
            initialTitle: prefilledTitle,
            urls: urls,
            save: { [weak self] capture in try await self?.saveAndPush(capture) },
            onComplete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "com.itorah.gsd.share", code: 0))
            }
        )
        let host = UIHostingController(rootView: composeView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}

// MARK: - Shared input decoding

/// A conforming text provider may support data delivery without a successful typed-object load.
@MainActor
enum ShareInputExtractor {
    static func extract(from inputItems: [NSExtensionItem]) async -> (String, [String]) {
        var metadataFallback: String?
        for item in inputItems {
            let pageTitle = nonempty(item.attributedContentText?.string)
            if metadataFallback == nil { metadataFallback = pageTitle }
            let providers = item.attachments ?? []

            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadObject(URL.self, from: provider),
                   !url.absoluteString.isEmpty {
                    let title = pageTitle ?? URLTitle.derive(from: url.absoluteString)
                    report("typed_url", bytes: title.utf8.count)
                    return (title, [url.absoluteString])
                }
            }
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadText(from: provider) { return (text, []) }
            }
        }
        report(metadataFallback == nil ? "empty" : "metadata", bytes: metadataFallback?.utf8.count ?? 0)
        return (metadataFallback ?? "", [])
    }

    private static func loadText(from provider: NSItemProvider) async -> String? {
        if let text = nonempty(await loadObject(String.self, from: provider)) {
            report("typed_text", bytes: text.utf8.count)
            return text
        }
        // Use only declared, supported encodings; never interpret arbitrary binary data as text.
        for identifier in provider.registeredTypeIdentifiers {
            guard supportedTextTypes.contains(identifier),
                  let data = await loadData(from: provider, identifier: identifier),
                  let text = nonempty(decodeText(data, identifier: identifier)) else { continue }
            report("text_data", bytes: text.utf8.count)
            return text
        }
        return nil
    }

    private static let supportedTextTypes: Set<String> = [
        UTType.plainText.identifier, UTType.utf8PlainText.identifier,
        UTType.utf16PlainText.identifier, UTType.utf16ExternalPlainText.identifier
    ]

    private static func decodeText(_ data: Data, identifier: String) -> String? {
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if identifier == UTType.utf16PlainText.identifier
            || identifier == UTType.utf16ExternalPlainText.identifier {
            if hasUTF16BOM { return String(data: data, encoding: .utf16) }
            // Native UTF-16 follows the host byte order; external UTF-16 defaults to big-endian.
            if identifier == UTType.utf16PlainText.identifier {
                #if _endian(little)
                return String(data: data, encoding: .utf16LittleEndian)
                #else
                return String(data: data, encoding: .utf16BigEndian)
                #endif
            }
            return String(data: data, encoding: .utf16BigEndian)
        }
        if identifier == UTType.plainText.identifier && hasUTF16BOM {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func loadObject<T>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T: _ObjectiveCBridgeable & Sendable, T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in
                continuation.resume(returning: value)
            }
        }
    }

    private static func loadData(from provider: NSItemProvider, identifier: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    nonisolated private static func report(_ path: String, bytes: Int) {
        #if DEBUG
        // Counts and the selected decoder path only; never shared text, links, or account data.
        print("GSD_SHARE_INPUT path=\(path) bytes=\(bytes)")
        #endif
    }
}
