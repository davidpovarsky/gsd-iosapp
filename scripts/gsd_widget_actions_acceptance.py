#!/usr/bin/env python3
"""Run one Native-owned, fully bound Widget acceptance inside GitHub Actions.

This adapter never builds products, modifies the native controller, signs, or
uploads to Apple. Its result is Widget-only evidence, not native-acceptance.json.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import sys
import uuid

sys.dont_write_bytecode = True
REPOSITORY = "davidpovarsky/gsd-iosapp"
WORKFLOW = ".github/workflows/gsd-hanlin-agent-ios.yml"
PLAN_ROOT = Path("/Users/m1/builds/gsd-widget-actions-20261125/plans")
RESULT_ROOT = Path("/Users/m1/builds/gsd-widget-actions-20261125/runs")
BUILD_ROOT = Path("/Users/m1/builds")
TEST = "GSDNativeSystemAcceptanceUITests/test01RealWidgetTimelineRefreshAndTaskTap"
SCOPE = "real_home_widget_timeline_refresh_and_row_deep_link"
BUNDLES = {"com.itorah.gsd" + suffix for suffix in (
    "", ".widgets", ".share", ".watchkitapp", ".watchkitapp.widgets")}
INPUTS = {"controller", "wrapper", "capacity", "manifest", "composition",
          "buildTerminal", "sourceClosure", "systemTest", "sdkLock", "generatedProject", "appInfo"}
HELPERS = ("gsd_local_supplemental_validation.py", "gsd_appstore_connect.py",
           "gsd_simulator_smoke.py", "verify_gsd_release_bundle.py")
PUBLIC_FILES = ("widget-actions-receipt.json", "widget-terminal-public.json",
                "widget-binding-public.json", "widget-observation-public.json")


class GuardError(RuntimeError):
    pass


def require(value: bool, code: str) -> None:
    if not value:
        raise GuardError(code)


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def unique_keys(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def read_json(path: Path) -> dict:
    value = json.loads(path.read_bytes().decode("utf-8"), object_pairs_hook=unique_keys)
    require(isinstance(value, dict), "json_object_required")
    return value


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def timestamp(value: str) -> datetime:
    require(isinstance(value, str), "timestamp_type")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timestamp_timezone")
    return parsed.astimezone(timezone.utc)


def hexadecimal(value: str, length: int, code: str) -> str:
    require(isinstance(value, str) and re.fullmatch("[0-9a-f]{" + str(length) + "}", value) is not None, code)
    return value


def plan_identifier(value: str) -> str:
    require(isinstance(value, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{7,63}", value) is not None, "plan_id")
    return value


def confined(raw: str | Path, root: Path, *, exists: bool = True) -> Path:
    path = Path(raw)
    require(path.is_absolute() and ".." not in path.parts, "absolute_confined_path")
    require(path.is_relative_to(root), "path_outside_approved_root")
    current = path
    while current != root.parent:
        require(not current.is_symlink(), "symlink_input")
        current = current.parent
    resolved = path.resolve()
    require(resolved.is_relative_to(root.resolve()), "resolved_path_outside_root")
    if exists:
        require(path.exists(), "missing_bound_path")
    return resolved


def file_spec(spec: dict) -> Path:
    require(isinstance(spec, dict) and set(spec) == {"path", "sha256"}, "file_spec")
    expected = hexadecimal(spec["sha256"], 64, "file_digest")
    path = confined(spec["path"], BUILD_ROOT)
    require(path.is_file() and digest(path) == expected, "bound_file_changed")
    return path


def tree_digest(root: Path) -> dict:
    require(root.is_dir() and not root.is_symlink(), "products_directory")
    rows = []
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "products_symlink")
        if path.is_file():
            rows.append((path.relative_to(root).as_posix(), digest(path)))
    require(bool(rows), "empty_products")
    encoded = json.dumps(rows, separators=(",", ":"), ensure_ascii=True).encode()
    return {"sha256": hashlib.sha256(encoded).hexdigest(), "files": len(rows)}


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, timeout=30)
    require(result.returncode == 0, "git_guard")
    return result.stdout.decode("utf-8")


def verify_source(repo: Path, source: str) -> None:
    require(git(repo, "rev-parse", "HEAD").strip() == source, "owned_source_head")
    records = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all").split("\0")
    for record in records:
        if not record:
            continue
        require("R" not in record[:2] and "C" not in record[:2], "renamed_source")
        path = record[3:]
        require(path == "App/Info.plist" or path.startswith("GSD.xcodeproj/"), "owned_source_dirty")


def final_products(plan: dict, manifest: dict, composition: dict) -> None:
    source = plan["sourceSHA"]
    require(composition.get("kind") == "fresh-complete-products", "not_final_fresh_products")
    require(composition.get("productionSourceSHA") == source
            and composition.get("testSourceSHA") == source
            and manifest.get("sourceSHA") == source, "production_test_source_mismatch")
    require(composition.get("productionTargetCount") == 5
            and composition.get("completeProductsFromSource") is True
            and composition.get("mixedProductionProducts") is False, "incomplete_or_mixed_products")
    require(manifest.get("buildForTestingCompleted") is True
            and type(manifest.get("buildExitCode")) is int and manifest["buildExitCode"] == 0,
            "build_not_completed")
    require(manifest.get("build") == plan["build"] and manifest.get("version") == plan["version"], "product_version")
    require(set(manifest.get("audit", {}).get("targets", {})) == BUNDLES, "five_target_audit_required")
    require(composition.get("productsRoot") == manifest.get("productsRoot") == plan["productsRoot"], "products_root_binding")
    require(composition.get("productsTree") == manifest.get("productsTree"), "products_tree_binding")
    require(composition.get("xctestrunSHA256") == manifest.get("xctestrun", {}).get("sha256"), "xctestrun_binding")


def job_context(plan: dict, plan_sha: str, environment: dict) -> dict:
    require(environment.get("GITHUB_REPOSITORY") == REPOSITORY, "actions_repository")
    require(environment.get("GITHUB_EVENT_NAME") == "workflow_dispatch", "manual_dispatch_required")
    require(environment.get("GITHUB_WORKFLOW_REF", "").startswith(REPOSITORY + "/" + WORKFLOW + "@"), "actions_workflow_path")
    workflow_sha = hexadecimal(environment.get("GITHUB_SHA"), 40, "workflow_sha")
    require(plan.get("workflowSHA") == workflow_sha, "workflow_plan_mismatch")
    for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT"):
        require(re.fullmatch(r"[1-9][0-9]*", environment.get(name, "")) is not None, "actions_run_identity")
    runner = plan.get("runner", {})
    require(runner.get("name") == environment.get("RUNNER_NAME") and bool(runner.get("name")), "owned_runner_name")
    require(runner.get("os") == environment.get("RUNNER_OS") == "macOS", "owned_runner_os")
    require(runner.get("arch") == environment.get("RUNNER_ARCH") == "ARM64", "owned_runner_arch")
    return {"runID": environment["GITHUB_RUN_ID"], "runAttempt": environment["GITHUB_RUN_ATTEMPT"],
            "workflowSHA": workflow_sha, "planSHA256": plan_sha,
            "invocationID": uuid.uuid4().hex, "startedUTC": now()}


def claim_once(directory: Path, plan_id: str, context: dict) -> Path:
    plan_identifier(plan_id)
    directory.mkdir(parents=True, exist_ok=True)
    path = confined(directory / (plan_id + ".json"), PLAN_ROOT, exists=False)
    try:
        with path.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(context, stream, indent=2)
            stream.write("\n")
    except FileExistsError as error:
        raise GuardError("plan_already_claimed") from error
    return path


def verify_inputs(plan: dict) -> tuple[dict, dict]:
    require(set(plan.get("inputFiles", {})) == INPUTS, "input_file_set")
    paths = {key: file_spec(value) for key, value in plan["inputFiles"].items()}
    executable_inputs = plan.get("executableInputs")
    require(isinstance(executable_inputs, list) and bool(executable_inputs), "executable_closure")
    executables = [file_spec(value) for value in executable_inputs]
    require(len(set(executables)) == len(executables), "duplicate_executable_input")
    repo = confined(plan["repoRoot"], BUILD_ROOT)
    required_executables = {paths[key] for key in ("controller", "wrapper", "capacity")}
    required_executables.update(repo / "scripts" / name for name in HELPERS)
    require(required_executables <= set(executables), "executable_closure_incomplete")
    require(type(plan.get("controllerTimeoutSeconds")) is int and 60 <= plan["controllerTimeoutSeconds"] <= 9000, "controller_wall_budget")
    source = hexadecimal(plan["sourceSHA"], 40, "source_sha")
    require(plan.get("version") == "4.1.0" and re.fullmatch(r"[1-9][0-9]*", plan.get("build", "")), "build_version")
    verify_source(repo, source)
    for key, relative in (("systemTest", "ScreenshotTests/GSDNativeSystemAcceptanceUITests.swift"),
                          ("sdkLock", "HanlinSDK.lock.json"), ("generatedProject", "GSD.xcodeproj/project.pbxproj"),
                          ("appInfo", "App/Info.plist")):
        require(paths[key] == (repo / relative).resolve(), "source_input_location")
    products = confined(plan["productsRoot"], BUILD_ROOT)
    result_root = confined(plan["resultRoot"], RESULT_ROOT)
    require(result_root == (RESULT_ROOT / plan["planID"]).resolve(), "result_plan_location")
    require(not any(result_root.is_relative_to(p) or p.is_relative_to(result_root) for p in (repo, products)), "result_overlaps_inputs")
    manifest, composition = read_json(paths["manifest"]), read_json(paths["composition"])
    final_products(plan, manifest, composition)
    require(composition.get("manifestSHA256") == plan["inputFiles"]["manifest"]["sha256"]
            and composition.get("systemTestSHA256") == plan["inputFiles"]["systemTest"]["sha256"], "composition_input_binding")
    require(tree_digest(products) == manifest["productsTree"], "actual_products_changed")
    require(manifest.get("repoRoot") == str(repo), "manifest_repo")
    require(manifest.get("sdkLockSHA256") == plan["inputFiles"]["sdkLock"]["sha256"]
            and manifest.get("projectSHA256") == plan["inputFiles"]["generatedProject"]["sha256"], "sdk_project_binding")
    xctestrun = confined(products / manifest["xctestrun"]["relativePath"], products)
    require(xctestrun.is_file() and digest(xctestrun) == manifest["xctestrun"]["sha256"], "actual_xctestrun_changed")
    build_terminal, source_closure = read_json(paths["buildTerminal"]), read_json(paths["sourceClosure"])
    require(build_terminal.get("passed") is True and build_terminal.get("sourceSHA") == source
            and build_terminal.get("buildForTestingCompleted") is True
            and type(build_terminal.get("buildExitCode")) is int and build_terminal["buildExitCode"] == 0
            and build_terminal.get("runtimeExecuted") is False
            and build_terminal.get("productsTree") == manifest["productsTree"]
            and build_terminal.get("systemTestSHA256") == plan["inputFiles"]["systemTest"]["sha256"]
            and build_terminal.get("appInfoSHA256") == plan["inputFiles"]["appInfo"]["sha256"], "fresh_build_terminal")
    require(source_closure.get("sourceSHA") == source
            and source_closure.get("systemTestSHA256") == plan["inputFiles"]["systemTest"]["sha256"]
            and source_closure.get("appInfoSHA256") == plan["inputFiles"]["appInfo"]["sha256"], "source_closure")
    return paths, manifest


def bounded_times(record: dict, context: dict, end: str) -> None:
    start = timestamp(record.get("startedUTC"))
    finish = timestamp(record.get("finishedUTC"))
    require(timestamp(context["startedUTC"]) <= start <= finish <= timestamp(end), "stale_or_invalid_times")


def expected_counts(value: dict) -> None:
    expected = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
    require(all(type(value.get(key)) is int and value[key] == number for key, number in expected.items()), "exact_widget_test_counts")


def verify_terminal(plan: dict, context: dict, controller_pid: int, controller_exit: int, end: str) -> dict:
    require(controller_exit == 0, "controller_exit_failed")
    result_root = confined(plan["resultRoot"], RESULT_ROOT)
    terminal_path = confined(plan["terminalPath"], result_root)
    require(terminal_path.is_file(), "missing_terminal")
    terminal = read_json(terminal_path)
    require(terminal.get("phase") == "complete" and terminal.get("passed") is True, "terminal_not_passed")
    require(terminal.get("actionsContext") == context, "terminal_actions_identity")
    require(terminal.get("controllerPID") == controller_pid, "controller_pid_binding")
    bounded_times(terminal, context, end)
    source = plan["sourceSHA"]
    require(terminal.get("testSourceSHA") == source and terminal.get("productionSourceSHA") == source, "terminal_source")
    require(set(terminal.get("cases", {})) == {"widget"}, "one_widget_case_only")
    case = terminal["cases"]["widget"]
    require(case.get("passed") is True and type(case.get("returncode")) is int and case["returncode"] == 0, "widget_case_failed")
    require(type(case.get("pid")) is int and case["pid"] > 0, "wrapper_pid_type")
    bounded_times(case, context, end)
    binding_path = confined(case.get("binding", ""), result_root)
    require(digest(binding_path) == case.get("bindingSHA256"), "binding_hash")
    binding = read_json(binding_path)
    require(binding.get("phase") == "complete" and binding.get("passed") is True, "binding_not_passed")
    require(binding.get("actionsContext") == context and binding.get("wrapperPID") == case.get("pid"), "binding_actions_identity")
    bounded_times(binding, context, end)
    require(binding.get("testSourceSHA") == source and binding.get("productionSourceSHA") == source, "binding_source")
    require(binding.get("systemTestSHA256") == plan["inputFiles"]["systemTest"]["sha256"]
            and binding.get("compositionReceiptSHA256") == plan["inputFiles"]["composition"]["sha256"]
            and binding.get("composedManifestSHA256") == plan["inputFiles"]["manifest"]["sha256"], "binding_input_hashes")
    require(binding.get("ownedSimulatorsRemoved") is True and binding.get("sourceAndProductsUnchanged") is True, "binding_preservation")
    require(binding.get("singleCaseOnly") is True and binding.get("selectedKind") == "widget"
            and binding.get("fullSystemSurfaceCoverage") is False and binding.get("accountGrantVerified") is False, "binding_scope")
    require(set(binding.get("suites", {})) == {"widget"}, "binding_one_widget")
    suite = binding["suites"]["widget"]
    require(case.get("case") == suite, "terminal_suite_binding")
    bounded_times(suite, context, end)
    require(suite.get("method") == TEST.split("/", 1)[1] and suite.get("passed") is True, "original_widget_method")
    require(suite.get("ownedDevicesRemoved") is True and type(suite.get("returncode")) is int and suite["returncode"] == 0, "suite_exit_or_cleanup")
    summary = suite.get("testSummary", {})
    expected_counts(summary)
    for key in ("startTime", "finishTime"):
        require(type(summary.get(key)) in (int, float), "xctest_time_type")
    require(timestamp(context["startedUTC"]).timestamp() <= summary["startTime"]
            <= summary["finishTime"] <= timestamp(end).timestamp(), "xctest_stale_times")
    devices = summary.get("devicesAndConfigurations", [])
    require(len(devices) == 1 and devices[0].get("device", {}).get("deviceId") == suite.get("device")
            and devices[0]["device"].get("osBuildNumber") == "24B8117", "xctest_device_binding")
    exact = suite.get("exactTests", {})
    expected_counts(exact)
    require(exact.get("selectedTests") == [TEST], "original_widget_selection")
    command = suite.get("command", [])
    selectors = [arg for arg in command if isinstance(arg, str) and arg.startswith(("-only-testing", "-skip-testing"))]
    require(command[:2] == ["xcodebuild", "test-without-building"]
            and selectors == ["-only-testing:GSDScreenshotTests/" + TEST], "exact_xcode_invocation")
    for flag, expected in (("-testLanguage", "he"), ("-testRegion", "IL"), ("-parallel-testing-enabled", "NO"),
                           ("-destination", "platform=iOS Simulator,id=" + suite.get("device", ""))):
        require(command.count(flag) == 1 and command.index(flag) + 1 < len(command)
                and command[command.index(flag) + 1] == expected, "widget_profile")
    require(not any(arg.startswith(("-retry-tests", "-test-iterations", "-run-tests-until-failure")) for arg in command), "test_retry_forbidden")
    require(suite.get("scope") == SCOPE, "suite_scope")
    artifacts = confined(suite.get("artifacts", ""), result_root)
    observation_path = confined(artifacts / "widget" / "observation.json", result_root)
    require(digest(observation_path) == suite.get("observationSHA256"), "observation_hash")
    observation = read_json(observation_path)
    require(observation == suite.get("observation"), "observation_copy_binding")
    require(observation.get("schemaVersion") == 1 and observation.get("productionSourceSHA") == source
            and observation.get("simulatorID") == suite.get("device") and bool(suite.get("device")), "observation_identity")
    require(all(observation.get(key) is True for key in
                ("passed", "installedWidgetDisplayedInitialTask", "realWidgetTimelineRefreshObserved", "widgetRowOpenedExactTask")), "widget_functional_proof")
    require(observation.get("scope") == SCOPE and all(observation.get(key) is False for key in
            ("shortcutInvoked", "personalAccountUsed", "siriVerified", "voiceOverSpeechVerified", "watchConnectivityVerified")), "observation_scope")
    require(isinstance(observation.get("taskCardID"), str)
            and re.fullmatch(r"task-card-[A-Za-z0-9_-]{1,100}", observation["taskCardID"]), "synthetic_task_identity")
    for key, letter in (("initialTitle", "A"), ("updatedTitle", "B")):
        require(re.fullmatch(r"GSD-Widget-" + letter + r"-[A-F0-9]{8}", observation.get(key, "")) is not None, "synthetic_title")
    require(observation["updatedTitle"].replace("-B-", "-A-", 1) == observation["initialTitle"], "synthetic_title_pair")
    return {"terminal": terminal, "binding": binding, "observation": observation,
            "originalHashes": {"terminal": digest(terminal_path), "binding": digest(binding_path), "observation": digest(observation_path)}}


def public_evidence(verified: dict) -> dict:
    terminal, binding, observation = (verified[key] for key in ("terminal", "binding", "observation"))
    suite = binding["suites"]["widget"]
    return {
        "widget-terminal-public.json": {key: terminal[key] for key in
            ("phase", "passed", "actionsContext", "controllerPID", "testSourceSHA", "productionSourceSHA", "startedUTC", "finishedUTC")},
        "widget-binding-public.json": {**{key: binding[key] for key in
            ("phase", "passed", "actionsContext", "testSourceSHA", "productionSourceSHA", "systemTestSHA256",
             "compositionReceiptSHA256", "composedManifestSHA256", "sourceAndProductsUnchanged",
             "ownedSimulatorsRemoved", "startedUTC", "finishedUTC")},
            "selectedTests": [TEST], "counts": {key: suite["testSummary"][key] for key in
                ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")}},
        "widget-observation-public.json": {key: observation[key] for key in
            ("schemaVersion", "productionSourceSHA", "simulatorID", "passed", "scope", "taskCardID",
             "initialTitle", "updatedTitle", "installedWidgetDisplayedInitialTask",
             "realWidgetTimelineRefreshObserved", "widgetRowOpenedExactTask", "shortcutInvoked",
             "personalAccountUsed", "siriVerified", "voiceOverSpeechVerified", "watchConnectivityVerified")}
    }


def run_controller(controller: Path, log_path: Path, environment: dict, budget: int, receipt: dict) -> int:
    """Signal only the child process group created here; never a shared runner."""
    process = None
    interrupted = False
    timed_out = False

    def request_stop(_number, _frame):
        nonlocal interrupted
        interrupted = True
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    previous = {number: signal.signal(number, request_stop) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        require(not interrupted, "interrupted_before_controller")
        with log_path.open("xb") as log:
            process = subprocess.Popen([sys.executable, "-B", str(controller)], cwd=controller.parent,
                                       env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            receipt["controllerPID"] = process.pid
            deadline = time.monotonic() + budget
            while process.poll() is None:
                if interrupted or time.monotonic() >= deadline:
                    timed_out = not interrupted
                    break
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=120)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                    receipt["ownedControllerRequiredKill"] = True
        require(not interrupted, "actions_interrupted")
        require(not timed_out, "controller_wall_timeout")
        return process.returncode
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)


def run(args: argparse.Namespace) -> int:
    require(sys.platform == "darwin" and sys.version_info[:2] == (3, 12), "owned_mac_python_required")
    identifier = plan_identifier(args.plan_id)
    plan_sha = hexadecimal(args.plan_sha256, 64, "plan_sha")
    source = hexadecimal(args.source_sha, 40, "source_sha")
    plan_path = confined(PLAN_ROOT / (identifier + ".json"), PLAN_ROOT)
    require(digest(plan_path) == plan_sha, "plan_hash")
    plan = read_json(plan_path)
    require(plan.get("schemaVersion") == 1 and plan.get("kind") == "gsd-widget-final-actions-plan"
            and plan.get("planID") == identifier, "plan_schema")
    require(plan.get("sourceSHA") == source and plan.get("build") == args.build, "dispatch_source_or_build")
    require(digest(Path(__file__).resolve()) == plan.get("adapterSHA256"), "adapter_hash")
    context = job_context(plan, plan_sha, os.environ)
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve()
    require(git(workspace, "rev-parse", "HEAD").strip() == context["workflowSHA"], "checkout_workflow_sha")
    output = confined(args.output, workspace, exists=False)
    output.mkdir(parents=True, exist_ok=False)
    receipt = {"schemaVersion": 1, "kind": "gsd-widget-actions-acceptance", "passed": False,
               "workflow": WORKFLOW, "workflowSHA": context["workflowSHA"], "sourceSHA": source,
               "testSourceSHA": source, "productionSourceSHA": source, "build": args.build,
               "scope": SCOPE, "actionsContext": context, "selectedTests": [TEST],
               "nativeAcceptance": False, "fullSystemSurfaceCoverage": False, "accountGrantVerified": False,
               "buildExecutedByAdapter": False, "appleUploadExecuted": False}
    try:
        paths, _ = verify_inputs(plan)
        terminal_path = confined(plan["terminalPath"], Path(plan["resultRoot"]), exists=False)
        require(not terminal_path.exists(), "terminal_exists_before_launch")
        claim_once(PLAN_ROOT / "claims", identifier, context)
        environment = {key: os.environ[key] for key in
                       ("PATH", "HOME", "TMPDIR", "SHELL", "LANG", "LC_ALL", "USER", "LOGNAME", "RUNNER_TRACKING_ID") if key in os.environ}
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["GSD_WIDGET_ACTIONS_CONTEXT"] = json.dumps(context, separators=(",", ":"))
        log_path = Path(plan["resultRoot"]) / "actions-controller-private.log"
        code = run_controller(paths["controller"], log_path, environment, plan["controllerTimeoutSeconds"], receipt)
        end = now()
        receipt["controllerExitCode"] = code
        verified = verify_terminal(plan, context, receipt["controllerPID"], code, end)
        # Recheck every executable, receipt, source and product after the native case.
        require(digest(plan_path) == plan_sha, "plan_changed_during_run")
        verify_inputs(plan)
        receipt.update(passed=True, finishedUTC=end, originalEvidenceSHA256=verified["originalHashes"],
                       counts={"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0},
                       sourceAndProductsUnchanged=True, ownedSimulatorsRemoved=True)
        for name, value in public_evidence(verified).items():
            (output / name).write_bytes(json.dumps(value, indent=2).encode() + b"\n")
    except Exception as error:
        receipt["failureCode"] = str(error) if isinstance(error, GuardError) else "adapter_" + type(error).__name__
        receipt["passed"] = False
        receipt["finishedUTC"] = now()
    finally:
        (output / PUBLIC_FILES[0]).write_bytes(json.dumps(receipt, indent=2).encode() + b"\n")
    print("GSD_WIDGET_ACTIONS_" + ("PASS" if receipt["passed"] else "FAIL"))
    return 0 if receipt["passed"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan-id", required=True)
    parser.add_argument("--plan-sha256", required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        return run(args)
    except Exception as error:
        print("GSD_WIDGET_ACTIONS_BLOCKED " + (str(error) if isinstance(error, GuardError) else type(error).__name__))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
