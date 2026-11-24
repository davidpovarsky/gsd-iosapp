import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
spec=importlib.util.spec_from_file_location("supplemental",HERE/"gsd_local_supplemental_validation.py")
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

class SupplementalGuardTests(unittest.TestCase):
 def test_changed_product_tree_is_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);(root/"app").write_bytes(b"original")
   before=m.tree_digest(root);(root/"app").write_bytes(b"changed")
   with self.assertRaisesRegex(m.GuardFailure,"products_changed"):
    m.verify_tree(root,before)
 def test_symlinked_product_is_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);(root/"outside").symlink_to("/etc/passwd")
   with self.assertRaisesRegex(m.GuardFailure,"product_symlink"):
    m.tree_digest(root)
 def test_clean_source_allows_only_generated_files(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp)
   subprocess.run(["git","init","-q",str(root)],check=True)
   (root/"App").mkdir();(root/"App/source.swift").write_text("tracked")
   (root/"App/Info.plist").write_text("generated")
   subprocess.run(["git","-C",str(root),"add","."],check=True)
   subprocess.run(["git","-C",str(root),"-c","user.name=Test","-c","user.email=test@example.invalid","commit","-qm","fixture"],check=True)
   (root/"App/Info.plist").write_text("changed generated")
   self.assertRegex(m.source_state(root),r"^[0-9a-f]{40}$")
   (root/"App/untracked.swift").write_text("unreviewed")
   with self.assertRaisesRegex(m.GuardFailure,"dirty_source"):
    m.source_state(root)
   (root/"App/untracked.swift").unlink();(root/"App/source.swift").write_text("uncommitted")
   with self.assertRaisesRegex(m.GuardFailure,"dirty_source"):
    m.source_state(root)
 def test_test_paths_cannot_escape_products(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);target=root/"test.xctestrun"
   (root/"Runner.app").mkdir();(root/"Runner.app/Runner").touch()
   value={"TestConfigurations":[{"TestTargets":[{"BlueprintName":"GSDScreenshotTests",
    "TestBundlePath":"__TESTROOT__/../outside.xctest","TestHostPath":"__TESTROOT__/Runner.app/Runner",
    "UITargetAppPath":"__TESTROOT__/GSD.app"}]}]}
   target.write_bytes(plistlib.dumps(value))
   with self.assertRaisesRegex(m.GuardFailure,"test_path_outside_products"):
    m.verify_xctestrun(target,root)
 def test_observed_xcode_testhost_placeholder_resolves_inside_products(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp)
   runner=root/"Debug-iphonesimulator/GSDScreenshotTests-Runner.app"
   (runner/"PlugIns/GSDScreenshotTests.xctest").mkdir(parents=True)
   (root/"Debug-iphonesimulator/GSD.app").mkdir()
   target=root/"accepted.xctestrun"
   target.write_bytes(plistlib.dumps({"GSDScreenshotTests":{
    "TestHostPath":"__TESTROOT__/Debug-iphonesimulator/GSDScreenshotTests-Runner.app",
    "TestBundlePath":"__TESTHOST__/PlugIns/GSDScreenshotTests.xctest",
    "UITargetAppPath":"__TESTROOT__/Debug-iphonesimulator/GSD.app"},"__xctestrun_metadata__":{"FormatVersion":1}}))
   result=m.verify_xctestrun(target,root)
   self.assertEqual(result["TestBundlePath"],"Debug-iphonesimulator/GSDScreenshotTests-Runner.app/PlugIns/GSDScreenshotTests.xctest")
 def test_test_selection_requires_exact_nonzero_success(self):
  tests=["Example/testOne","Example/testTwo"]
  good={"totalTestCount":2,"passedTests":2,"failedTests":0,"skippedTests":0,"expectedFailures":0}
  log="Test Case '-[Bundle.Example testOne]' passed (0.1 seconds).\nTest Case '-[Bundle.Example testTwo]' passed (0.1 seconds).\n"
  self.assertEqual(m.exact_test_summary(good,log,tests)["passedTests"],2)
  for bad in [dict(good,totalTestCount=0),dict(good,skippedTests=1),dict(good,passedTests=1),dict(good,expectedFailures=1)]:
   with self.assertRaises(m.GuardFailure):m.exact_test_summary(bad,log,tests)
  with self.assertRaises(m.GuardFailure):m.exact_test_summary(good,log.replace("testTwo","wrongTest"),tests)
 def test_missing_share_assertion_never_passes(self):
  raw={"schemaVersion":1,"appSourceSHA":"a"*40,"simulatorID":"owned","language":"he","installedBundleIDs":["com.itorah.gsd"],
   "coverageComplete":False,"discoveryRecorded":True,"discoveryOnly":False,"surfaces":{
    "shareText":{"status":"passed","assertions":{k:True for k in m.SHARE_ASSERTIONS}},
    "shareWebURL":{"status":"incomplete"},"widgetKit":{"status":"incomplete"},"shortcuts":{"status":"incomplete"},
    "voiceOver":{"status":"unknown"},"accessibility":{"status":"passed","scope":"sufficientElementDescription on the actual visible Share compose host","voiceOverFocusOrSpeechVerified":False}}}
  m.verify_share(raw,"a"*40,"owned",["com.itorah.gsd"])
  raw["surfaces"]["shareText"]["assertions"]["cancelCreatedNone"]=False
  with self.assertRaises(m.GuardFailure):m.verify_share(raw,"a"*40,"owned",["com.itorah.gsd"])
 def preconsent(self):
  return {"schemaVersion":1,"appSourceSHA":"a"*40,"simulatorID":"owned","scope":"native_preconsent_start_and_cancel_only","language":"en",
   "probePassed":True,"pageContentClassification":"unclassified","outcome":"official_browser_opened_cancelled_and_disconnected",
   "observedAt":"2026-11-24T15:00:00Z","observedOfficialHost":"auth.openai.com","expectedAuthorizationOrigin":"https://auth.openai.com",
   "originEvidence":"visible_host_only","publicState":"official_browser_visible",
   **{k:False for k in m.CLAIMS_FALSE},**{k:True for k in m.STATES}}
 def test_preconsent_export_rejects_secret_or_unproved_claim(self):
  raw=self.preconsent();self.assertTrue(m.safe_observation(raw,"owned","a"*40)["probePassed"])
  for bad in [dict(raw,token="sensitive"),dict(raw,grantVerified=True),dict(raw,observedOrigin="https://auth.openai.com/path?secret=yes"),
              dict(raw,appSourceSHA="b"*40),dict(raw,probePassed=False,outcome="incomplete",pageContentClassification="not_observed",failure="private page prose")]:
   if "failure" in bad:self.assertNotIn("failure",m.safe_observation(bad,"owned","a"*40))
   else:
    with self.assertRaises(m.GuardFailure):m.safe_observation(bad,"owned","a"*40)
 def test_device_ownership_excludes_existing_devices(self):
  inventory={"devices":{m.IOS_RUNTIME:[{"udid":"a","name":"unique","state":"Shutdown"}]}}
  self.assertEqual(m.exact_owned_device(inventory,m.IOS_RUNTIME,"unique",set()),"a")
  with self.assertRaises(m.GuardFailure):m.exact_owned_device(inventory,m.IOS_RUNTIME,"unique",{"a"})
  inventory["devices"][m.IOS_RUNTIME].append({"udid":"b","name":"unique","state":"Shutdown"})
  with self.assertRaises(m.GuardFailure):m.exact_owned_device(inventory,m.IOS_RUNTIME,"unique",set())
 def test_exact_runtime_build_is_required(self):
  inventory={"runtimes":[{"identifier":m.IOS_RUNTIME,"version":"27.2","buildversion":"24B8117","isAvailable":True}]}
  self.assertEqual(m.required_runtime(inventory,m.IOS_RUNTIME,"27.2","24B8117")["version"],"27.2")
  with self.assertRaises(m.GuardFailure):m.required_runtime(inventory,m.IOS_RUNTIME,"27.2","wrong")
 def test_manifest_source_and_lock_are_bound(self):
  expected={"schemaVersion":1,"kind":"local-final-build-products","sourceSHA":"a"*40,"buildExitCode":0,
   "compiler":{"version":m.COMPILER_VERSION},"sdkLockSHA256":"b"*64,"projectSHA256":"c"*64,
   "buildForTestingCompleted":True}
  m.verify_identity(expected,"a"*40,"b"*64,"c"*64)
  for bad in [dict(expected,sourceSHA="d"*40),dict(expected,sdkLockSHA256="e"*64),
              dict(expected,buildExitCode=65),dict(expected,buildForTestingCompleted=False)]:
   with self.assertRaises(m.GuardFailure):m.verify_identity(bad,"a"*40,"b"*64,"c"*64)
if __name__=="__main__":unittest.main()
