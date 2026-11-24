# Share input regression evidence — 2026-11-24

## Observed defect

The real text-share acceptance on production `ee5e95f536c375cfdbfa13cb6c812dcef8987a5f` opened the native GSD extension, but its settled Title field remained empty. Both reviewers inspected the original screenshot (SHA-256 `153539119e57555f5b6430750c872152ef9226c89ded9ec7e158e4a63525b7dd`). The strict source-title prefill assertion failed; it was not replaced by a typing fallback.

The retained native ShareSheet log showed the synthetic source string and a `public.plain-text` attachment. The old extractor discarded typed-load failures, inspected only the first input item, and did not preserve metadata when attachments were absent. The exact failing live provider callback was not recorded, so the Foundation fixtures establish these decoder contract failures without claiming to reproduce every part of the iOS transport.

## Correction

Only `ShareExtension/ShareViewController.swift` changes production behavior. Successful typed URL and String delivery retains priority. A failed or empty URL does not prevent trying text or later items. Supported registered text data is decoded as UTF-8 or the declared UTF-16 format, respecting BOMs, native byte order, and external big-endian defaults. Nonempty attributed content text is a last fallback after actual payloads. Arbitrary binary bytes are not guessed into another text encoding.

The helper stays in the existing Share extension source file. No project, package, SDK, main-app, Watch, widget, account, or persistence source changes are required. DEBUG diagnostics record only decoder path and byte count.

Lorvex has no receiving Share extension or input-items decoder; its outbound macOS text provider is a different path. This receiver correction has no Lorvex counterpart.

## Focused native evidence

The runner compiles the exact production decoder and actual Foundation providers with Xcode 27.1 / 27A9275, Swift 6, complete strict concurrency, and warnings treated as errors. For the baseline, it mechanically exposes the old private methods with an explicit input-items parameter.

At 21:35:14 UTC, the old source passed 4 of 14 fixtures and failed the 10 targeted fallback cases. The corrected source passed all 14. The fixtures prove that a typed String load actually fails before the same provider successfully supplies plain-text data; they also cover UTF-16 with and without BOMs, URL precedence, later items, metadata fallback, invalid bytes, and empty input.

Reproduce on the authorized Apple build host:

```sh
python3 scripts/test_share_input_extraction.py --repo . \
  --developer-dir "$GSD_COMPILER_DEVELOPER_DIR" \
  --output "$GSD_SHARE_PROBE_OUTPUT"
```

Use a new output directory for each run. The receipt binds production source, fixture and URL-title helper hashes.

## Native release gate

The original real prefill/Add/Cancel/persistence UI assertions remain required on the corrected app. Foundation success alone does not close the live Share defect. A fresh simulator build, target audit, real Share run, and signed archive are pending in this source receipt. The earlier preconsent pass is preserved separately; it does not imply account authorization or inference.

## API references

- [NSItemProvider data representation loading](https://developer.apple.com/documentation/foundation/nsitemprovider/loaddatarepresentation%28fortypeidentifier%3Acompletionhandler%3A%29)
- [Native-order UTF-16 plain text](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/utf16plaintext)
- [External UTF-16 plain text](https://developer.apple.com/documentation/uniformtypeidentifiers/uttypeutf16externalplaintext)
