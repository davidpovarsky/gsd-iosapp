import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
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

if __name__ == "__main__":
    unittest.main()

