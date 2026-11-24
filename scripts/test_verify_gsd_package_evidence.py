#!/usr/bin/env python3
"""Failure cases for reusing package evidence after a native-only change."""
import unittest
from verify_gsd_package_evidence import STEPS, verify_log_bindings, verify_workflow

SHA = "b86d1dbdbf8fb70f170814e966c41ab31fab88e5"
XCODE = "Xcode 27.1\nBuild version 27A9275"
LOG = "2026-11-24T00:57:00.6498490Z   GSD_SOURCE_SHA: " + SHA + "\n2026-11-24T00:57:06.5379210Z Xcode 27.1\n"
BUILD_LINE = "2026-11-24T00:57:06.5379210Z Build version 27A9275\n"
METADATA_LINE = "2026-11-24T01:07:41.0309560Z     /Applications/Xcode_27.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/appintentsmetadataprocessor --xcode-version 27A9275 --platform-family iOS\n"
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
        proof = verify_log_bindings(LOG + BUILD_LINE, SHA, XCODE)
        self.assertEqual(proof["build_version"], "27A9275")

    def test_observed_metadata_command_proves_older_log_build(self):
        proof = verify_log_bindings(LOG + METADATA_LINE, SHA, XCODE)
        self.assertEqual(proof["prior_build_provenance"], "xcode-appintents-command-log")

    def test_missing_or_conflicting_build_identity_rejects_reuse(self):
        for log in (LOG, LOG + BUILD_LINE + METADATA_LINE.replace("27A9275", "27A9999")):
            with self.subTest(log=log), self.assertRaises(ValueError):
                verify_log_bindings(log, SHA, XCODE)

    def test_changed_or_ambiguous_source_and_toolchain_reject_reuse(self):
        for log, source, xcode in ((LOG + BUILD_LINE, "0" * 40, XCODE),
                                    (LOG + BUILD_LINE + LOG.replace(SHA, "0" * 40), SHA, XCODE),
                                    (LOG + BUILD_LINE, SHA, XCODE.replace("27.1", "27.2")),
                                    (LOG + BUILD_LINE, SHA, XCODE.replace("27A9275", "27A9999"))):
            with self.subTest(source=source, xcode=xcode), self.assertRaises(ValueError):
                verify_log_bindings(log, source, xcode)


if __name__ == "__main__":
    unittest.main()
