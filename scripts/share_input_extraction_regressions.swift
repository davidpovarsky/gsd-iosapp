import Foundation
import UniformTypeIdentifiers

@MainActor
private func item(_ providers: [NSItemProvider]? = nil, metadata: String? = nil) -> NSExtensionItem {
    let result = NSExtensionItem()
    result.attachments = providers
    if let metadata { result.attributedContentText = NSAttributedString(string: metadata) }
    return result
}

@MainActor
private func failedTypedText(data: Data, identifier: String) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerObject(ofClass: NSString.self, visibility: .all) { completion in
        completion(nil, NSError(domain: "GSDShareSyntheticTypedFailure", code: 1))
        return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

@MainActor
private func typedText(_ provider: NSItemProvider) async -> String? {
    await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: String.self) { value, _ in
            continuation.resume(returning: value)
        }
    }
}

@main
struct ShareInputRegressionProbe {
    @MainActor static func main() async throws {
        let text = "GSD synthetic שיתוף\nDo First"
        let url = URL(string: "https://example.com/source-page")!
        let dataOnly = failedTypedText(data: Data(text.utf8), identifier: UTType.plainText.identifier)
        let utf16 = failedTypedText(data: text.data(using: .utf16)!, identifier: UTType.utf16ExternalPlainText.identifier)
        #if _endian(little)
        let nativeUTF16Data = text.data(using: .utf16LittleEndian)!
        #else
        let nativeUTF16Data = text.data(using: .utf16BigEndian)!
        #endif
        let nativeUTF16 = failedTypedText(data: nativeUTF16Data, identifier: UTType.utf16PlainText.identifier)
        let externalUTF16 = failedTypedText(data: text.data(using: .utf16BigEndian)!, identifier: UTType.utf16ExternalPlainText.identifier)
        let plainUTF16 = failedTypedText(data: text.data(using: .utf16)!, identifier: UTType.plainText.identifier)
        let invalid = failedTypedText(data: Data([0xFF, 0x00, 0x01]), identifier: UTType.plainText.identifier)
        let failedURL = NSItemProvider()
        failedURL.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(nil, NSError(domain: "GSDShareSyntheticURLFailure", code: 2))
            return nil
        }
        let dataOnlyTyped = await typedText(dataOnly)
        let utf16Typed = await typedText(utf16)
        let fixturePreconditions = dataOnlyTyped == nil && utf16Typed == nil
        guard fixturePreconditions else {
            print("GSD_SHARE_REGRESSION " + "{\"fixturePreconditions\":false,\"passed\":false}")
            exit(2)
        }
        let fixtures: [(String, [NSExtensionItem], String, [String])] = [
            ("typed_text", [item([NSItemProvider(object: text as NSString)])], text, []),
            ("typed_url_priority", [item([NSItemProvider(object: url as NSURL), NSItemProvider(object: text as NSString)], metadata: "Source page")], "Source page", [url.absoluteString]),
            ("failed_typed_text_valid_plain_data", [item([dataOnly])], text, []),
            ("failed_typed_text_valid_utf16_data", [item([utf16])], text, []),
            ("native_utf16_without_bom", [item([nativeUTF16])], text, []),
            ("external_utf16_without_bom", [item([externalUTF16])], text, []),
            ("plain_text_with_utf16_bom", [item([plainUTF16])], text, []),
            ("failed_url_then_valid_text", [item([failedURL, NSItemProvider(object: text as NSString)])], text, []),
            ("empty_first_item_then_text", [item(), item([NSItemProvider(object: text as NSString)])], text, []),
            ("metadata_without_attachments", [item(metadata: "Metadata title")], "Metadata title", []),
            ("metadata_before_real_payload", [item(metadata: "Earlier metadata"), item([NSItemProvider(object: text as NSString)])], text, []),
            ("invalid_data_preserves_metadata", [item([invalid], metadata: "Safe metadata")], "Safe metadata", []),
            ("invalid_data_is_not_garbled_text", [item([invalid])], "", []),
            ("empty_input", [], "", [])
        ]
        var rows: [[String: Any]] = []
        for (name, inputs, expectedTitle, expectedURLs) in fixtures {
            let actual = await ShareInputExtractor.extract(from: inputs)
            rows.append(["case": name, "passed": actual.0 == expectedTitle && actual.1 == expectedURLs])
        }
        let passed = rows.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String: Any] = ["fixturePreconditions": true, "cases": rows,
                                    "passed": passed, "total": rows.count]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print("GSD_SHARE_REGRESSION " + String(decoding: data, as: UTF8.self))
        if !passed { exit(1) }
    }
}
