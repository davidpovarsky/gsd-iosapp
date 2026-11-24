import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).parent))
import gsd_native_acceptance as native

@unittest.skipUnless(os.name == "posix", "Native runner requires POSIX process groups")
class NativeLogRedactionTests(unittest.TestCase):
    def test_fixture_is_removed_before_log_and_later_summary_are_saved(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "xcodebuild.log"
            secret = "fixture-password-unit-test-431"
            output = native.run([sys.executable, "-c",
                "print('::add-mask::" + secret + "'); print('Type " + secret + "')"], log)
            self.assertNotIn(secret, output)
            self.assertNotIn(secret, log.read_text())
            summary = Path(folder) / "summary.json"
            native.run([sys.executable, "-c", "print('" + secret + "')"], summary)
            self.assertNotIn(secret, summary.read_text())

    def test_failure_log_is_also_redacted(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "failed.log"
            secret = "fixture-password-unit-test-432"
            with self.assertRaises(RuntimeError):
                native.run([sys.executable, "-c",
                    "print('::add-mask::" + secret + "'); raise SystemExit(9)"], log)
            self.assertNotIn(secret, log.read_text())

    def test_timeout_cannot_leave_a_raw_artifact(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / "timeout.log"
            secret = "fixture-password-unit-test-433"
            with self.assertRaises(subprocess.TimeoutExpired):
                native.run([sys.executable, "-u", "-c",
                    "import time; print('::add-mask::" + secret + "'); time.sleep(3)"], log, timeout=1)
            self.assertNotIn(secret, log.read_text())
            self.assertEqual(list(Path(folder).iterdir()), [log])

    def test_timeout_terminates_owned_process_when_group_signal_is_denied(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(
                native.os, "killpg", side_effect=PermissionError("group signal denied")):
            log = Path(folder) / "timeout.log"
            with self.assertRaises(subprocess.TimeoutExpired):
                native.run([sys.executable, "-c", "import time; time.sleep(30)"], log, timeout=1)
            self.assertTrue(log.exists())


class SimulatorLifecycleTests(unittest.TestCase):
    def test_bootstatus_timeout_requires_booted_marker_and_exact_device_state(self):
        for marker, state, expected in ((True, "Booted", True), (False, "Booted", False),
                                         (True, "Shutdown", False), (True, None, False)):
            with self.subTest(marker=marker, state=state), tempfile.TemporaryDirectory() as folder:
                folder = Path(folder)
                (folder / "bootstatus.log").write_text(
                    "Device already booted, nothing to do." if marker else "Waiting for boot")
                with patch.object(native, "run", side_effect=subprocess.TimeoutExpired("bootstatus", 300)), \
                        patch.object(native, "simulator_state", return_value=state):
                    if expected:
                        self.assertEqual(native.await_simulator_boot("owned", folder),
                                         "verified-booted-after-status-timeout")
                    else:
                        with self.assertRaises(subprocess.TimeoutExpired):
                            native.await_simulator_boot("owned", folder)

    def test_shutdown_timeout_is_recovered_only_after_checked_delete_and_absence(self):
        folder = Path("evidence")
        timeout = subprocess.TimeoutExpired("shutdown", 30)
        with patch.object(native, "run", side_effect=[timeout, ""]) as run, \
                patch.object(native, "simulator_state", return_value=None) as state:
            self.assertIn("timed out", native.remove_simulator("owned", folder))
            self.assertEqual(run.call_args.args[0], ["xcrun", "simctl", "delete", "owned"])
            state.assert_called_once_with("owned", folder / "cleanup-inventory.json")
        with patch.object(native, "run", side_effect=[timeout, ""]), \
                patch.object(native, "simulator_state", return_value="Booted"):
            with self.assertRaisesRegex(RuntimeError, "remained after deletion"):
                native.remove_simulator("owned", folder)

if __name__ == "__main__":
    unittest.main()

