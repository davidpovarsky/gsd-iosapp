#!/usr/bin/env python3
"""Apply existing fixture masks to retained native diagnostic text before upload."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from gsd_native_acceptance import _redactions, redact

REPLACEMENT = "[REDACTED_EPHEMERAL_PASSWORD]"


def discover(value) -> None:
    if isinstance(value, str):
        redact(value)
    elif isinstance(value, list):
        for item in value:
            discover(item)
    elif isinstance(value, dict):
        for key, item in value.items():
            discover(key)
            discover(item)


def sanitize(output: Path) -> dict:
    if output.is_symlink():
        raise RuntimeError("Diagnostic output must not be a symlink")
    output.mkdir(parents=True, exist_ok=True)
    paths = sorted(path for path in output.rglob("*") if path.suffix in (".log", ".json"))
    contents = {}
    # Discover every explicit fixture mask before rewriting any file. A raw
    # XCTest diagnostic can contain the mask after a JSON summary references it.
    for path in paths:
        if path.is_symlink():
            raise RuntimeError("Diagnostic text must not be a symlink")
        if path.is_file():
            # Byte decoding preserves original CRLF and all unrelated content.
            text = path.read_bytes().decode("utf-8")
            contents[path] = text
            if path.suffix == ".json":
                try:
                    discover(json.loads(text))
                except json.JSONDecodeError:
                    # A failed xcresulttool may emit plain diagnostic text to
                    # its intended JSON path. Preserve and sanitize that too.
                    discover(text)
            else:
                discover(text)
    _redactions.discard(REPLACEMENT)
    masks = _redactions - {REPLACEMENT}
    changed = []
    for path, text in contents.items():
        sanitized = text
        for value in sorted(masks, key=len, reverse=True):
            sanitized = sanitized.replace(value, REPLACEMENT)
        if any(value in sanitized for value in masks):
            raise RuntimeError("A known fixture mask remains in diagnostic text")
        if sanitized != text:
            path.write_bytes(sanitized.encode("utf-8"))
            changed.append(path.relative_to(output).as_posix())
    report = {"passed": True, "scope": "Exact explicit fixture masks in retained .log/.json only",
              "text_files_scanned": len(contents), "files_changed": changed,
              "known_fixture_mask_count": len(masks), "binary_images_unchanged": True}
    (output / "diagnostic-redaction.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    report = sanitize(args.output)
    print("GSD_NATIVE_DIAGNOSTIC_REDACTION_PASS", report["text_files_scanned"],
          len(report["files_changed"]))


if __name__ == "__main__":
    main()
