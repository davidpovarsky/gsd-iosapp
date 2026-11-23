"""Audit Apple UI literals and en/he catalogs. Run from any directory with Python 3."""
import json
import re
import sys
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("App", "Widgets", "ShareExtension", "Watch", "WatchWidgets")
# Direct presentation API calls. Computed Strings, backend replies and reflection need review.
UI = re.compile(
    r'\b(?:Text|Button|Label|Menu|Section|Picker|Toggle|TextField|SecureField|'
    r'ContentUnavailableView|DatePicker|ProgressView|navigationTitle|'
    r'accessibilityLabel|accessibilityHint|accessibilityValue|alert|confirmationDialog|'
    r'help|displayName|configurationDisplayName|IntentDescription|'
    r'TypeDisplayRepresentation|LocalizedStringResource)\(\s*(?:name:\s*)?$'
    r'|\bString\(localized:\s*$|localizedUserNotificationString\(forKey:\s*$|@Parameter\(title:\s*$|LocalizedStringResource\s*=\s*$'
)
# These display a URL or keyboard glyph verbatim in either language.
INVARIANT = {"gsdtaskmanager.com", "!!", "•", "·"}
FORMAT = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|@|f|lf)|\$\{applicationName\}')


# Plain String assignments and nil-coalescing fallbacks do not get SwiftUI literal lookup.
PLAIN_COPY = re.compile(
    r'\b(?:configurationError|errorMessage|saveError|headline|subtitle|title|'
    r'statusText|captureError|message|label)\s*=\s*$|\?\?\s*$'
)


def expressions(line, start=0):
    """Yield (literal start, catalog skeleton), including literals inside interpolation."""
    i = start
    while i < len(line):
        if line.startswith("//", i):
            break
        if line[i] != '"':
            i += 1
            continue
        opening = i
        i += 1
        key = ""
        while i < len(line) and line[i] != '"':
            if line.startswith(r"\(", i):
                depth = 1
                j = i + 2
                quoted = False
                while j < len(line) and depth:
                    c = line[j]
                    if c == "\\" and quoted:
                        j += 2
                        continue
                    if c == '"':
                        quoted = not quoted
                    elif not quoted:
                        depth += (c == "(") - (c == ")")
                    j += 1
                for pos, inner in expressions(line[i + 2:j - 1]):
                    yield i + 2 + pos, inner
                key += "{}"
                i = j
            elif line[i] == "\\" and i + 1 < len(line):
                key += line[i + 1]
                i += 2
            else:
                key += line[i]
                i += 1
        yield opening, key
        i += 1


def translations(node):
    if "stringUnit" in node:
        yield node["stringUnit"]
    for forms in node.get("variations", {}).values():
        for form in forms.values():
            yield from translations(form)


def audit():
    issues = []
    sources = {}
    catalogs = {}
    for target in TARGETS:
        sources[target] = set((ROOT / target).rglob("*.swift"))
        path = ROOT / target / "Localizable.xcstrings"
        catalogs[target] = json.loads(path.read_text(encoding="utf-8"))["strings"]
    sources["App"].update((ROOT / "GSDKit/Sources").rglob("*.swift"))
    sources["App"].update((ROOT / "Widgets").glob("TodaysFocusView.swift"))
    shared = ROOT / "GSDKit/Sources"
    sources["Widgets"].add(shared / "GSDSnapshot/WidgetSnapshot.swift")
    for target in ("Watch", "ShareExtension"):
        sources[target].add(shared / "GSDModel/Quadrant.swift")
    sources["ShareExtension"].add(shared / "GSDSnapshot/SharedCaptureBuilder.swift")
    sources["Watch"].update((shared / module) for module in (
        "GSDModel/Escalation.swift", "GSDSnapshot/WatchToday.swift"
    ))
    for target in ("Watch", "WatchWidgets"):
        sources[target].update((ROOT / "WatchShared").rglob("*.swift"))
    catalogs["AppShortcuts"] = json.loads(
        (ROOT / "App/AppShortcuts.xcstrings").read_text(encoding="utf-8")
    )["strings"]
    for target, entries in catalogs.items():
        for key, entry in entries.items():
            for lang in ("en", "he"):
                node = entry.get("localizations", {}).get(lang, {})
                units = list(translations(node))
                if not units:
                    issues.append(f"{target}: missing {lang} for {key}")
                for unit in units:
                    value = unit.get("value", "")
                    if not value or unit.get("state") != "translated":
                        issues.append(f"{target}: unfinished {lang} for {key}")
                    if lang == "he" and re.search(r"\?{2,}", value):
                        issues.append(f"{target}: corrupted Hebrew text for {key}")
                    placeholders = FORMAT.findall(key)
                    actual = FORMAT.findall(value)
                    # A singular or dual explicitly spelling out a quantity may omit its number.
                    spelled_quantity = "variations" in node and placeholders == ["%lld"] and not actual
                    if not spelled_quantity and placeholders != actual:
                        issues.append(f"{target}: format mismatch in {lang} for {key}")
        if target == "AppShortcuts":
            swift = (ROOT / "App/Intents/GSDAppIntents.swift").read_text(encoding="utf-8")
            phrases = {s.replace(r"\(.applicationName)", chr(36) + "{applicationName}")
                       for s in re.findall(r'"([^"\n]*\\\(\.applicationName\)[^"\n]*)"', swift)}
            if phrases != set(entries):
                issues.append("AppShortcuts: phrase keys differ from intent declarations")
            continue
        keys = {FORMAT.sub("{}", k) for k in entries}
        count = 0
        for path in sorted(sources[target]):
            for num, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                for pos, key in expressions(line):
                    prefix = line[:pos]
                    if (PLAIN_COPY.search(prefix) and re.match(r"[A-Z][a-z].* [a-z]", key)
                            and not path.is_relative_to(shared)):
                        issues.append(f"{target}: {path.relative_to(ROOT)}:{num}: raw UI copy: {key}")
                    if not UI.search(prefix) or key in INVARIANT:
                        continue
                    if not re.search("[a-zA-Z]", key):
                        continue  # Purely numeric, punctuation or interpolated content.
                    count += 1
                    if key not in keys:
                        issues.append(f"{target}: {path.relative_to(ROOT)}:{num}: {key}")
        print(f"{target}: {len(entries)} keys, {count} literal references checked")
    app = catalogs["App"]
    releases = json.loads((shared / "GSDModel/Resources/whats-new.json").read_text(encoding="utf-8"))
    for release in releases["releases"]:
        if release["platform"] == "apple":
            for key in [release["headline"], *release["new"], *release["improved"], *release["fixed"]]:
                if key and key not in app:
                    issues.append(f"App: missing release note: {key}")
    tools_dir = ROOT / "Packages/GSDHanlinAgent/Sources"
    catalog_source = next(tools_dir.rglob("GSDHanlinToolCatalog.swift")).read_text(encoding="utf-8")
    for title, summary in re.findall(r'\.init\("\w+", "([^"]+)", "([^"]+)"', catalog_source):
        for key in (title, summary):
            if key not in app:
                issues.append(f"App: missing AI tool description: {key}")
    with (ROOT / "App/Info.plist").open("rb") as stream:
        shortcuts = plistlib.load(stream)["UIApplicationShortcutItems"]
    for lang in ("en", "he"):
        info = (ROOT / "App" / f"{lang}.lproj/InfoPlist.strings").read_text(encoding="utf-8")
        for shortcut in shortcuts:
            for field in ("UIApplicationShortcutItemTitle", "UIApplicationShortcutItemSubtitle"):
                key = shortcut[field]
                if not re.search(r'^"' + re.escape(key) + r'"\s*=\s*"[^"]+";', info, re.M):
                    issues.append(f"App: missing {lang} Home Screen shortcut: {key}")
    print(f"AppShortcuts: {len(catalogs['AppShortcuts'])} phrases")
    return issues


if __name__ == "__main__":
    issues = audit()
    for issue in issues:
        print(issue)
    sys.exit(bool(issues))
