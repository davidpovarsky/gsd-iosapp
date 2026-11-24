#!/usr/bin/env python3
"""Apply existing fixture masks to retained native diagnostic text before upload."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from gsd_native_acceptance import _redactions, redact

REPLACEMENT = "[REDACTED_EPHEMERAL_PASSWORD]"

# XCTest abbreviates values in typing actions. The full fixture mask cannot
# match such prefixes, so redact only the quoted payload of an explicitly
# identified SecureTextField Type action, preserving the action and target.
# A literal or JSON-escaped newline ends the action; never match a later field.
_SECURE_TYPE = re.compile(
    r"""(?P<prefix>\bType[ \t]+)(?P<quote>\\?['"])(?P<payload>(?:(?!\\[rn])[^\r\n])*?)(?P=quote)"""
    r"""(?=[ \t]+into(?:(?!\\[rn])[^\r\n])*\bSecureTextField\b)"""
)


def redact_secure_typing(text: str) -> tuple[str, int]:
    count = 0

    def replace(match: re.Match) -> str:
        nonlocal count
        count += match["payload"] != REPLACEMENT
        return match["prefix"] + match["quote"] + REPLACEMENT + match["quote"]

    return _SECURE_TYPE.sub(replace, text), count


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
    secure_typing_payloads = 0
    for path, text in contents.items():
        sanitized = text
        for value in sorted(masks, key=len, reverse=True):
            sanitized = sanitized.replace(value, REPLACEMENT)
        sanitized, action_count = redact_secure_typing(sanitized)
        secure_typing_payloads += action_count
        if any(match["payload"] != REPLACEMENT for match in _SECURE_TYPE.finditer(sanitized)):
            raise RuntimeError("A secure typing payload remains in diagnostic text")
        if any(value in sanitized for value in masks):
            raise RuntimeError("A known fixture mask remains in diagnostic text")
        if sanitized != text:
            path.write_bytes(sanitized.encode("utf-8"))
            changed.append(path.relative_to(output).as_posix())
    report = {"passed": True, "scope": "Exact explicit fixture masks and SecureTextField typing payloads in retained .log/.json",
              "text_files_scanned": len(contents), "files_changed": changed,
              "known_fixture_mask_count": len(masks), "secure_typing_payloads_redacted": secure_typing_payloads,
              "binary_images_unchanged": True}
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
