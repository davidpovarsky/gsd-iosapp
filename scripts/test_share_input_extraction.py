#!/usr/bin/env python3
"""Compile the actual Share input decoder with Foundation fixtures on the Apple host."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

SOURCE = "ShareExtension/ShareViewController.swift"
MARKER = "// MARK: - Shared input decoding"

def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--source-ref", default="working-tree")
    parser.add_argument("--developer-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    source_bytes = ((repo / SOURCE).read_bytes() if args.source_ref == "working-tree" else
                    subprocess.check_output(["git", "show", args.source_ref + ":" + SOURCE], cwd=repo))
    source = source_bytes.decode()
    if MARKER in source:
        decoder = source.split(MARKER, 1)[1]
        mode = "actual-production-decoder"
    else:
        # The baseline's two private methods are moved unchanged into the same test namespace;
        # only the UIKit context access becomes an explicit array parameter.
        start = source.index("    /// Prefer a web-URL attachment")
        end = source.index("    private func presentCompose", start)
        decoder = source[start:end]
        decoder = decoder.replace("private func extractSharedItem() async",
                                  "static func extract(from inputItems: [NSExtensionItem]) async", 1)
        decoder = decoder.replace("extensionContext?.inputItems.first as? NSExtensionItem",
                                  "inputItems.first", 1)
        decoder = decoder.replace("private func loadObject<T>", "private static func loadObject<T>", 1)
        decoder = "@MainActor enum ShareInputExtractor {\n" + decoder + "\n}\n"
        mode = "actual-baseline-methods-with-context-argument"
    (output / "Decoder.swift").write_text("import Foundation\nimport UniformTypeIdentifiers\n" + decoder)
    fixture_path = repo / "scripts/share_input_extraction_regressions.swift"
    title_path = repo / "GSDKit/Sources/GSDModel/URLTitle.swift"
    (output / "Fixtures.swift").write_bytes(fixture_path.read_bytes())
    (output / "URLTitle.swift").write_bytes(title_path.read_bytes())
    environment = {**os.environ, "DEVELOPER_DIR": str(args.developer_dir)}
    command = ["xcrun", "swiftc", "-swift-version", "6", "-strict-concurrency=complete",
               "-warnings-as-errors", "-parse-as-library", str(output / "Decoder.swift"),
               str(output / "URLTitle.swift"), str(output / "Fixtures.swift"),
               "-o", str(output / "probe")]
    compile_result = subprocess.run(command, env=environment, text=True,
                                    capture_output=True, timeout=60)
    (output / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
    result = {"mode": mode, "sourceRef": args.source_ref, "sourceSHA256": digest(source_bytes),
              "fixtureSHA256": digest(fixture_path.read_bytes()),
              "urlTitleSHA256": digest(title_path.read_bytes()),
              "compileReturnCode": compile_result.returncode, "command": command,
              "compiler": subprocess.check_output(["xcodebuild", "-version"],
                                                  env=environment, text=True).strip(),
              "passed": False}
    if compile_result.returncode == 0:
        run_result = subprocess.run([str(output / "probe")], text=True,
                                    capture_output=True, timeout=30)
        (output / "run.log").write_text(run_result.stdout + run_result.stderr)
        reports = [line.removeprefix("GSD_SHARE_REGRESSION ") for line in run_result.stdout.splitlines()
                   if line.startswith("GSD_SHARE_REGRESSION ")]
        result["runReturnCode"] = run_result.returncode
        if len(reports) == 1:
            result["regressions"] = json.loads(reports[0])
            result["passed"] = run_result.returncode == 0 and result["regressions"].get("passed") is True
    else:
        print(compile_result.stderr[:10000], file=sys.stderr)
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["passed"] else 1

if __name__ == "__main__":
    raise SystemExit(main())
