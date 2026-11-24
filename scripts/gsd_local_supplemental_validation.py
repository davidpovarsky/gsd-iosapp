#!/usr/bin/env python3
"""Capture and validate final local GSD products, then run bounded supplemental probes."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
sys.dont_write_bytecode = True
import time
import uuid

from gsd_appstore_connect import TEAM, APP_GROUP
from gsd_simulator_smoke import devices_for_runtime
from verify_gsd_release_bundle import audit, BUNDLES

COMPILER_VERSION="Xcode 27.1\nBuild version 27A9275"
DRIVER_VERSION="Xcode 27.0\nBuild version 27A266a"
IOS_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-2"
WATCH_RUNTIME="com.apple.CoreSimulator.SimRuntime.watchOS-27-0"
PHONE="com.itorah.gsd"
WATCH=PHONE+".watchkitapp"
TESTS={
 "share":["GSDSystemSurfaceUITests/test00RecordSystemSurfaceDiscovery",
          "GSDSystemSurfaceUITests/test01TextShareExtensionRoundTripAndCancellation"],
 "preconsent":["GSDChatGPTPreConsentUITests/test00ContinueOpensOfficialBrowserAndCancels"]
}
TEST_FILES=["ScreenshotTests/GSDSystemSurfaceUITests.swift","ScreenshotTests/GSDChatGPTPreConsentUITests.swift"]
SHARE_ASSERTIONS={"sourceCreated","activitySheetOpened","extensionOpenedForAdd","addCreatedExactlyOne",
 "addedTaskPersisted","extensionOpenedForCancel","cancelCreatedNone","cancelNoneAfterRelaunch"}
CLAIMS_FALSE=("authorizationSucceeded","grantVerified","entitlementVerified","signInPageVerified",
 "inferenceInvokedByProbe","browserScreenshotsRequestedByProbe","fullHierarchyRequestedByProbe")
STATES=("continueActivated","officialBrowserObserved","ordinaryCancellationObserved","disconnectedAfterCancel",
 "retryContinueActivated","retryOpeningObserved","officialBrowserObservedOnRetry","ordinaryRetryCancellationObserved",
 "disconnectedAfterRetryCancel","disconnectedAfterRelaunch")
PUBLIC_STATES={"official_browser_visible","cancelled_before_browser_observation","secure_window_unavailable",
 "native_authorization_timed_out","native_sign_in_failed_unclassified"}
ERROR_MARKERS={"invalid_request","invalid_client","unauthorized_client","invalid_scope","unsupported_response_type",
 "access_denied","server_error","temporarily_unavailable","Something went wrong","Unable to sign in","An error occurred"}
PICTURES={"01-disconnected-before-start.png":"continueActivated","02-disconnected-after-cancel.png":"disconnectedAfterCancel",
 "03-disconnected-after-retry-cancel.png":"disconnectedAfterRetryCancel",
 "03-disconnected-after-relaunch.png":"disconnectedAfterRelaunch"}
STOP_REQUESTED=False

class GuardFailure(Exception):
 pass

def require(condition: bool,code: str)->None:
 if not condition:raise GuardFailure(code)

def sha(path: Path)->str:
 digest=hashlib.sha256()
 with path.open("rb") as stream:
  for block in iter(lambda:stream.read(1024*1024),b""):digest.update(block)
 return digest.hexdigest()

def tree_digest(directory: Path)->dict:
 require(directory.is_dir() and not directory.is_symlink(),"product_directory")
 rows=[]
 for path in sorted(directory.rglob("*")):
  require(not path.is_symlink(),"product_symlink")
  if path.is_file():rows.append((path.relative_to(directory).as_posix(),sha(path)))
 require(bool(rows),"empty_product_tree")
 return {"sha256":hashlib.sha256(json.dumps(rows,separators=(",",":"),ensure_ascii=True).encode()).hexdigest(),"files":len(rows)}

def verify_tree(directory: Path,expected: dict)->None:
 require(tree_digest(directory)==expected,"products_changed")

def git(repo: Path,*arguments: str)->bytes:
 result=subprocess.run(["git","-C",str(repo),*arguments],capture_output=True,timeout=30)
 require(result.returncode==0,"git_guard_failed")
 return result.stdout

def generated(path: str)->bool:
 return path=="App/Info.plist" or path.startswith("GSD.xcodeproj/")

def source_state(repo: Path)->str:
 head=git(repo,"rev-parse","HEAD").decode().strip()
 require(re.fullmatch(r"[0-9a-f]{40}",head) is not None,"source_sha")
 records=git(repo,"status","--porcelain=v1","-z","--untracked-files=all").decode().split("\0")
 index=0
 while index<len(records):
  record=records[index];index+=1
  if not record:continue
  require(generated(record[3:]),"dirty_source")
  if "R" in record[:2] or "C" in record[:2]:
   require(index<len(records) and generated(records[index]),"dirty_source")
   index+=1
 return head

def safe_environment(developer: Path)->dict:
 environment={key:os.environ[key] for key in ("PATH","HOME","TMPDIR","SHELL","LANG","LC_ALL","USER","LOGNAME") if key in os.environ}
 environment["DEVELOPER_DIR"]=str(developer.resolve())
 return environment

def probe_toolchain(developer: Path,expected: str)->dict:
 require(developer.is_dir(),"developer_directory")
 environment=safe_environment(developer)
 output=subprocess.run(["xcodebuild","-version"],env=environment,capture_output=True,text=True,timeout=30)
 require(output.returncode==0 and output.stdout.strip()==expected,"toolchain_version")
 resolved=subprocess.run(["xcrun","--find","xcodebuild"],env=environment,capture_output=True,text=True,timeout=30)
 require(resolved.returncode==0,"toolchain_resolution")
 executable=Path(resolved.stdout.strip()).resolve()
 require(executable.is_file() and executable.is_relative_to(developer.resolve()),"toolchain_path")
 return {"developerDir":str(developer.resolve()),"version":expected,"resolvedXcodebuild":str(executable)}

def verify_xctestrun(xctestrun: Path,products: Path)->dict:
 value=plistlib.loads(xctestrun.read_bytes())
 targets=[]
 if "TestConfigurations" in value:
  for configuration in value["TestConfigurations"]:targets.extend(configuration.get("TestTargets",[]))
 else:
  targets=[dict(item,BlueprintName=name) for name,item in value.items() if isinstance(item,dict)]
 matches=[item for item in targets if item.get("BlueprintName")== "GSDScreenshotTests"]
 require(len(matches)==1,"one_screenshot_test_target")
 paths={}
 host=None
 for key in ("TestHostPath","TestBundlePath","UITargetAppPath"):
  raw=matches[0].get(key)
  require(isinstance(raw,str) and bool(raw),"missing_test_path")
  expanded=raw.replace("__TESTROOT__",str(xctestrun.parent))
  if host is not None:expanded=expanded.replace("__TESTHOST__",str(host))
  require("__" not in expanded,"unknown_test_path_placeholder")
  resolved=Path(expanded).resolve()
  require(resolved.is_relative_to(products.resolve()),"test_path_outside_products")
  require(resolved.exists(),"missing_test_product")
  paths[key]=resolved.relative_to(products.resolve()).as_posix()
  if key=="TestHostPath":host=resolved
 require(paths["TestBundlePath"].endswith(".xctest"),"test_bundle_type")
 require(paths["UITargetAppPath"]=="Debug-iphonesimulator/GSD.app","test_target_identity")
 return paths

def simulator_entitlements(executable: Path, identifier: str) -> dict:
    # Same parser and identity checks used by the validated native workflow.
    data = executable.read_bytes()
    assert len(data) >= 32 and struct.unpack_from("<I", data)[0] == 0xfeedfacf
    assert struct.unpack_from("<I", data, 4)[0] == 0x0100000c
    count, size = struct.unpack_from("<II", data, 16)
    position, boundary = 32, 32 + size
    assert boundary <= len(data)
    matches = []
    for _ in range(count):
        assert position + 8 <= boundary
        command, length = struct.unpack_from("<II", data, position)
        assert length >= 8 and position + length <= boundary
        if command == 0x19:
            assert length >= 72
            sections = struct.unpack_from("<I", data, position + 64)[0]
            assert 72 + sections * 80 <= length
            for index in range(sections):
                section = position + 72 + index * 80
                name = data[section:section + 16].split(b"\0")[0]
                segment = data[section + 16:section + 32].split(b"\0")[0]
                if (segment, name) == (b"__TEXT", b"__entitlements"):
                    amount = struct.unpack_from("<Q", data, section + 40)[0]
                    offset = struct.unpack_from("<I", data, section + 48)[0]
                    assert offset + amount <= len(data)
                    matches.append(plistlib.loads(data[offset:offset + amount]))
        position += length
    assert len(matches) == 1
    entitlements = matches[0]
    assert entitlements.get("application-identifier") == TEAM + "." + identifier
    assert entitlements.get("com.apple.security.application-groups") == [APP_GROUP]
    return entitlements

def audit_local_products(products: Path,build: str,version: str)->dict:
 app=products/"Debug-iphonesimulator/GSD.app"
 resources=audit(app,build,version,False)
 targets={}
 for identifier,relative in BUNDLES.items():
  bundle=app/relative;info=plistlib.loads((bundle/"Info.plist").read_bytes())
  require(info.get("DTXcodeBuild")=="27A9275","product_compiler_identity")
  result=subprocess.run(["codesign","--verify","--strict",str(bundle)],capture_output=True,timeout=30)
  require(result.returncode==0,"product_signature")
  executable=bundle/info["CFBundleExecutable"]
  entitlements=simulator_entitlements(executable,identifier)
  targets[identifier]={"tree":tree_digest(bundle),"executableSHA256":sha(executable),"runtimeEntitlements":entitlements}
 verify=subprocess.run(["codesign","--verify","--deep","--strict",str(app)],capture_output=True,timeout=30)
 require(verify.returncode==0,"app_deep_signature")
 watch=products/"Debug-watchsimulator/GSDWatch.app"
 require(tree_digest(watch)==tree_digest(app/"Watch/GSDWatch.app"),"embedded_watch_identity")
 return {"resources":resources,"targets":targets}

def verify_identity(receipt: dict,source: str,sdk_hash: str,project_hash: str)->None:
 require(receipt.get("schemaVersion")==1 and receipt.get("kind")=="local-final-build-products","manifest_schema")
 require(receipt.get("sourceSHA")==source and re.fullmatch(r"[0-9a-f]{40}",source) is not None,"manifest_source")
 require(receipt.get("buildExitCode")==0 and receipt.get("buildForTestingCompleted") is True,"build_not_completed")
 require(receipt.get("compiler",{}).get("version")==COMPILER_VERSION,"manifest_compiler")
 require(receipt.get("sdkLockSHA256")==sdk_hash,"manifest_sdk_lock")
 require(receipt.get("projectSHA256")==project_hash,"manifest_generated_project")

def capture(args: argparse.Namespace)->int:
 require(__debug__,"python_optimized")
 repo=args.repo.resolve();products=args.products.resolve();output=args.output.resolve()
 require(not output.is_relative_to(products),"manifest_inside_products")
 source=source_state(repo)
 require(not os.environ.get("GSD_SOURCE_SHA") or os.environ["GSD_SOURCE_SHA"]==source,"source_environment_mismatch")
 require(args.build_exit_code==0 and args.build.isdigit(),"build_exit_or_number")
 log=args.build_log.resolve()
 require(log.is_file() and not log.is_symlink(),"build_log")
 text=log.read_text(errors="replace")
 require(text.count("** TEST BUILD SUCCEEDED **")==1 and "** TEST BUILD FAILED **" not in text,"build_log_terminal")
 compiler=probe_toolchain(args.compile_developer_dir,COMPILER_VERSION)
 candidates=list(products.glob("*.xctestrun"));require(len(candidates)==1,"one_xctestrun")
 paths=verify_xctestrun(candidates[0],products)
 audit_result=audit_local_products(products,args.build,args.version)
 receipt={"schemaVersion":1,"kind":"local-final-build-products","sourceSHA":source,"repoRoot":str(repo),
  "build":args.build,"version":args.version,"buildExitCode":args.build_exit_code,"buildForTestingCompleted":True,
  "compiler":compiler,"sdkLockSHA256":sha(repo/"HanlinSDK.lock.json"),"projectSHA256":sha(repo/"GSD.xcodeproj/project.pbxproj"),
  "buildLog":{"path":str(log),"sha256":sha(log)},"productsRoot":str(products),"productsTree":tree_digest(products),
  "xctestrun":{"relativePath":candidates[0].relative_to(products).as_posix(),"sha256":sha(candidates[0]),"targetPaths":paths},
  "testSources":{name:sha(repo/name) for name in TEST_FILES},"audit":audit_result,"capturedAt":datetime.now(timezone.utc).isoformat()}
 require(source_state(repo)==source,"source_changed_during_capture")
 output.parent.mkdir(parents=True,exist_ok=True)
 with output.open("x") as stream:json.dump(receipt,stream,indent=2);stream.write("\n")
 output.chmod(0o600)
 print("GSD_LOCAL_PRODUCTS_CAPTURED source="+source+" manifestSHA256="+sha(output),flush=True)
 return 0

def verify_manifest(receipt: dict,repo: Path,products: Path)->Path:
 source=source_state(repo)
 verify_identity(receipt,source,sha(repo/"HanlinSDK.lock.json"),sha(repo/"GSD.xcodeproj/project.pbxproj"))
 require(str(repo.resolve())==receipt["repoRoot"] and str(products.resolve())==receipt["productsRoot"],"manifest_location")
 require(sha(Path(receipt["buildLog"]["path"]))==receipt["buildLog"]["sha256"],"build_log_changed")
 require(receipt["testSources"]=={name:sha(repo/name) for name in TEST_FILES},"test_source_changed")
 verify_tree(products,receipt["productsTree"])
 xctestrun=products/receipt["xctestrun"]["relativePath"]
 require(xctestrun.resolve().is_relative_to(products.resolve()),"xctestrun_outside_products")
 require(sha(xctestrun)==receipt["xctestrun"]["sha256"],"xctestrun_changed")
 require(verify_xctestrun(xctestrun,products)==receipt["xctestrun"]["targetPaths"],"test_paths_changed")
 require(audit_local_products(products,receipt["build"],receipt["version"])==receipt["audit"],"bundle_audit_changed")
 return xctestrun

def exact_test_summary(raw: dict,log: str,selected: list[str])->dict:
 counts={key:raw.get(key,0) for key in ("totalTestCount","passedTests","failedTests","skippedTests","expectedFailures")}
 require(all(type(value) is int and value>=0 for value in counts.values()),"test_count_type")
 require(counts=={"totalTestCount":len(selected),"passedTests":len(selected),"failedTests":0,"skippedTests":0,"expectedFailures":0},"exact_test_counts")
 terminals=re.findall(r"(?im)^.*Test [Cc]ase.*\b(passed|failed|skipped)\b.*$",log)
 require(len(terminals)==len(selected),"exact_terminal_count")
 for selected_test in selected:
  classname,name=selected_test.split("/")
  matches=re.findall(r"(?im)^.*Test [Cc]ase.*\b"+re.escape(classname)+r"\b.*\b"+re.escape(name)+r"\b.*\b(passed|failed|skipped)\b.*$",log)
  require(matches==["passed"],"selected_test_not_passed")
 return {"selectedTests":selected,**counts}

def verify_share(raw: dict,source: str,device: str,identifiers: list[str])->None:
 require(raw.get("schemaVersion")==1 and raw.get("appSourceSHA")==source and raw.get("simulatorID")==device,"share_identity")
 require(raw.get("language")=="he" and raw.get("installedBundleIDs")==identifiers,"share_profile")
 require(raw.get("coverageComplete") is False and raw.get("discoveryRecorded") is True and raw.get("discoveryOnly") is False,"share_scope")
 surfaces=raw["surfaces"];require(set(surfaces)=={"shareText","shareWebURL","widgetKit","shortcuts","accessibility","voiceOver"},"share_surfaces")
 require(all(surfaces[name]["status"]!="passed" for name in ("shareWebURL","widgetKit","shortcuts","voiceOver")),"unproven_surface")
 require(surfaces["shareText"]["status"]=="passed" and set(surfaces["shareText"]["assertions"])==SHARE_ASSERTIONS,"share_assertion_keys")
 require(all(value is True for value in surfaces["shareText"]["assertions"].values()),"share_assertion_incomplete")
 accessibility=surfaces["accessibility"]
 require(accessibility.get("status")=="passed" and accessibility.get("scope")=="sufficientElementDescription on the actual visible Share compose host"
  and accessibility.get("voiceOverFocusOrSpeechVerified") is False,"share_accessibility")

def safe_observation(raw: dict, device: str, source: str) -> dict:
    required = {"schemaVersion", "appSourceSHA", "simulatorID", "scope", "language", "probePassed",
                "pageContentClassification", "outcome", "observedAt", *CLAIMS_FALSE, *STATES}
    optional = {"observedOfficialHost", "expectedAuthorizationOrigin", "originEvidence", "observedOrigin",
                "publicState", "publicErrorMarker", "systemPromptObserved", "systemPromptContinued",
                "systemPromptDomain", "browserObservationSummary", "failure"}
    require(isinstance(raw, dict) and required <= set(raw) <= required | optional, "observation_keys")
    require(type(raw["schemaVersion"]) is int and raw["schemaVersion"] == 1, "observation_schema")
    require((raw["appSourceSHA"], raw["simulatorID"], raw["scope"], raw["language"]) ==
            (source, device, "native_preconsent_start_and_cancel_only", "en"), "observation_identity")
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
        numbers = {"ownerState", "webViewCount", "nativeBrowserBarCount", "nativeBrowserBarsInspected"}
        booleans = {"exactCancelObserved", "uniqueHittableCancelObserved", "officialHostChromeObserved"}
        for item in owners.values():
            require(isinstance(item, dict) and set(item) == numbers | booleans, "browser_summary_keys")
            require(all(type(item[k]) is int and 0 <= item[k] <= 100000 for k in numbers), "browser_counts")
            require(item["ownerState"] <= 4 and item["nativeBrowserBarsInspected"] <= 1, "browser_bounds")
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

def required_runtime(inventory: dict,identifier: str,version: str,build: str)->dict:
 matches=[item for item in inventory["runtimes"] if item["identifier"]==identifier and item.get("isAvailable")]
 require(len(matches)==1 and matches[0]["version"]==version and matches[0]["buildversion"]==build,"runtime_identity")
 return matches[0]

def exact_owned_device(inventory: dict,runtime: str,name: str,before: set[str])->str:
 matches=[item["udid"] for item in inventory["devices"].get(runtime,[]) if item["name"]==name]
 require(len(matches)==1 and matches[0] not in before,"owned_device_identity")
 return matches[0]

def private_command(arguments: list[str],log: Path,environment: dict,timeout: int=120,check: bool=True,cleanup: bool=False)->tuple[int,str]:
 require(cleanup or not STOP_REQUESTED,"interrupted")
 with log.open("xb") as stream:
  process=subprocess.Popen(arguments,stdout=stream,stderr=subprocess.STDOUT,env=environment,start_new_session=True)
  deadline=time.monotonic()+timeout
  try:
   while process.poll() is None:
    require(cleanup or not STOP_REQUESTED,"interrupted")
    require(time.monotonic()<deadline,"command_timeout")
    try:process.wait(timeout=1)
    except subprocess.TimeoutExpired:pass
  finally:
   if process.poll() is None:
    try:os.killpg(process.pid,signal.SIGTERM)
    except ProcessLookupError:pass
    try:process.wait(timeout=15)
    except subprocess.TimeoutExpired:
     os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=10)
 text=log.read_text(errors="replace")
 require(not check or process.returncode==0,"command_failed_"+str(process.returncode))
 return process.returncode,text

class OwnedDevices:
 def __init__(self,private: Path,environment: dict):
  self.private=private;self.environment=environment;self.counter=0;self.devices={};self.pairs=[]
  self.before=self.inventory()
  self.before_ids={d["udid"] for group in self.before["devices"].values() for d in group}
  self.save()
 def save(self)->None:
  (self.private/"owned-devices.json").write_text(json.dumps({"beforeIDs":sorted(self.before_ids),"devices":self.devices,"pairs":self.pairs},indent=2))
 def run(self,arguments: list[str],timeout: int=120,check: bool=True,environment: dict|None=None,cleanup: bool=False)->tuple[int,str]:
  self.counter+=1
  return private_command(arguments,self.private/("command-"+str(self.counter)+".log"),environment or self.environment,timeout,check,cleanup)
 def inventory(self,cleanup: bool=False)->dict:
  return json.loads(self.run(["xcrun","simctl","list","--json"],cleanup=cleanup)[1])
 def create(self,runtime: dict,device_type: dict,role: str,language: str)->str:
  name="GSD-Supplemental-"+role+"-"+uuid.uuid4().hex
  try:code,_=self.run(["xcrun","simctl","create",name,device_type["identifier"],runtime["identifier"]],check=False)
  finally:
   inventory=self.inventory(cleanup=True);device=exact_owned_device(inventory,runtime["identifier"],name,self.before_ids)
   self.devices[device]={"name":name,"runtime":runtime["identifier"],"deviceType":device_type["identifier"],"role":role}
   self.save()
  require(code==0,"device_creation_failed")
  details=[d for group in inventory["devices"].values() for d in group if d["udid"]==device]
  require(len(details)==1 and details[0]["state"]=="Shutdown","fresh_device_state")
  data=Path(details[0]["dataPath"]).resolve()
  require(data.name=="data" and data.parent.name.upper()==device.upper(),"owned_data_directory")
  preference=data/"Library/Preferences/.GlobalPreferences.plist"
  values=plistlib.loads(preference.read_bytes()) if preference.exists() else {}
  values.update(AppleLanguages=[language],AppleLocale="he_IL" if language=="he" else "en_US")
  preference.parent.mkdir(parents=True,exist_ok=True);preference.write_bytes(plistlib.dumps(values))
  return device
 def boot_install(self,device: str,app: Path,language: str)->None:
  require(device in self.devices and device not in self.before_ids,"unowned_device")
  self.run(["xcrun","simctl","boot",device])
  self.run(["xcrun","simctl","bootstatus",device,"-b"],timeout=300)
  locale=self.run(["xcrun","simctl","spawn",device,"defaults","read","-g","AppleLocale"])[1].strip()
  languages=self.run(["xcrun","simctl","spawn",device,"defaults","read","-g","AppleLanguages"])[1]
  require(locale==("he_IL" if language=="he" else "en_US") and re.search(r"\b"+language+r"\b",languages),"locale_readback")
  self.run(["xcrun","simctl","install",device,str(app)],timeout=300)
  identifier=plistlib.loads((app/"Info.plist").read_bytes())["CFBundleIdentifier"]
  installed=self.run(["xcrun","simctl","get_app_container",device,identifier,"app"])[1].strip()
  require(tree_digest(Path(installed))==tree_digest(app),"installed_product_identity")
 def identifiers(self,device: str)->list[str]:
  _,text=self.run(["xcrun","simctl","listapps",device]);path=self.private/("apps-"+device+".plist");path.write_text(text)
  _,raw=self.run(["plutil","-convert","json","-o","-",str(path)])
  names=sorted(json.loads(raw));require(PHONE in names,"app_inventory")
  return names
 def cleanup(self)->None:
  errors=[]
  for pair in reversed(self.pairs):
   try:self.run(["xcrun","simctl","unpair",pair],check=False,cleanup=True)
   except Exception:errors.append("unpair_failed")
  for device,details in reversed(list(self.devices.items())):
   require(device not in self.before_ids,"cleanup_preexisting_device")
   if details.get("removed"):continue
   try:
    self.run(["xcrun","simctl","shutdown",device],check=False,cleanup=True)
    self.run(["xcrun","simctl","delete",device],cleanup=True)
   except Exception:errors.append("delete_failed")
  remaining={d["udid"] for group in self.inventory(cleanup=True)["devices"].values() for d in group}
  for device,details in self.devices.items():details["removed"]=device not in remaining
  self.save()
  require(not remaining.intersection(self.devices) and not errors,"owned_device_cleanup_incomplete")
  self.pairs=[];self.save()

def png(path: Path)->dict:
 require(path.is_file() and not path.is_symlink(),"picture_path")
 data=path.read_bytes()
 require(24<=len(data)<=25_000_000 and data[:8]==b"\x89PNG\r\n\x1a\n" and data[12:16]==b"IHDR","picture_format")
 width,height=struct.unpack_from(">II",data,16);require(width>0 and height>0,"picture_dimensions")
 return {"sha256":sha(path),"bytes":len(data),"pixelWidth":width,"pixelHeight":height}

def capture_failure_runtime_diagnostics(manager: OwnedDevices,device: str,kind: str)->None:
 predicate='(process == "GSD" OR process == "GSDShareExtension") AND (eventMessage CONTAINS[c] "UIActivityViewController" OR eventMessage CONTAINS[c] "Attempt to present" OR eventMessage CONTAINS[c] "not in the window hierarchy" OR eventMessage CONTAINS[c] "ASWebAuthenticationSessionErrorDomain")'
 diagnostic={"scope":"owned_simulator_presentation_errors","device":device,"kind":kind}
 try:
  result=subprocess.run(["xcrun","simctl","spawn",device,"log","show","--style","compact","--last","5m","--predicate",predicate],
   env=manager.environment,capture_output=True,text=True,timeout=20)
  text=result.stdout+"\n"+result.stderr
  text=re.sub(r"https?://[^\s\"'<>]+","[redacted-url]",text)
  text=re.sub(r"(?i)(access_token|refresh_token|id_token|code_verifier|authorization|cookie|state)\s*[:=]\s*[^\s,;]+",r"\1=[redacted]",text)
  diagnostic.update(returncode=result.returncode,lines=[line[:1200] for line in text.splitlines()[-80:]])
 except Exception as error:diagnostic["captureFailure"]=type(error).__name__
 (manager.private/(kind+"-runtime-diagnostics.json")).write_text(json.dumps(diagnostic,indent=2))

def run_ui(kind: str,manager: OwnedDevices,receipt: dict,products: Path,xctestrun: Path,public: Path)->dict:
 language="he" if kind=="share" else "en"
 runtime=required_runtime(manager.inventory(),IOS_RUNTIME,"27.2","24B8117")
 selected=devices_for_runtime(manager.before,runtime).get("iPhone");require(selected is not None,"phone_type")
 device=manager.create(runtime,selected,kind,language)
 manager.boot_install(device,products/"Debug-iphonesimulator/GSD.app",language)
 identifiers=manager.identifiers(device)
 ui=manager.private/(kind+"-ui");ui.mkdir(mode=0o700)
 environment=dict(manager.environment);environment["TEST_RUNNER_GSD_TEST_LANGUAGE"]=language
 prefix="TEST_RUNNER_GSD_SYSTEM_SURFACE_" if kind=="share" else "TEST_RUNNER_GSD_SIWC_PRECONSENT_"
 environment.update({prefix+"ARTIFACTS":str(ui),prefix+"SIMULATOR_UDID":device,prefix+"FRESH_SIMULATOR":"1",prefix+"APP_SOURCE":receipt["sourceSHA"]})
 if kind=="share":environment["TEST_RUNNER_GSD_SYSTEM_INSTALLED_BUNDLE_IDS"]=json.dumps(identifiers)
 result=manager.private/(kind+".xcresult")
 command=["xcodebuild","test-without-building","-xctestrun",str(xctestrun),"-destination","platform=iOS Simulator,id="+device,
  "-destination-timeout","90","-parallel-testing-enabled","NO","-collect-test-diagnostics","never","-resultBundlePath",str(result),"-testLanguage",language,"-testRegion","IL" if language=="he" else "US"]
 command.extend("-only-testing:GSDScreenshotTests/"+name for name in TESTS[kind])
 # The real Add/Cancel workflow can incur 60s XCTest animation-idle waits per action.
 # Its 2026-11-24 first Add flow took 906s. Cover both flows plus full Matrix traversals;
 # this outer wall budget leaves every individual UI/readiness/assertion deadline unchanged.
 code,log=manager.run(command,timeout=3600 if kind=="share" else 600,check=False,environment=environment)
 if code!=0:capture_failure_runtime_diagnostics(manager,device,kind)
 observation_path=ui/("system-surface-observations.json" if kind=="share" else "siwc-preconsent-observation.json")
 observation=json.loads(observation_path.read_text())
 if kind=="preconsent":
  observation=safe_observation(observation,device,receipt["sourceSHA"])
  (public/"siwc-preconsent-observation.json").write_text(json.dumps(observation,indent=2))
  for name,state in PICTURES.items():
   if observation[state] is True and (ui/name).exists():
    png(ui/name);shutil.copy2(ui/name,public/name)
 else:verify_share(observation,receipt["sourceSHA"],device,identifiers)
 _,raw=manager.run(["xcrun","xcresulttool","get","test-results","summary","--path",str(result)])
 summary=exact_test_summary(json.loads(raw),log,TESTS[kind])
 require(code==0,"xctest_exit")
 if kind=="preconsent":require(observation["probePassed"] is True,"preconsent_incomplete")
 return {"passed":True,"simulatorID":device,"runtime":IOS_RUNTIME,"runtimeBuild":"24B8117","test":summary,
  "scope":"real_text_share_add_cancel_and_persistence" if kind=="share" else "native_preconsent_start_and_cancel_only",
  "fullSystemSurfaceCoverage":False,"accountGrantVerified":False}

def run_watch(manager: OwnedDevices,products: Path,public: Path)->dict:
 inventory=manager.inventory();phone_runtime=required_runtime(inventory,IOS_RUNTIME,"27.2","24B8117")
 watch_runtime=required_runtime(inventory,WATCH_RUNTIME,"27.0","24R362")
 phone_type=devices_for_runtime(inventory,phone_runtime).get("iPhone");require(phone_type is not None,"phone_type")
 supported={item["identifier"] if isinstance(item,dict) else item for item in watch_runtime.get("supportedDeviceTypes",[])}
 types=[item for item in inventory["devicetypes"] if item.get("productFamily")=="Apple Watch" and item["identifier"] in supported]
 require(bool(types),"watch_type")
 phone=manager.create(phone_runtime,phone_type,"watch-phone","en")
 watch=manager.create(watch_runtime,types[0],"watch","en")
 manager.run(["xcrun","simctl","pair",watch,phone])
 _,raw=manager.run(["xcrun","simctl","list","pairs","--json"])
 matches=[key for key,item in json.loads(raw)["pairs"].items() if item["watch"]["udid"]==watch and item["phone"]["udid"]==phone]
 require(len(matches)==1,"owned_pair_readback");manager.pairs.append(matches[0]);manager.save()
 apps={"phone":products/"Debug-iphonesimulator/GSD.app","watch":products/"Debug-watchsimulator/GSDWatch.app"}
 manager.boot_install(phone,apps["phone"],"en");manager.boot_install(watch,apps["watch"],"en")
 observations=[]
 for language,locale in (("en","en_US"),("he","he_IL")):
  for family,device,identifier in (("phone",phone,PHONE),("watch",watch,WATCH)):
   _,launch=manager.run(["xcrun","simctl","launch","--terminate-running-process",device,identifier,"-AppleLanguages","("+language+")","-AppleLocale",locale])
   match=re.search(r"(?m)^"+re.escape(identifier)+r":\s*(\d+)\s*$",launch);require(match is not None,"watch_launch_pid")
   if family=="watch":pid=match[1]
  time.sleep(5)
  _,raw=manager.run(["ps","-p",pid,"-o","pid=,comm="])
  process=raw.strip().split(maxsplit=1);info=plistlib.loads((apps["watch"]/"Info.plist").read_bytes())
  require(len(process)==2 and process[0]==pid and Path(process[1]).name==info["CFBundleExecutable"],"watch_liveness")
  picture=manager.private/("watch-"+language+".png")
  manager.run(["xcrun","simctl","io",watch,"screenshot","--type=png",str(picture)])
  image=png(picture);shutil.copy2(picture,public/picture.name)
  observations.append({"language":language,"locale":locale,"processID":int(pid),"aliveAfterSeconds":5,
   "picture":picture.name,**image,"visualReview":"pending"})
 return {"passed":len(observations)==2,"phoneID":phone,"watchID":watch,"pairID":matches[0],"watchRuntimeBuild":"24R362",
  "languages":observations,"scope":"watch_process_launch_liveness_and_raw_screenshots","watchConnectivityVerified":False}

def request_stop(_number: int,_frame: object)->None:
 global STOP_REQUESTED
 STOP_REQUESTED=True

def run_local(args: argparse.Namespace)->int:
 require(__debug__,"python_optimized")
 repo=args.repo.resolve();manifest=args.manifest.resolve();receipt=json.loads(manifest.read_text())
 products=Path(receipt["productsRoot"]);xctestrun=verify_manifest(receipt,repo,products)
 compiler=probe_toolchain(args.compile_developer_dir,COMPILER_VERSION)
 require(compiler==receipt["compiler"],"capture_compiler_changed")
 driver=probe_toolchain(args.driver_developer_dir,DRIVER_VERSION)
 output=args.output.resolve();output.mkdir(parents=True,exist_ok=False,mode=0o700)
 private=output/"private";private.mkdir(mode=0o700);public=output/"public";public.mkdir(mode=0o700)
 report={"schemaVersion":1,"sourceSHA":receipt["sourceSHA"],"manifestSHA256":sha(manifest),"build":receipt["build"],
  "compiler":compiler["version"],"driver":driver["version"],"passed":False,"accountGrantVerified":False,"fullSystemSurfaceCoverage":False,"suites":{}}
 manager=None;handlers={number:signal.signal(number,request_stop) for number in (signal.SIGINT,signal.SIGTERM)}
 try:
  manager=OwnedDevices(private,safe_environment(args.driver_developer_dir))
  for kind in args.suite:
   try:
    require(not STOP_REQUESTED,"interrupted");verify_tree(products,receipt["productsTree"])
    report["suites"][kind]=run_watch(manager,products,public) if kind=="watch" else run_ui(kind,manager,receipt,products,xctestrun,public)
   except Exception as error:
    report["suites"][kind]={"passed":False,"failureCode":str(error) if isinstance(error,GuardFailure) else "private_"+type(error).__name__}
   finally:
    try:manager.cleanup();report["suites"].setdefault(kind,{"passed":False})["ownedDevicesRemoved"]=True
    except Exception:
     report["suites"].setdefault(kind,{})["passed"]=False
     report["suites"][kind]["ownedDevicesRemoved"]=False
   (public/"supplemental-summary.json").write_text(json.dumps(report,indent=2))
 finally:
  try:verify_tree(products,receipt["productsTree"]);report["productsUnchanged"]=True
  except Exception:report["productsUnchanged"]=False
  if manager is not None:
   try:manager.cleanup();report["ownedSimulatorsRemoved"]=True
   except Exception as error:
    report["ownedSimulatorsRemoved"]=False;report["cleanupFailure"]=str(error) if isinstance(error,GuardFailure) else "private_"+type(error).__name__
  else:report["ownedSimulatorsRemoved"]=False
  report["passed"]=set(report["suites"])==set(args.suite) and all(item["passed"] for item in report["suites"].values()) and report["productsUnchanged"] and report["ownedSimulatorsRemoved"] and not STOP_REQUESTED
  report["completedAt"]=datetime.now(timezone.utc).isoformat()
  (public/"supplemental-summary.json").write_text(json.dumps(report,indent=2))
  for number,handler in handlers.items():signal.signal(number,handler)
 print("GSD_LOCAL_SUPPLEMENTAL_"+("PASSED" if report["passed"] else "INCOMPLETE"),flush=True)
 return 0 if report["passed"] else 1

def main()->int:
 parser=argparse.ArgumentParser(description=__doc__)
 modes=parser.add_subparsers(dest="mode",required=True)
 capture_parser=modes.add_parser("capture")
 capture_parser.add_argument("--repo",type=Path,required=True)
 capture_parser.add_argument("--products",type=Path,required=True)
 capture_parser.add_argument("--build-log",type=Path,required=True)
 capture_parser.add_argument("--build-exit-code",type=int,required=True)
 capture_parser.add_argument("--build",required=True)
 capture_parser.add_argument("--version",default="4.1.0")
 capture_parser.add_argument("--compile-developer-dir",type=Path,required=True)
 capture_parser.add_argument("--output",type=Path,required=True)
 local=modes.add_parser("run",description="Use only captured local products; no GitHub access or rebuild.")
 local.add_argument("--repo",type=Path,required=True)
 local.add_argument("--manifest",type=Path,required=True)
 local.add_argument("--compile-developer-dir",type=Path,required=True)
 local.add_argument("--driver-developer-dir",type=Path,required=True)
 local.add_argument("--output",type=Path,required=True)
 local.add_argument("--suite",choices=["share","preconsent","watch"],action="append")
 args=parser.parse_args()
 if args.mode=="run":
  args.suite=args.suite or ["share","preconsent","watch"]
  require(len(args.suite)==len(set(args.suite)),"duplicate_suite")
 try:return capture(args) if args.mode=="capture" else run_local(args)
 except Exception as error:
  print("GSD_LOCAL_SUPPLEMENTAL_BLOCKED "+(str(error) if isinstance(error,GuardFailure) else type(error).__name__),flush=True)
  return 1

if __name__=="__main__":raise SystemExit(main())
