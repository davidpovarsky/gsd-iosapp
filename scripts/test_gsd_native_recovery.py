#!/usr/bin/env python3
"""Negative guards for reusing a failed run's successfully compiled native app."""
import copy
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
import zlib

import gsd_native_recovery as recovery


def source_fixture():
    run = {"id": recovery.SOURCE_RUN, "run_attempt": 1,
           "repository": {"id": recovery.REPOSITORY_ID, "full_name": recovery.REPOSITORY},
           "head_repository": {"id": recovery.REPOSITORY_ID},
           "head_sha": recovery.SOURCE_SHA, "head_branch": "feat/hanlin-agent-api-20261122",
           "path": recovery.WORKFLOW, "status": "completed", "conclusion": "failure",
           "html_url": "https://github.com/davidpovarsky/gsd-iosapp/actions/runs/45113033128"}
    steps = [{"name": name, "status": "completed", "conclusion": "success"}
             for name in recovery.REQUIRED_STEPS]
    steps.append({"name": recovery.FAILED_STEP, "status": "completed", "conclusion": "failure"})
    jobs = {"jobs": [{"id": 1, "name": "native-acceptance", "status": "completed",
                     "conclusion": "failure", "steps": steps}]}
    return run, jobs


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b""))


def smoke_fixture(app):
    devices = []
    for index, family in enumerate(("iPhone", "iPad")):
        devices.append({"family": family, "status": "passed", "stage": "complete",
                        "processID": 123, "aliveAfterSeconds": 5,
                        "deviceID": f"25fb43eb-cf8c-4202-8681-d02c017db45{index}",
                        "deviceType": "com.apple.CoreSimulator.SimDeviceType." + family + "-Test",
                        "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                        "bootAttempts": [{"attempt": 1, "status": "passed"}],
                        "installation": {"attempts": 1, "status": "passed",
                                         "exitCode": 0, "timeoutSeconds": 300},
                        "screenshot": family.lower() + ".png"})
    return {"status": "passed", "launchMode": "normal (no demo arguments)",
            "bundleID": "dev.vinny.gsd", "app": str(app), "devices": devices}


class RecoveryGuards(unittest.TestCase):
    def test_only_smoke_failure_is_reusable(self):
        run, jobs = source_fixture()
        receipt = recovery.validate_source(run, jobs)
        self.assertEqual(receipt["conclusion"], "failure")
        jobs["jobs"][0]["steps"][0]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "prerequisite"):
            recovery.validate_source(run, jobs)

    def test_wrong_source_sha_and_attempt_are_rejected(self):
        run, jobs = source_fixture()
        for key, value in (("head_sha", "0" * 40), ("run_attempt", 2)):
            wrong = copy.deepcopy(run)
            wrong[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                recovery.validate_source(wrong, jobs)

    def test_harness_only_change_reuses_tree_but_app_and_lockfile_do_not(self):
        source = {"App/GSDApp.swift": "100644 blob abc", "Package.resolved": "100644 blob def"}
        current = {**source, "scripts/gsd_native_recovery.py": "100644 blob new"}
        self.assertTrue(recovery.validate_trees(source, current)["protectedTreeIdentical"])
        for path in source:
            wrong = {**current, path: "100644 blob changed"}
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "rebuild required"):
                recovery.validate_trees(source, wrong)

    def test_artifact_identity_and_bytes_are_bound(self):
        expected = recovery.ARTIFACTS["generated"]
        metadata = {"id": expected["id"], "name": expected["name"], "digest": expected["digest"],
                    "size_in_bytes": expected["size"], "expired": False,
                    "workflow_run": {"id": recovery.SOURCE_RUN, "head_sha": recovery.SOURCE_SHA,
                                     "repository_id": recovery.REPOSITORY_ID,
                                     "head_repository_id": recovery.REPOSITORY_ID}}
        recovery.validate_artifact(metadata, expected)
        wrong = copy.deepcopy(metadata)
        wrong["workflow_run"]["id"] += 1
        with self.assertRaisesRegex(ValueError, "another source"):
            recovery.validate_artifact(wrong, expected)
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "artifact.zip"
            path.write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "digest"):
                recovery.verify_download(path, {"size_in_bytes": 7, "digest": expected["digest"]})

    def test_generated_build_inputs_must_match_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            checkout = Path(temporary) / "checkout"
            archive_path = Path(temporary) / "generated.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                for name in recovery.GENERATED_FILES:
                    target = checkout / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(name.encode())
                    archive.writestr(name, name.encode())
            self.assertTrue(recovery.verify_generated(
                archive_path, checkout)["generatedProjectIdentical"])
            (checkout / "App/Info.plist").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "build input differs"):
                recovery.verify_generated(archive_path, checkout)

    def test_both_normal_device_installs_and_real_pngs_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            app = directory / "GSD.app"
            report = smoke_fixture(app)
            for family in ("iphone", "ipad"):
                (directory / (family + ".png")).write_bytes(png())
            self.assertEqual(len(recovery.validate_smoke(report, directory, app)), 2)
            missing = copy.deepcopy(report)
            missing["devices"].pop()
            with self.assertRaisesRegex(ValueError, "Both distinct"):
                recovery.validate_smoke(missing, directory, app)
            retry = copy.deepcopy(report)
            retry["devices"][1]["installation"]["attempts"] = 2
            with self.assertRaisesRegex(ValueError, "exactly once"):
                recovery.validate_smoke(retry, directory, app)
            demo = copy.deepcopy(report)
            demo["launchMode"] = "demo"
            with self.assertRaisesRegex(ValueError, "normal execution"):
                recovery.validate_smoke(demo, directory, app)
            (directory / "ipad.png").write_bytes(b"\x89PNG\r\n\x1a\n")
            with self.assertRaisesRegex(ValueError, "Incomplete"):
                recovery.validate_smoke(report, directory, app)


if __name__ == "__main__":
    unittest.main()
