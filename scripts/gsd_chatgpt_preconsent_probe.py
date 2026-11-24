#!/usr/bin/env python3
"""One private native ChatGPT browser-open/cancel probe; never authorization proof.

--output is the ONLY publishable directory. Raw XCTest logs, xcresult, browser
diagnostics and restored products remain in a separate mode-0700 RUNNER_TEMP
directory. The workflow must upload only --output, never that private directory.
The frozen surface helper is a read-only, full-hash-verified dependency.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True
SOURCE = "71b1b7ce4adf7bea2ddacfc683a69906d6acd6ae"
PARENT_RUN = "45397928701"
BUILD = "48"
CORE_COMMIT = "93a46c1e029387d54df9fb8b9be793c378658d5e"
CORE_SHA256 = "dcb677bb6dea2070dac1611070f3372914ff3581626ea4a23c7e0a35f4d1e783"
SWIFT = Path("ScreenshotTests/GSDChatGPTPreConsentUITests.swift")
SWIFT_SHA256 = "01053bfaabfb167e01894f9749b3b1b7fb0462947aa99105b806c7345b9311b0"
SELF = "scripts/gsd_chatgpt_preconsent_probe.py"
WORKFLOW = ".github/workflows/gsd-chatgpt-preconsent.yml"
CLASS = "GSDChatGPTPreConsentUITests"
TEST = "test00ContinueOpensOfficialBrowserAndCancels"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
RUNTIME_BUILD = "24B8117"
VERSIONS = {"build": "Xcode 27.1\nBuild version 27A9275",
            "test": "Xcode 27.0\nBuild version 27A266a"}
CLAIMS_FALSE = ("authorizationSucceeded", "grantVerified", "entitlementVerified",
                "signInPageVerified", "inferenceInvokedByProbe",
                "browserScreenshotsRequestedByProbe", "fullHierarchyRequestedByProbe")
STATES = ("continueActivated", "officialBrowserObserved", "ordinaryCancellationObserved",
          "disconnectedAfterCancel", "disconnectedAfterRelaunch")
PUBLIC_STATES = {"official_browser_visible", "cancelled_before_browser_observation",
                 "secure_window_unavailable", "native_authorization_timed_out",
                 "native_sign_in_failed_unclassified"}
ERROR_MARKERS = {"invalid_request", "invalid_client", "unauthorized_client", "invalid_scope",
                 "unsupported_response_type", "access_denied", "server_error",
                 "temporarily_unavailable", "Something went wrong", "Unable to sign in",
                 "An error occurred"}
PICTURES = {"01-disconnected-before-start.png": "continueActivated",
            "02-disconnected-after-cancel.png": "disconnectedAfterCancel",
            "03-disconnected-after-relaunch.png": "disconnectedAfterRelaunch"}
STOP_REQUESTED = False


class GuardFailure(Exception):
    pass


def require(condition: bool, code: str) -> None:
    if not condition:
        raise GuardFailure(code)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def request_stop(_signum: int, _frame: object) -> None:
    global STOP_REQUESTED
    STOP_REQUESTED = True


def private_run(command: list[str], log: Path, timeout: int = 120,
                env: dict | None = None, check: bool = True) -> tuple[int, str]:
    """No subprocess output or command arguments are printed to public job logs."""
    require(not STOP_REQUESTED, "interrupted")
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("xb") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        deadline = time.monotonic() + timeout
        try:
            while process.poll() is None:
                require(not STOP_REQUESTED, "interrupted")
                require(time.monotonic() < deadline, "command_timeout")
                try:
                    process.wait(timeout=min(1.0, max(0.01, deadline - time.monotonic())))
                except subprocess.TimeoutExpired:
                    pass
        finally:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
    text = log.read_text(encoding="utf-8", errors="replace")
    require(not check or process.returncode == 0, "command_failed")
    return process.returncode, text


def git(repo: Path, *arguments: str) -> bytes:
    result = subprocess.run(["git", "-C", str(repo), *arguments], capture_output=True, timeout=30)
    require(result.returncode == 0, "git_guard_failed")
    return result.stdout


def load_core(repo: Path, path: Path, harness: str) -> object:
    require(sys.flags.optimize == 0 and sys.platform == "darwin", "unsupported_python_host")
    require(git(repo, "rev-parse", "HEAD").decode().strip() == harness, "harness_head")
    git(repo, "merge-base", "--is-ancestor", SOURCE, harness)
    changed = git(repo, "diff", "--name-only", SOURCE, harness).decode().splitlines()
    allowed = {SELF, SWIFT.as_posix(), WORKFLOW}
    require(all(p in allowed or p.startswith("docs/ai-agent/") for p in changed), "unexpected_source_change")
    require(not git(repo, "status", "--porcelain", "--untracked-files=no").strip(), "dirty_tracked_source")
    require(sha(repo / SWIFT) == SWIFT_SHA256, "swift_source_pin")
    require(path.is_file() and not path.is_symlink() and sha(path) == CORE_SHA256, "frozen_helper_pin")
    for name in ("gsd_native_acceptance.py", "gsd_simulator_smoke.py", "resume_gsd_native_acceptance.py",
                 "verify_gsd_release_bundle.py", "gsd_appstore_connect.py"):
        require((repo / "scripts" / name).read_bytes() == git(repo, "show", SOURCE + ":scripts/" + name),
                "frozen_dependency_changed")
    sys.path.insert(0, str(repo / "scripts"))
    spec = importlib.util.spec_from_file_location("_gsd_preconsent_frozen_surface", path)
    require(spec is not None and spec.loader is not None, "helper_import")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    require((module.SOURCE, module.PARENT_RUN, module.BUILD) == (SOURCE, PARENT_RUN, BUILD), "helper_contract")
    return module


def toolchain(directory: Path, role: str, private: Path) -> tuple[dict, dict]:
    require(directory.is_absolute() and directory.is_dir(), "developer_directory")
    directory = directory.resolve()
    # No CI tokens, provider keys or arbitrary TEST_RUNNER variables enter XCTest.
    environment = {k: os.environ[k] for k in ("PATH", "HOME", "USER", "LOGNAME", "TMPDIR") if k in os.environ}
    environment.update(DEVELOPER_DIR=str(directory), LANG="en_US.UTF-8")
    executable = directory / "usr/bin/xcodebuild"
    require(executable.is_file(), "xcodebuild_missing")
    _, version = private_run([str(executable), "-version"], private / (role + "-version.log"), env=environment)
    require(version.strip() == VERSIONS[role], "toolchain_version")
    _, resolved = private_run(["xcrun", "--find", "xcodebuild"], private / (role + "-resolved.log"), env=environment)
    require(Path(resolved.strip()).resolve() == executable.resolve(), "toolchain_resolution")
    return environment, {"version": version.strip(), "developerDir": str(directory),
                         "resolvedXcodebuild": str(executable.resolve())}


def build_runner(core: object, source: Path, private: Path, environment: dict) -> Path:
    spec = core.projection(source)
    core.verify_projection(spec, source)
    projected = private / "test-project"
    projected.mkdir()
    (projected / "project.json").write_text(json.dumps(spec, indent=2) + "\n")
    private_run(["xcodegen", "generate", "--spec", str(projected / "project.json"), "--project", str(projected)],
                private / "xcodegen.log", env=environment)
    project = projected / "GSDSystemSurfaces.xcodeproj"
    text = (project / "project.pbxproj").read_text()
    require(all(s not in text for s in ("PBXTargetDependency", "XCRemoteSwiftPackageReference",
                                       "XCLocalSwiftPackageReference", "PBXShellScriptBuildPhase")), "project_dependency")
    require(text.count("isa = PBXNativeTarget;") == 1 and
            text.count('productType = "com.apple.product-type.bundle.ui-testing";') == 1, "project_target")
    derived = private / "test-derived"
    _, log = private_run([str(Path(environment["DEVELOPER_DIR"]) / "usr/bin/xcodebuild"), "build-for-testing",
        "-project", str(project), "-scheme", "GSDSystemSurfaces", "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", str(derived), "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
        "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES"],
        private / "test-only-build.log", timeout=600, env=environment)
    core.verify_build_plan(log)
    products = derived / "Build/Products"
    require(not list(products.rglob("GSD.app")) and not list(products.rglob("*.appex")), "product_was_built")
    files = list(products.glob("*.xctestrun"))
    require(len(files) == 1, "xctestrun_count")
    config = plistlib.loads(files[0].read_bytes())
    require(not re.search(r"/GSD\.app(?:/|\")", json.dumps(config)), "test_host_app_reference")
    return files[0]


def create_owned(core: object, inventory: dict, device_type: str, private: Path, ledger: dict) -> str:
    before = {d["udid"] for group in inventory["devices"].values() for d in group}
    name = "GSD-ChatGPTPreconsent-en-" + ledger["harnessRunID"] + "-" + uuid.uuid4().hex[:8]
    ledger.update(requested_simulator_name=name, pre_create_simulator_ids=sorted(before))
    (private / "create-intention.json").write_text(json.dumps(ledger, indent=2) + "\n")
    try:
        _, result = private_run(["xcrun", "simctl", "create", name, device_type, RUNTIME], private / "create.log")
    except (OSError, GuardFailure, subprocess.SubprocessError):
        try:
            # One exact-name/runtime/new-UUID reconciliation; never repeat create.
            current = json.loads(core.run(["xcrun", "simctl", "list", "--json"],
                                         private / "create-reconciliation.json", timeout=60))
            ledger["owned_simulator_id"] = core.exact_owned_device(current, name, before)
            ledger["ownership_reconciled_after_create_error"] = True
        except (OSError, RuntimeError, AssertionError, ValueError, subprocess.SubprocessError):
            ledger["create_reconciliation_incomplete"] = True
        raise
    result = result.strip()
    if re.fullmatch(r"[A-Fa-f0-9-]{36}", result) and result not in before:
        ledger["owned_simulator_id"] = result
    _, text = private_run(["xcrun", "simctl", "list", "--json"], private / "created-inventory.json", timeout=60)
    observed = core.exact_owned_device(json.loads(text), name, before)
    ledger["owned_simulator_id"] = observed
    require(result == observed, "owned_device_mismatch")
    return observed


def safe_observation(raw: dict, device: str) -> dict:
    required = {"schemaVersion", "appSourceSHA", "simulatorID", "scope", "language", "probePassed",
                "pageContentClassification", "outcome", "observedAt", *CLAIMS_FALSE, *STATES}
    optional = {"observedOfficialHost", "expectedAuthorizationOrigin", "originEvidence", "observedOrigin",
                "publicState", "publicErrorMarker", "systemPromptObserved", "systemPromptContinued",
                "systemPromptDomain", "browserObservationSummary", "failure"}
    require(isinstance(raw, dict) and required <= set(raw) <= required | optional, "observation_keys")
    require(type(raw["schemaVersion"]) is int and raw["schemaVersion"] == 1, "observation_schema")
    require((raw["appSourceSHA"], raw["simulatorID"], raw["scope"], raw["language"]) ==
            (SOURCE, device, "native_preconsent_start_and_cancel_only", "en"), "observation_identity")
    require(all(raw[k] is False for k in CLAIMS_FALSE), "unproven_claim")
    require(all(type(raw[k]) is bool for k in (*STATES, "probePassed")), "observation_boolean")
    require(raw["pageContentClassification"] in
            {"not_observed", "unclassified", "allowlisted_error_marker_observed"}, "page_classification")
    require(raw["outcome"] in {"incomplete", "official_public_error",
            "official_browser_opened_cancelled_and_disconnected"}, "probe_outcome")
    require(isinstance(raw["observedAt"], str) and
            re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", raw["observedAt"]), "observation_timestamp")
    datetime.fromisoformat(raw["observedAt"].replace("Z", "+00:00"))
    for key, values in {
        "observedOfficialHost": {"auth.openai.com"},
        "expectedAuthorizationOrigin": {"https://auth.openai.com"},
        "observedOrigin": {"https://auth.openai.com"},
        "originEvidence": {"visible_host_only", "visible_https_url"},
        "publicState": PUBLIC_STATES, "publicErrorMarker": ERROR_MARKERS,
        "systemPromptDomain": {"openai.com"}}.items():
        require(key not in raw or raw[key] in values, "unsafe_observation_string")
    for key in ("systemPromptObserved", "systemPromptContinued"):
        require(key not in raw or type(raw[key]) is bool, "prompt_boolean")
    if "browserObservationSummary" in raw:
        owners = raw["browserObservationSummary"]
        require(isinstance(owners, dict) and set(owners) <= {"gsd_app", "springboard"}, "browser_owner")
        numbers = {"ownerState", "webViewCount", "navigationBarCount", "navigationBarsInspected"}
        booleans = {"exactCancelObserved", "uniqueHittableCancelObserved", "officialHostChromeObserved"}
        for item in owners.values():
            require(isinstance(item, dict) and set(item) == numbers | booleans, "browser_summary_keys")
            require(all(type(item[k]) is int and 0 <= item[k] <= 100000 for k in numbers), "browser_counts")
            require(item["ownerState"] <= 4 and item["navigationBarsInspected"] <= 6, "browser_bounds")
            require(all(type(item[k]) is bool for k in booleans), "browser_flags")
    if raw["officialBrowserObserved"]:
        require(raw.get("observedOfficialHost") == "auth.openai.com" and
                raw.get("expectedAuthorizationOrigin") == "https://auth.openai.com" and
                raw.get("publicState") == "official_browser_visible", "official_origin_missing")
        require(raw.get("originEvidence") in {"visible_host_only", "visible_https_url"}, "origin_evidence")
        require(("observedOrigin" in raw) == (raw["originEvidence"] == "visible_https_url"), "origin_scope")
    if raw["probePassed"]:
        require(all(raw[k] is True for k in STATES) and "publicErrorMarker" not in raw and
                "failure" not in raw and raw["pageContentClassification"] == "unclassified" and
                raw["outcome"] == "official_browser_opened_cancelled_and_disconnected", "probe_pass_contract")
    # Drop even source-controlled failure prose. No free-form string enters public artifacts.
    return {key: raw[key] for key in sorted(raw) if key != "failure"}


def safe_test_summary(raw: dict, log: str) -> dict:
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    counts = {key: raw.get(key, 0) for key in keys}
    require(all(type(v) is int and 0 <= v <= 1000 for v in counts.values()), "summary_counts")
    terminals = re.findall(r"(?im)^.*Test [Cc]ase.*\b(passed|failed|skipped)\b.*$", log)
    own = re.findall(r"(?im)^.*Test [Cc]ase.*\b" + CLASS + r"\b.*\b" + TEST +
                     r"\b.*\b(passed|failed|skipped)\b.*$", log)
    require(counts["totalTestCount"] == 1 and len(terminals) == 1 and len(own) == 1, "one_exact_terminal_test")
    outcome = own[0].lower()
    require(counts["passedTests"] == int(outcome == "passed") and
            counts["failedTests"] == int(outcome == "failed") and
            counts["skippedTests"] == int(outcome == "skipped") and
            counts["expectedFailures"] == 0, "summary_log_disagreement")
    return {"selectedTest": CLASS + "/" + TEST, "terminalOutcome": outcome, **counts}


def publish(public: Path, summary: dict, cleanup: dict, observation: dict | None, ui: Path) -> None:
    files = {}
    for name, content in (("probe-summary.json", summary), ("cleanup-proof.json", cleanup),
                          ("siwc-preconsent-observation.json", observation)):
        if content is not None:
            (public / name).write_text(json.dumps(content, indent=2, sort_keys=True) + "\n")
    if observation is not None:
        for name, state in PICTURES.items():
            path = ui / name
            if observation[state] is True and path.exists():
                require(path.is_file() and not path.is_symlink(), "screenshot_path")
                data = path.read_bytes()
                require(24 <= len(data) <= 25_000_000 and data[:8] == b"\x89PNG\r\n\x1a\n" and
                        data[12:16] == b"IHDR", "screenshot_format")
                (public / name).write_bytes(data)
    for path in public.iterdir():
        require(path.name in {"probe-summary.json", "cleanup-proof.json",
                "siwc-preconsent-observation.json", *PICTURES}, "public_output_allowlist")
        files[path.name] = {"sha256": sha(path), "bytes": path.stat().st_size}
    (public / "public-manifest.json").write_text(json.dumps({"schemaVersion": 1, "files": files}, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-sha", "run-id", "build", "runtime-build"):
        parser.add_argument("--" + name, required=True)
    for name in ("output", "surface-helper", "build-developer-dir", "test-developer-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    require((args.source_sha, args.run_id, args.build, args.runtime_build) ==
            (SOURCE, PARENT_RUN, BUILD, RUNTIME_BUILD), "fixed_provenance_arguments")
    os.umask(0o077)
    public = args.output.resolve()
    public.mkdir(parents=True, exist_ok=False)
    private = Path(tempfile.mkdtemp(prefix="gsd-siwc-preconsent-private-", dir=os.environ.get("RUNNER_TEMP")))
    require(not public.is_relative_to(private) and not private.is_relative_to(public), "private_output_separation")
    repo = Path(__file__).resolve().parents[1]
    harness, run_id = os.environ.get("GITHUB_SHA", ""), os.environ.get("GITHUB_RUN_ID", "")
    require(re.fullmatch(r"[0-9a-f]{40}", harness) and run_id.isdigit(), "harness_identity")
    summary = {"schemaVersion": 1, "appSourceSHA": SOURCE, "compiledProductRunID": PARENT_RUN,
        "build": BUILD, "harnessSHA": harness, "harnessRunID": run_id, "testSourceSHA256": SWIFT_SHA256,
        "frozenHelperCommit": CORE_COMMIT, "frozenHelperSHA256": CORE_SHA256, "language": "en",
        "scope": "native_preconsent_start_and_cancel_only", "probePassed": False, "fullAcceptance": False,
        "accountFixturesCreatedByProbe": 0, **{key: False for key in CLAIMS_FALSE}}
    ledger = {"harnessRunID": run_id, "artifacts": {}}
    cleanup_proof = {"ownedSimulatorCreated": False, "ownedSimulatorRemovedVerified": False,
                     "noUnrelatedSimulatorMutationRequested": True}
    core = app = before_tree = device = observation = None
    ui, result = private / "ui", private / "Results.xcresult"
    ui.mkdir()
    phase, code, test_log = "source_provenance", None, ""
    started = time.monotonic()
    old_handlers = {s: signal.signal(s, request_stop) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        core = load_core(repo, args.surface_helper, harness)
        phase = "toolchains"
        build_env, summary["compiler"] = toolchain(args.build_developer_dir, "build", private)
        driver_env, summary["xctestDriver"] = toolchain(args.test_developer_dir, "test", private)
        # Process-local only: frozen simulator helpers inherit the explicitly verified driver.
        os.environ["DEVELOPER_DIR"] = driver_env["DEVELOPER_DIR"]
        phase = "restore_and_audit"
        app = core.restore(private, ledger)
        audit = core.audit_products(app, private)
        before_tree = core.tree_digest(app)
        summary["productTreeBefore"] = before_tree
        summary["fiveBundleAuditPassed"] = len(audit["targets"]) == 5
        require(summary["fiveBundleAuditPassed"], "five_bundle_audit")
        phase = "standalone_test_build"
        xctestrun = build_runner(core, repo / SWIFT, private, build_env)
        require(core.tree_digest(app) == before_tree, "product_changed_during_build")
        phase = "owned_simulator"
        _, raw_inventory = private_run(["xcrun", "simctl", "list", "--json"], private / "inventory.json", env=driver_env)
        inventory = json.loads(raw_inventory)
        runtimes = [r for r in inventory["runtimes"] if r["identifier"] == RUNTIME and r.get("isAvailable")]
        require(len(runtimes) == 1 and (runtimes[0]["version"], runtimes[0]["buildversion"]) ==
                ("27.2", RUNTIME_BUILD), "exact_available_runtime")
        selected = core.devices_for_runtime(inventory, runtimes[0])["iPhone"]
        device = create_owned(core, inventory, selected["identifier"], private, ledger)
        summary["simulator"] = {"id": device, "deviceType": selected["identifier"], "runtime": RUNTIME,
                                "runtimeVersion": "27.2", "runtimeBuild": RUNTIME_BUILD}
        _, created = private_run(["xcrun", "simctl", "list", "devices", "--json"], private / "created.json", env=driver_env)
        matches = [d for g in json.loads(created)["devices"].values() for d in g if d["udid"] == device]
        require(len(matches) == 1 and matches[0]["state"] == "Shutdown", "fresh_device_state")
        data_path = Path(matches[0]["dataPath"]).resolve()
        require(data_path.name == "data" and data_path.parent.name.upper() == device.upper(), "owned_data_path")
        prefs = data_path / "Library/Preferences/.GlobalPreferences.plist"
        values = plistlib.loads(prefs.read_bytes()) if prefs.exists() else {}
        values.update(AppleLanguages=["en"], AppleLocale="en_US")
        prefs.parent.mkdir(parents=True, exist_ok=True)
        prefs.write_bytes(plistlib.dumps(values))
        core.boot_device(device, private / "boot.log", ledger)
        _, language = private_run(["xcrun", "simctl", "spawn", device, "defaults", "read", "-g", "AppleLanguages"],
                                  private / "language.log", env=driver_env)
        _, locale = private_run(["xcrun", "simctl", "spawn", device, "defaults", "read", "-g", "AppleLocale"],
                                private / "locale.log", env=driver_env)
        require(re.search(r"\ben\b", language) and locale.strip() == "en_US", "english_locale")
        private_run(["xcrun", "simctl", "install", device, str(app)], private / "install.log", timeout=300, env=driver_env)
        _, container = private_run(["xcrun", "simctl", "get_app_container", device, "com.itorah.gsd", "app"],
                                   private / "installed-path.log", env=driver_env)
        require(core.tree_digest(Path(container.strip())) == before_tree, "installed_product_identity")
        phase = "single_preconsent_test"
        require(time.monotonic() - started < 1800, "setup_budget")
        driver_env.update({"TEST_RUNNER_GSD_TEST_LANGUAGE": "en",
            "TEST_RUNNER_GSD_SIWC_PRECONSENT_ARTIFACTS": str(ui),
            "TEST_RUNNER_GSD_SIWC_PRECONSENT_SIMULATOR_UDID": device,
            "TEST_RUNNER_GSD_SIWC_PRECONSENT_FRESH_SIMULATOR": "1",
            "TEST_RUNNER_GSD_SIWC_PRECONSENT_APP_SOURCE": SOURCE})
        code, test_log = private_run([summary["xctestDriver"]["resolvedXcodebuild"], "test-without-building",
            "-xctestrun", str(xctestrun), "-destination", "platform=iOS Simulator,id=" + device,
            "-destination-timeout", "90", "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result),
            "-testLanguage", "en", "-testRegion", "US", "-only-testing:GSDScreenshotTests/" + CLASS + "/" + TEST],
            private / "xcodebuild-private.log", timeout=600, env=driver_env, check=False)
        phase = "private_result_validation"
        _, raw_summary = private_run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)],
                                     private / "summary-private.json", timeout=120, env=driver_env)
        summary["test"] = safe_test_summary(json.loads(raw_summary), test_log)
        observation = safe_observation(json.loads((ui / "siwc-preconsent-observation.json").read_text()), device)
        require(code == 0 and summary["test"]["terminalOutcome"] == "passed" and observation["probePassed"], "probe_incomplete")
        require(all((ui / name).is_file() for name in PICTURES), "required_app_screenshots")
        summary["probePassed"] = True
    except Exception as error:
        summary.update(probePassed=False, stoppedAt=phase,
                       failureCode=str(error) if isinstance(error, GuardFailure) else "private_" + type(error).__name__)
    finally:
        if observation is None and device and (ui / "siwc-preconsent-observation.json").is_file():
            try:
                observation = safe_observation(json.loads((ui / "siwc-preconsent-observation.json").read_text()), device)
            except Exception:
                summary["observationWithheld"] = True
        if app is not None and before_tree is not None:
            try:
                summary["productTreeAfter"] = core.tree_digest(app)
                require(summary["productTreeAfter"] == before_tree, "product_changed")
                summary["productsUnchanged"] = True
            except Exception:
                summary.update(probePassed=False, productsUnchanged=False)
        device = device or ledger.get("owned_simulator_id")
        if device:
            cleanup_proof.update(ownedSimulatorCreated=True, ownedSimulatorID=device)
            try:
                core.cleanup(device, private, ledger)
                cleanup_proof["ownedSimulatorRemovedVerified"] = ledger.get("created_simulator_removed") is True
            except Exception:
                summary["probePassed"] = False
                cleanup_proof["cleanupIncomplete"] = True
        if not cleanup_proof["ownedSimulatorRemovedVerified"] or STOP_REQUESTED:
            summary["probePassed"] = False
        summary["completedAt"] = datetime.now(timezone.utc).isoformat()
        summary["elapsedSeconds"] = round(time.monotonic() - started, 3)
        (private / "private-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
        try:
            publish(public, summary, cleanup_proof, observation, ui)
        except Exception:
            # No unsafe field or image becomes a published success.
            summary.update(probePassed=False, publicExportFailed=True)
            (public / "probe-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        print("GSD_SIWC_PRECONSENT_PASSED" if summary["probePassed"] else "GSD_SIWC_PRECONSENT_INCOMPLETE", flush=True)
    return 0 if summary["probePassed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
