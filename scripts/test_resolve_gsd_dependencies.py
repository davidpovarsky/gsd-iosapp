import tempfile
from pathlib import Path
import unittest
from resolve_gsd_dependencies import is_known_transport_failure, resolve_packages

OBSERVED = """error: 'grdb.swift': Couldn't update repository submodules:
Submodule 'SQLiteCustom/src' (https://github.com/swiftlyfalling/SQLiteLib.git)
fatal: could not read Username for 'https://github.com': terminal prompts disabled
Failed to clone 'SQLiteCustom/src' a second time, aborting
"""

class DependencyRecoveryTests(unittest.TestCase):
    def run_case(self, results, public=True, packages=None):
        calls = []
        answers = iter(results)
        def runner(package):
            calls.append(package)
            return next(answers)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        return calls, lambda: resolve_packages(packages or ["Packages/GSDHanlinAgent"],
            Path(temporary.name), runner=runner, public_check=lambda: public, pause=lambda _: None)

    def test_observed_public_fetch_failure_is_retried_once_before_success(self):
        calls, run = self.run_case([(1, OBSERVED), (0, "resolved")])
        run()
        self.assertEqual(len(calls), 2)

    def test_unconfirmed_repository_is_not_retried(self):
        calls, run = self.run_case([(1, OBSERVED)], public=False)
        with self.assertRaises(RuntimeError):
            run()
        self.assertEqual(len(calls), 1)

    def test_compilation_or_manifest_error_is_not_retried(self):
        calls, run = self.run_case([(1, "error: Invalid manifest; types do not match")])
        with self.assertRaises(RuntimeError):
            run()
        self.assertEqual(len(calls), 1)

    def test_retry_budget_is_shared_across_packages(self):
        calls, run = self.run_case([(1, OBSERVED), (0, "resolved"), (1, OBSERVED)],
                                  packages=["Packages/GSDHanlinAgent", "GSDKit"])
        with self.assertRaises(RuntimeError):
            run()
        self.assertEqual(len(calls), 3)

    def test_repeat_fetch_failure_stops_after_one_retry(self):
        calls, run = self.run_case([(1, OBSERVED), (1, OBSERVED)])
        with self.assertRaises(RuntimeError):
            run()
        self.assertEqual(len(calls), 2)

    def test_unknown_repository_auth_failure_is_not_retryable(self):
        self.assertFalse(is_known_transport_failure(OBSERVED.replace(
            "https://github.com/swiftlyfalling/SQLiteLib.git", "https://github.com/other/private.git")))

if __name__ == "__main__":
    unittest.main()
