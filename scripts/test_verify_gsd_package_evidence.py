#!/usr/bin/env python3
"""Failure cases for reusing package evidence after a native-only change."""
import unittest
from verify_gsd_package_evidence import STEPS, verify_log_bindings, verify_workflow

SHA = "b86d1dbdbf8fb70f170814e966c41ab31fab88e5"
LOG = "2026-11-24T00:57:00.6498490Z   GSD_SOURCE_SHA: " + SHA + "\n2026-11-24T00:57:06.5379210Z Xcode 27.1\n"
WORKFLOW = 'env:\n  GSD_CLOUD_SYSTEM_TEST: "1"\n  GSD_CLOUD_TEST_BASE: https://example.test/gsd-cloud\n' + "".join(
    "      - name: " + name + "\n        shell: bash\n        run: |\n          swift test --filter all\n"
    for name in STEPS)


class PackageEvidenceTests(unittest.TestCase):
    def test_only_execution_condition_may_differ(self):
        changed = WORKFLOW.replace("        shell: bash", "        if: inputs.package_tests_run == ''\n        shell: bash")
        verify_workflow(WORKFLOW, changed)

    def test_changed_filter_rejects_reuse(self):
        with self.assertRaises(ValueError):
            verify_workflow(WORKFLOW, WORKFLOW.replace("--filter all", "--filter partial"))

    def test_cloud_endpoint_or_opt_in_change_rejects_reuse(self):
        for old, new in (("example.test", "other.test"), ('GSD_CLOUD_SYSTEM_TEST: "1"', 'GSD_CLOUD_SYSTEM_TEST: "0"')):
            with self.subTest(change=old), self.assertRaises(ValueError):
                verify_workflow(WORKFLOW, WORKFLOW.replace(old, new))

    def test_missing_named_step_rejects_reuse(self):
        with self.assertRaises(ValueError):
            verify_workflow(WORKFLOW, WORKFLOW.replace(STEPS[1], "A different step"))

    def test_actual_log_format_binds_source_and_xcode(self):
        verify_log_bindings(LOG, SHA, "Xcode 27.1")

    def test_changed_or_ambiguous_source_and_toolchain_reject_reuse(self):
        for log, source, xcode in ((LOG, "0" * 40, "Xcode 27.1"),
                                    (LOG + LOG.replace(SHA, "0" * 40), SHA, "Xcode 27.1"),
                                    (LOG, SHA, "Xcode 27.2")):
            with self.subTest(source=source, xcode=xcode), self.assertRaises(ValueError):
                verify_log_bindings(log, source, xcode)


if __name__ == "__main__":
    unittest.main()
