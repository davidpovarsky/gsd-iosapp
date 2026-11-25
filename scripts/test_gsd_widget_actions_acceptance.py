#!/usr/bin/env python3
"""Focused adversarial checks for the Widget-only Actions evidence adapter."""
import copy
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("widget_actions", HERE / "gsd_widget_actions_acceptance.py")
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class WidgetActionsGuards(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.patches = [
            mock.patch.object(m, "BUILD_ROOT", self.root),
            mock.patch.object(m, "RESULT_ROOT", self.root / "runs"),
            mock.patch.object(m, "PLAN_ROOT", self.root / "plans"),
        ]
        for patch in self.patches:
            patch.start()
        self.directory = self.root / "runs" / "fixture-20261125"
        self.directory.mkdir(parents=True)
        self.make_case()

    def tearDown(self):
        for patch in reversed(self.patches):
            patch.stop()
        self.temporary.cleanup()

    def make_case(self):
        self.source = "b" * 40
        self.context = {
            "runID": "123456", "runAttempt": "1", "workflowSHA": "a" * 40,
            "planSHA256": "c" * 64, "invocationID": "d" * 32,
            "startedUTC": "2026-11-25T04:00:00+00:00",
        }
        self.end = "2026-11-25T04:00:20+00:00"
        self.plan = {
            "sourceSHA": self.source, "resultRoot": str(self.directory),
            "terminalPath": str(self.directory / "terminal.json"),
            "inputFiles": {key: {"sha256": letter * 64}
                           for key, letter in (("systemTest", "1"), ("composition", "2"), ("manifest", "3"))},
        }
        self.artifacts = self.directory / "private" / "widget-ui"
        self.observation_path = self.artifacts / "widget" / "observation.json"
        self.observation_path.parent.mkdir(parents=True, exist_ok=True)
        self.observation = {
            "schemaVersion": 1, "productionSourceSHA": self.source, "simulatorID": "owned-device",
            "passed": True, "scope": m.SCOPE, "taskCardID": "task-card-synthetic_123",
            "initialTitle": "GSD-Widget-A-1234ABCD", "updatedTitle": "GSD-Widget-B-1234ABCD",
            "installedWidgetDisplayedInitialTask": True, "realWidgetTimelineRefreshObserved": True,
            "widgetRowOpenedExactTask": True, "shortcutInvoked": False, "personalAccountUsed": False,
            "siriVerified": False, "voiceOverSpeechVerified": False, "watchConnectivityVerified": False,
        }
        counts = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "expectedFailures": 0}
        self.suite = {
            "passed": True, "method": m.TEST.split("/", 1)[1], "ownedDevicesRemoved": True,
            "returncode": 0, "scope": m.SCOPE, "device": "owned-device", "artifacts": str(self.artifacts),
            "startedUTC": "2026-11-25T04:00:03+00:00", "finishedUTC": "2026-11-25T04:00:13+00:00",
            "testSummary": {
                **counts, "startTime": datetime.fromisoformat("2026-11-25T04:00:05+00:00").timestamp(),
                "finishTime": datetime.fromisoformat("2026-11-25T04:00:12+00:00").timestamp(),
                "devicesAndConfigurations": [{"device": {"deviceId": "owned-device", "osBuildNumber": "24B8117"}}],
            },
            "exactTests": {**counts, "selectedTests": [m.TEST]},
            "command": ["xcodebuild", "test-without-building", "-destination", "platform=iOS Simulator,id=owned-device",
                        "-testLanguage", "he", "-testRegion", "IL", "-parallel-testing-enabled", "NO",
                        "-only-testing:GSDScreenshotTests/" + m.TEST],
        }
        self.binding = {
            "phase": "complete", "passed": True, "actionsContext": copy.deepcopy(self.context), "wrapperPID": 222,
            "testSourceSHA": self.source, "productionSourceSHA": self.source,
            "systemTestSHA256": "1" * 64, "compositionReceiptSHA256": "2" * 64, "composedManifestSHA256": "3" * 64,
            "ownedSimulatorsRemoved": True, "sourceAndProductsUnchanged": True, "singleCaseOnly": True,
            "selectedKind": "widget", "fullSystemSurfaceCoverage": False, "accountGrantVerified": False,
            "startedUTC": "2026-11-25T04:00:02+00:00", "finishedUTC": "2026-11-25T04:00:14+00:00",
            "suites": {"widget": self.suite},
        }
        self.terminal = {
            "phase": "complete", "passed": True, "actionsContext": copy.deepcopy(self.context),
            "controllerPID": 111, "testSourceSHA": self.source, "productionSourceSHA": self.source,
            "startedUTC": "2026-11-25T04:00:01+00:00", "finishedUTC": "2026-11-25T04:00:15+00:00",
            "cases": {"widget": {"passed": True, "returncode": 0, "pid": 222,
                                "startedUTC": "2026-11-25T04:00:01+00:00", "finishedUTC": "2026-11-25T04:00:15+00:00"}},
        }
        self.write_case()

    @staticmethod
    def write(path, value):
        path.write_bytes(json.dumps(value, indent=2).encode() + b"\n")

    def write_case(self):
        self.write(self.observation_path, self.observation)
        self.suite["observation"] = copy.deepcopy(self.observation)
        self.suite["observationSHA256"] = m.digest(self.observation_path)
        binding_path = self.directory / "binding.json"
        self.write(binding_path, self.binding)
        self.terminal["cases"]["widget"].update(binding=str(binding_path), bindingSHA256=m.digest(binding_path),
                                                   case=copy.deepcopy(self.suite))
        self.write(Path(self.plan["terminalPath"]), self.terminal)

    def verify(self, code=0):
        return m.verify_terminal(self.plan, self.context, 111, code, self.end)

    def rejects(self, code=0):
        self.write_case()
        with self.assertRaises(m.GuardError):
            self.verify(code)

    def test_complete_original_case_is_widget_only_with_separate_workflow_sha(self):
        result = self.verify()
        self.assertNotEqual(result["terminal"]["actionsContext"]["workflowSHA"], result["terminal"]["productionSourceSHA"])
        exported = m.public_evidence(result)
        self.assertEqual(set(exported), set(m.PUBLIC_FILES) - {"widget-actions-receipt.json"})
        self.assertEqual(exported["widget-binding-public.json"]["selectedTests"], [m.TEST])

    def test_exit_zero_cannot_turn_failed_terminal_green(self):
        self.terminal["passed"] = False
        self.rejects(code=0)

    def test_nonzero_controller_is_rejected_even_with_passing_receipts(self):
        with self.assertRaisesRegex(m.GuardError, "controller_exit_failed"):
            self.verify(code=1)

    def test_missing_terminal_fails(self):
        Path(self.plan["terminalPath"]).unlink()
        with self.assertRaises(m.GuardError):
            self.verify()

    def test_stale_terminal_and_stale_xctest_are_rejected(self):
        self.terminal["startedUTC"] = "2026-11-24T04:00:00+00:00"
        self.rejects()
        self.make_case()
        self.suite["testSummary"]["startTime"] -= 86400
        self.rejects()

    def test_actions_nonce_and_run_identity_must_match(self):
        for key in ("runID", "runAttempt", "workflowSHA", "planSHA256", "invocationID"):
            with self.subTest(key=key):
                self.make_case()
                self.binding["actionsContext"][key] = "different"
                self.rejects()

    def test_controller_and_wrapper_pids_are_bound(self):
        self.terminal["controllerPID"] = 999
        self.rejects()
        self.make_case()
        self.binding["wrapperPID"] = 999
        self.rejects()

    def test_production_and_test_sources_cannot_be_mixed(self):
        self.binding["productionSourceSHA"] = "f" * 40
        self.rejects()

    def test_diagnostic_or_additional_method_is_rejected(self):
        self.suite["method"] = "test03DiagnoseWidgetRoute"
        self.rejects()
        self.make_case()
        self.suite["exactTests"]["selectedTests"].append("Other/test")
        self.rejects()

    def test_zero_skip_expected_failure_and_boolean_counts_are_rejected(self):
        for key, bad in (("totalTestCount", 0), ("passedTests", 0), ("failedTests", 1),
                         ("skippedTests", 1), ("expectedFailures", 1), ("passedTests", True)):
            with self.subTest(key=key, bad=bad):
                self.make_case()
                self.suite["testSummary"][key] = bad
                self.rejects()

    def test_all_four_widget_flags_are_required(self):
        for key in ("passed", "installedWidgetDisplayedInitialTask", "realWidgetTimelineRefreshObserved", "widgetRowOpenedExactTask"):
            with self.subTest(key=key):
                self.make_case()
                self.observation[key] = False
                self.rejects()

    def test_cleanup_and_preservation_cannot_be_missing(self):
        for key in ("ownedSimulatorsRemoved", "sourceAndProductsUnchanged"):
            with self.subTest(key=key):
                self.make_case()
                self.binding.pop(key)
                self.rejects()
        self.make_case()
        self.suite["ownedDevicesRemoved"] = False
        self.rejects()

    def test_changed_observation_bytes_are_rejected(self):
        self.observation_path.write_bytes(self.observation_path.read_bytes() + b" ")
        with self.assertRaisesRegex(m.GuardError, "observation_hash"):
            self.verify()

    def test_binding_cannot_escape_owned_result_root(self):
        self.terminal["cases"]["widget"]["binding"] = str(self.root / "outside.json")
        self.write(Path(self.plan["terminalPath"]), self.terminal)
        with self.assertRaisesRegex(m.GuardError, "path_outside_approved_root"):
            self.verify()

    def test_runtime_profile_and_retry_are_enforced(self):
        self.suite["command"][self.suite["command"].index("-testLanguage") + 1] = "en"
        self.rejects()
        self.make_case()
        self.suite["command"].extend(["-test-iterations", "2"])
        self.rejects()
        self.make_case()
        self.suite["testSummary"]["devicesAndConfigurations"][0]["device"]["osBuildNumber"] = "other"
        self.rejects()

    def test_the_same_synthetic_task_title_pair_is_required(self):
        self.observation["updatedTitle"] = "GSD-Widget-B-9999ABCD"
        self.rejects()

    def test_unproven_personal_claim_and_scope_are_rejected(self):
        self.observation["personalAccountUsed"] = True
        self.rejects()
        self.make_case()
        self.binding["accountGrantVerified"] = True
        self.rejects()

    def test_public_allowlist_does_not_copy_unknown_secrets_or_paths(self):
        self.observation["access_token"] = "do-not-publish-this"
        self.binding["privateLog"] = "/private/credentials"
        self.terminal["unsafeDescription"] = "do-not-publish-this"
        self.write_case()
        public = json.dumps(m.public_evidence(self.verify()))
        self.assertNotIn("do-not-publish-this", public)
        self.assertNotIn("/private/credentials", public)
        self.assertNotIn("artifacts", public)

    def test_plan_ids_cannot_supply_paths_or_shell_commands(self):
        for value in ("../escape", "x/y", "x; touch ignored", "$(anything)", "", "UPPERCASE-ID"):
            with self.subTest(value=value), self.assertRaises(m.GuardError):
                m.plan_identifier(value)

    def test_claim_is_exclusive_across_actions_attempts(self):
        directory = m.PLAN_ROOT / "claims"
        m.claim_once(directory, "fixture-20261125", self.context)
        second = {**self.context, "runAttempt": "2"}
        with self.assertRaisesRegex(m.GuardError, "plan_already_claimed"):
            m.claim_once(directory, "fixture-20261125", second)

    def test_duplicate_json_keys_are_rejected(self):
        path = self.directory / "duplicate.json"
        path.write_bytes(b'{"passed":false,"passed":true}')
        with self.assertRaisesRegex(m.GuardError, "duplicate_json_key"):
            m.read_json(path)

    def test_bound_executable_change_is_rejected(self):
        path = self.root / "controller.py"
        path.write_bytes(b"original")
        specification = {"path": str(path), "sha256": m.digest(path)}
        self.assertEqual(m.file_spec(specification), path)
        path.write_bytes(b"changed")
        with self.assertRaisesRegex(m.GuardError, "bound_file_changed"):
            m.file_spec(specification)

    def test_diagnostic_mixed_and_incomplete_products_cannot_satisfy_final_gate(self):
        plan = {"sourceSHA": self.source, "build": "49", "version": "4.1.0", "productsRoot": "/products"}
        manifest = {"sourceSHA": self.source, "build": "49", "version": "4.1.0",
                    "buildForTestingCompleted": True, "buildExitCode": 0, "productsRoot": "/products",
                    "productsTree": {"sha256": "a" * 64, "files": 10}, "xctestrun": {"sha256": "b" * 64},
                    "audit": {"targets": {identifier: {} for identifier in m.BUNDLES}}}
        composition = {"kind": "fresh-complete-products", "productionSourceSHA": self.source,
                       "testSourceSHA": self.source, "productionTargetCount": 5, "completeProductsFromSource": True,
                       "mixedProductionProducts": False, "productsRoot": "/products",
                       "productsTree": manifest["productsTree"], "xctestrunSHA256": "b" * 64}
        m.final_products(plan, manifest, composition)
        for key, bad in (("kind", "complete_fresh_diagnostic_products"), ("mixedProductionProducts", True),
                         ("completeProductsFromSource", False), ("productionTargetCount", 4),
                         ("productionSourceSHA", "f" * 40)):
            with self.subTest(key=key), self.assertRaises(m.GuardError):
                m.final_products(plan, manifest, {**composition, key: bad})
        with self.assertRaises(m.GuardError):
            m.final_products(plan, {**manifest, "buildForTestingCompleted": False}, composition)

    def test_generated_app_info_is_bound_before_and_after_execution(self):
        # Generated Info bytes are accepted by their actual digest, not a Git blob.
        repo, products = self.root / "source", self.root / "products"
        products.mkdir()
        (products / "test.xctestrun").write_bytes(b"captured test configuration")
        paths = {}
        relative = {
            "systemTest": "ScreenshotTests/GSDNativeSystemAcceptanceUITests.swift",
            "sdkLock": "HanlinSDK.lock.json", "generatedProject": "GSD.xcodeproj/project.pbxproj",
            "appInfo": "App/Info.plist",
        }
        for key, name in relative.items():
            paths[key] = repo / name
            paths[key].parent.mkdir(parents=True, exist_ok=True)
            paths[key].write_bytes(("generated and captured " + key).encode())
        for key in ("controller", "wrapper", "capacity", "manifest", "composition", "buildTerminal", "sourceClosure"):
            paths[key] = self.root / (key + ".json")
            paths[key].write_bytes(b"captured")
        helpers = []
        for name in m.HELPERS:
            path = repo / "scripts" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"captured helper")
            helpers.append(path)
        spec = lambda path: {"path": str(path), "sha256": m.digest(path)}
        system_hash, info_hash = m.digest(paths["systemTest"]), m.digest(paths["appInfo"])
        tree = m.tree_digest(products)
        manifest = {
            "sourceSHA": self.source, "repoRoot": str(repo), "productsRoot": str(products),
            "build": "49", "version": "4.1.0", "buildForTestingCompleted": True, "buildExitCode": 0,
            "productsTree": tree, "xctestrun": {"relativePath": "test.xctestrun", "sha256": m.digest(products / "test.xctestrun")},
            "audit": {"targets": {identifier: {} for identifier in m.BUNDLES}},
            "sdkLockSHA256": m.digest(paths["sdkLock"]), "projectSHA256": m.digest(paths["generatedProject"]),
        }
        self.write(paths["manifest"], manifest)
        self.write(paths["composition"], {
            "kind": "fresh-complete-products", "productionSourceSHA": self.source, "testSourceSHA": self.source,
            "productionTargetCount": 5, "completeProductsFromSource": True, "mixedProductionProducts": False,
            "productsRoot": str(products), "productsTree": tree, "xctestrunSHA256": manifest["xctestrun"]["sha256"],
            "manifestSHA256": m.digest(paths["manifest"]), "systemTestSHA256": system_hash,
        })
        build = {"passed": True, "sourceSHA": self.source, "buildForTestingCompleted": True, "buildExitCode": 0,
                 "runtimeExecuted": False, "productsTree": tree, "systemTestSHA256": system_hash, "appInfoSHA256": info_hash}
        closure = {"sourceSHA": self.source, "systemTestSHA256": system_hash, "appInfoSHA256": info_hash}
        self.write(paths["buildTerminal"], build)
        self.write(paths["sourceClosure"], closure)
        plan = {
            "sourceSHA": self.source, "build": "49", "version": "4.1.0", "repoRoot": str(repo), "productsRoot": str(products),
            "resultRoot": str(self.directory), "planID": "fixture-20261125", "controllerTimeoutSeconds": 600,
            "inputFiles": {key: spec(path) for key, path in paths.items()},
            "executableInputs": [spec(paths[key]) for key in ("controller", "wrapper", "capacity")] + [spec(p) for p in helpers],
        }
        with mock.patch.object(m, "verify_source"):
            m.verify_inputs(plan)
            missing = copy.deepcopy(plan)
            del missing["inputFiles"]["appInfo"]
            with self.assertRaisesRegex(m.GuardError, "input_file_set"):
                m.verify_inputs(missing)
            captured = paths["appInfo"].read_bytes()
            paths["appInfo"].write_bytes(b"changed after capture")
            with self.assertRaisesRegex(m.GuardError, "bound_file_changed"):
                m.verify_inputs(plan)
            paths["appInfo"].write_bytes(captured)
            for key, value, error in (("buildTerminal", build, "fresh_build_terminal"), ("sourceClosure", closure, "source_closure")):
                with self.subTest(receipt=key):
                    self.write(paths[key], {**value, "appInfoSHA256": "f" * 64})
                    changed = copy.deepcopy(plan)
                    changed["inputFiles"][key] = spec(paths[key])
                    with self.assertRaisesRegex(m.GuardError, error):
                        m.verify_inputs(changed)
                    self.write(paths[key], value)

    def test_dispatch_and_runner_identity_are_required(self):
        plan = {"workflowSHA": "a" * 40, "runner": {"name": "owned", "os": "macOS", "arch": "ARM64"}}
        environment = {"GITHUB_REPOSITORY": m.REPOSITORY, "GITHUB_EVENT_NAME": "workflow_dispatch",
                       "GITHUB_WORKFLOW_REF": m.REPOSITORY + "/" + m.WORKFLOW + "@refs/heads/reviewed",
                       "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1",
                       "RUNNER_NAME": "owned", "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64"}
        m.job_context(plan, "c" * 64, environment)
        for key, bad in (("GITHUB_REPOSITORY", "other/repo"), ("GITHUB_EVENT_NAME", "pull_request"),
                         ("GITHUB_SHA", "b" * 40), ("RUNNER_NAME", "other"), ("RUNNER_ARCH", "X64")):
            with self.subTest(key=key), self.assertRaises(m.GuardError):
                m.job_context(plan, "c" * 64, {**environment, key: bad})


if __name__ == "__main__":
    unittest.main(verbosity=2)
