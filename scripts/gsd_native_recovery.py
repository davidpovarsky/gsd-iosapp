#!/usr/bin/env python3
"""Reuse one pinned native build only after source and artifact integrity checks."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import uuid
import zipfile
import zlib

REPOSITORY = "davidpovarsky/gsd-iosapp"
REPOSITORY_ID = 1467886923
SOURCE_RUN = 45113033128
SOURCE_ATTEMPT = 1
SOURCE_SHA = "d44649ed9bb0cc0eab9fb0d12c9ec63a71cd41ca"
WORKFLOW = ".github/workflows/gsd-hanlin-agent-ios.yml"
FAILED_STEP = "Launch and capture disposable iPhone and iPad simulators"
REQUIRED_STEPS = (
    "Verify Xcode 27 required by HanlinAgentSDK",
    "Regenerate the Xcode project from its source",
    "Preserve the generated project and plists",
    "Test GSD OAuth PKCE and MCP bridge locally",
    "Test GSD Hanlin tools, schema and remote write consent",
    "Preserve SDK test log before native app build",
    "Build native iPad app and both unsigned IPA variants",
    "Upload verified GSD iPad IPA assets",
    "Build the universal iPhone and iPad simulator app",
    "Archive the compiled simulator app before launch",
    "Preserve the compiled simulator app for diagnostics",
)
ALLOWED_CHANGES = frozenset((
    WORKFLOW,
    "scripts/gsd_simulator_smoke.py",
    "scripts/gsd_native_recovery.py",
    "scripts/test_gsd_native_recovery.py",
    "docs/ai-agent/GSD_BUILD_REPAIR_20261123.md",
    "docs/ai-agent/GSD_REMOTE_MCP_HANDOFF_20261123.md",
    "docs/ai-agent/HANLIN_GSD_INTEGRATION.md",
    "tasks/todo.md",
))
GENERATED_FILES = frozenset((
    "GSD.xcodeproj/project.pbxproj",
    "GSD.xcodeproj/xcshareddata/xcschemes/GSD.xcscheme",
    "GSD.xcodeproj/xcshareddata/xcschemes/GSDScreenshots.xcscheme",
    "GSD.xcodeproj/xcshareddata/xcschemes/GSDWatch.xcscheme",
    "App/Info.plist", "Widgets/Info.plist", "ShareExtension/Info.plist",
    "Watch/Info.plist", "WatchWidgets/Info.plist",
))
ARTIFACTS = {
    "simulator": {
        "id": 14791328061, "size": 28239815,
        "name": f"GSD-Hanlin-Simulator-App-{SOURCE_RUN}",
        "digest": "sha256:73513cc65e6d685e677b78ef4807584e5d306380acc9b7c5ecdf583e4ead4a10",
    },
    "generated": {
        "id": 14791321410, "size": 25240,
        "name": f"GSD-Hanlin-Generated-Project-{SOURCE_RUN}",
        "digest": "sha256:bfeb763cf5afbac79674e70e6e5a87e3e8837c71dbf04e80e8daee83f160f765",
    },
    "ipa": {
        "id": 14791222839, "size": 52282908,
        "name": f"GSD-Hanlin-ChatGPT-MCP-iPad-UNSIGNED-{SOURCE_RUN}",
        "digest": "sha256:dbd1d7897ae46daee2965433a628001a4f88373293d611b152ee34a6826e41eb",
    },
}
ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def save_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def command(args: list[str], timeout: int = 120) -> bytes:
    result = subprocess.run(args, cwd=ROOT, stdin=subprocess.DEVNULL,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}: "
                           + result.stderr.decode("utf-8", errors="replace")[-2000:])
    return result.stdout


def api(endpoint: str) -> dict:
    # gh owns authentication and redirects; credentials never enter Python arguments.
    value = json.loads(command(["gh", "api", "--method", "GET", endpoint]))
    require(isinstance(value, dict), "Unexpected GitHub API response")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_source(run: dict, jobs_response: dict) -> dict:
    require(run["id"] == SOURCE_RUN and run["run_attempt"] == SOURCE_ATTEMPT,
            "Source run or attempt differs from the pinned build")
    require(run["repository"]["id"] == REPOSITORY_ID
            and run["head_repository"]["id"] == REPOSITORY_ID
            and run["repository"]["full_name"] == REPOSITORY,
            "Source repository identity mismatch")
    require(run["head_sha"] == SOURCE_SHA
            and run["head_branch"] == "feat/hanlin-agent-api-20261122",
            "Source code identity mismatch")
    require(run["path"] == WORKFLOW and run["status"] == "completed"
            and run["conclusion"] == "failure", "Unexpected source workflow outcome")
    jobs = jobs_response["jobs"]
    require(len(jobs) == 1 and jobs[0]["name"] == "native-acceptance",
            "Source attempt must contain the expected native job")
    job = jobs[0]
    require(job["status"] == "completed" and job["conclusion"] == "failure",
            "Source native job is not the recorded failed attempt")
    steps = {step["name"]: step for step in job["steps"]}
    require(len(steps) == len(job["steps"]), "Duplicate source step names")
    for name in REQUIRED_STEPS:
        require(name in steps and steps[name]["status"] == "completed"
                and steps[name]["conclusion"] == "success",
                f"Native prerequisite was not successful: {name}")
    failures = [step["name"] for step in job["steps"]
                if step["conclusion"] not in ("success", "skipped")]
    require(failures == [FAILED_STEP]
            and steps[FAILED_STEP]["conclusion"] == "failure",
            "The source has a failure outside simulator smoke")
    return {"runID": SOURCE_RUN, "runAttempt": SOURCE_ATTEMPT,
            "headSHA": SOURCE_SHA, "conclusion": "failure",
            "url": run["html_url"], "jobID": job["id"],
            "soleFailedStep": FAILED_STEP,
            "reusedSuccessfulSteps": list(REQUIRED_STEPS)}


def git_tree(revision: str) -> dict[str, str]:
    entries = command(["git", "ls-tree", "-r", "-z", "--full-tree", revision])
    return {name.decode("utf-8"): record.decode("ascii")
            for entry in entries.split(b"\0") if entry
            for record, name in [entry.split(b"\t", 1)]}


def validate_trees(source: dict[str, str], current: dict[str, str]) -> dict:
    changed = sorted(path for path in source.keys() | current.keys()
                     if source.get(path) != current.get(path))
    forbidden = [path for path in changed if path not in ALLOWED_CHANGES]
    require(not forbidden, f"Compiled inputs changed; rebuild required: {forbidden}")
    protected = {path: entry for path, entry in source.items()
                 if path not in ALLOWED_CHANGES}
    fingerprint = hashlib.sha256(json.dumps(
        protected, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()
    return {"protectedTreeIdentical": True, "protectedTreeSHA256": fingerprint,
            "allowedChangedPaths": changed}


def validate_artifact(metadata: dict, expected: dict) -> None:
    require(metadata["id"] == expected["id"] and metadata["name"] == expected["name"],
            "Artifact identity mismatch")
    require(metadata["digest"] == expected["digest"]
            and metadata["size_in_bytes"] == expected["size"]
            and metadata["expired"] is False, "Artifact digest, size or expiry mismatch")
    run = metadata["workflow_run"]
    require(run["id"] == SOURCE_RUN and run["head_sha"] == SOURCE_SHA
            and run["repository_id"] == REPOSITORY_ID
            and run["head_repository_id"] == REPOSITORY_ID,
            "Artifact belongs to another source run or repository")


def verify_download(path: Path, metadata: dict) -> None:
    require(path.stat().st_size == metadata["size_in_bytes"], "Downloaded size mismatch")
    require("sha256:" + sha256(path) == metadata["digest"],
            "Downloaded artifact digest mismatch")


def archive_files(archive: zipfile.ZipFile) -> dict[str, zipfile.ZipInfo]:
    result = {}
    for info in archive.infolist():
        name = PurePosixPath(info.filename)
        require(not name.is_absolute() and ".." not in name.parts
                and "\\" not in info.filename, "Unsafe archive path")
        if not info.is_dir():
            require(info.filename not in result, "Duplicate archive path")
            result[info.filename] = info
    return result


def verify_generated(path: Path, checkout: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        files = archive_files(archive)
        require(set(files) == GENERATED_FILES, "Generated project file set differs")
        hashes = {}
        for name in sorted(files):
            content = archive.read(files[name])
            require(content == (checkout / name).read_bytes(),
                    f"Actual generated build input differs: {name}")
            hashes[name] = hashlib.sha256(content).hexdigest()
    return {"generatedProjectIdentical": True, "files": hashes}


def app_tree_sha256(app: Path) -> str:
    entries = []
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            require(path.resolve().is_relative_to(app.resolve()), "App symlink escapes bundle")
            entries.append((relative, "link", os.readlink(path)))
        elif path.is_file():
            entries.append((relative, "file", sha256(path)))
    return hashlib.sha256(json.dumps(entries, separators=(",", ":")).encode()).hexdigest()


def inspect_app(app: Path) -> dict:
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info["CFBundleIdentifier"] == "dev.vinny.gsd"
            and info["CFBundleExecutable"] == "GSD"
            and info["CFBundleShortVersionString"] == "4.0.1"
            and str(info["CFBundleVersion"]) == "47", "Unexpected compiled app identity")
    require(info["DTPlatformName"] == "iphonesimulator"
            and info["CFBundleSupportedPlatforms"] == ["iPhoneSimulator"],
            "Artifact is not an iOS Simulator app")
    require(tuple(int(x) for x in info["MinimumOSVersion"].split(".")) in
            ((27, 0), (27, 0, 0)), "Unexpected deployment minimum")
    require(set(info["UIDeviceFamily"]) == {1, 2}, "App does not support both device families")
    binary = app / info["CFBundleExecutable"]
    architectures = command(["xcrun", "lipo", "-archs", str(binary)]).decode().split()
    require(architectures == ["arm64"], "Simulator binary is not the expected ARM64 build")
    return {"path": str(app), "bundleID": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"], "build": str(info["CFBundleVersion"]),
            "minimumOSVersion": info["MinimumOSVersion"], "platform": info["DTPlatformName"],
            "architectures": architectures, "executableSHA256": sha256(binary),
            "infoPlistSHA256": sha256(app / "Info.plist"), "treeSHA256": app_tree_sha256(app)}


def png_evidence(path: Path) -> dict:
    content = path.read_bytes()
    require(content[:8] == b"\x89PNG\r\n\x1a\n", "Screenshot is not a PNG")
    offset, width, height, image_data, ended = 8, 0, 0, False, False
    while offset < len(content):
        require(offset + 12 <= len(content), "Truncated PNG chunk")
        length = struct.unpack(">I", content[offset:offset + 4])[0]
        kind = content[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(content), "Truncated PNG payload")
        data = content[offset + 8:offset + 8 + length]
        checksum = struct.unpack(">I", content[end - 4:end])[0]
        require(zlib.crc32(kind + data) & 0xffffffff == checksum, "PNG CRC mismatch")
        if offset == 8:
            require(kind == b"IHDR" and length == 13, "Missing PNG header")
            width, height = struct.unpack(">II", data[:8])
        if kind == b"IDAT":
            image_data = True
        if kind == b"IEND":
            require(length == 0 and end == len(content), "Invalid PNG ending")
            ended = True
        offset = end
    require(width > 0 and height > 0 and image_data and ended, "Incomplete PNG screenshot")
    return {"file": path.name, "width": width, "height": height,
            "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()}


def validate_smoke(report: dict, directory: Path, app: Path) -> list[dict]:
    require(report["status"] == "passed"
            and report["launchMode"] == "normal (no demo arguments)"
            and report["bundleID"] == "dev.vinny.gsd"
            and Path(report["app"]).resolve() == app.resolve(),
            "Smoke report is not successful normal execution of the verified app")
    devices = report["devices"]
    require(len(devices) == 2 and {d["family"] for d in devices} == {"iPhone", "iPad"},
            "Both distinct device families must pass")
    require(len({device["deviceID"] for device in devices}) == 2,
            "Device families must use distinct simulator UUIDs")
    screenshots = []
    for device in devices:
        require(device["status"] == "passed" and device["stage"] == "complete"
                and isinstance(device["processID"], int) and device["processID"] > 0
                and device["aliveAfterSeconds"] >= 5, "Device launch/liveness did not pass")
        uuid.UUID(device["deviceID"])
        require(device["deviceType"].startswith(
            "com.apple.CoreSimulator.SimDeviceType." + device["family"] + "-"),
            "Device type does not match its claimed family")
        require(device["screenshot"] == device["family"].lower() + ".png",
                "Each device needs its own screenshot")
        require(re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-27(?:-\d+)*",
                             device["runtime"]) is not None, "Unexpected simulator runtime")
        attempts = device["bootAttempts"]
        require(1 <= len(attempts) <= 2 and attempts[-1]["status"] == "passed"
                and all(a["status"] == "timed_out" for a in attempts[:-1]),
                "Unexpected boot recovery sequence")
        install = device["installation"]
        require(install["attempts"] == 1 and install["status"] == "passed"
                and install["exitCode"] == 0 and install["timeoutSeconds"] == 300,
                "Installation must pass exactly once without app retries")
        screenshot = directory / device["screenshot"]
        require(screenshot.resolve().is_relative_to(directory.resolve()),
                "Screenshot escapes evidence directory")
        screenshots.append({"family": device["family"], **png_evidence(screenshot)})
    return screenshots


def execution_identity() -> dict:
    head = command(["git", "rev-parse", "HEAD"]).decode().strip()
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_SHA") == head, "Recovery checkout identity mismatch")
    run_id = os.environ.get("GITHUB_RUN_ID", "")
    require(run_id.isdigit() and int(run_id) != SOURCE_RUN, "Missing new recovery run identity")
    require(not command(["git", "status", "--porcelain", "--untracked-files=no"]).strip(),
            "Tracked recovery files differ from their commit")
    return {"runID": int(run_id), "harnessSHA": head,
            "url": f"https://github.com/{REPOSITORY}/actions/runs/{run_id}"}


def prepare(args: argparse.Namespace) -> None:
    require(args.source_run == str(SOURCE_RUN) and args.expected_source_sha == SOURCE_SHA,
            "Only the pinned source run and SHA may be reused")
    identity = execution_identity()
    cache = args.cache.resolve()
    require(not cache.exists(), "Recovery cache must be a fresh directory")
    require(not cache.is_relative_to(args.output.resolve()), "Binaries cannot be evidence artifacts")
    cache.mkdir(parents=True)
    xcode = command(["xcodebuild", "-version"]).decode()
    require(re.search(r"(?m)^Xcode 27(?:\.|$)", xcode) is not None, "Xcode 27 is required")
    save_json(args.output / "recovery-environment.json", {**identity, "xcode": xcode})
    run = api(f"repos/{REPOSITORY}/actions/runs/{SOURCE_RUN}")
    jobs = api(f"repos/{REPOSITORY}/actions/runs/{SOURCE_RUN}/attempts/{SOURCE_ATTEMPT}/jobs?per_page=100")
    save_json(args.output / "source-run.json", run)
    save_json(args.output / "source-jobs.json", jobs)
    source = validate_source(run, jobs)
    trees = validate_trees(git_tree(SOURCE_SHA), git_tree(identity["harnessSHA"]))
    metadata, downloads = {}, {}
    for label, expected in ARTIFACTS.items():
        artifact = api(f"repos/{REPOSITORY}/actions/artifacts/{expected['id']}")
        validate_artifact(artifact, expected)
        metadata[label] = artifact
        save_json(args.output / f"artifact-{label}.json", artifact)
        download = cache / f"{label}.zip"
        with download.open("wb") as stream:
            subprocess.run(["gh", "api", "--method", "GET",
                            f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"],
                           cwd=ROOT, stdin=subprocess.DEVNULL, stdout=stream,
                           check=True, timeout=180)
        verify_download(download, artifact)
        downloads[label] = download
        print(f"Verified {label} artifact {artifact['id']}: {artifact['digest']}", flush=True)
    generated = verify_generated(downloads["generated"], ROOT)
    inner = cache / "GSD-Simulator.zip"
    with zipfile.ZipFile(downloads["simulator"]) as archive:
        files = archive_files(archive)
        require(set(files) == {"GSD-Simulator.zip"}, "Unexpected simulator artifact contents")
        with archive.open("GSD-Simulator.zip") as source_file, inner.open("wb") as target:
            shutil.copyfileobj(source_file, target)
    with zipfile.ZipFile(inner) as archive:
        files = archive_files(archive)
        require(files and all(name.startswith(("GSD.app/", "__MACOSX/")) for name in files),
                "Unexpected app archive root")
    application = cache / "application"
    application.mkdir()
    command(["ditto", "-x", "-k", str(inner), str(application)])
    app = application / "GSD.app"
    inspected = inspect_app(app)
    receipt = {"status": "prepared", "repository": REPOSITORY,
               "compiledCodeSHA": SOURCE_SHA, "recovery": identity, "source": source,
               "reuse": {**trees, **generated,
                         "simulatorArchiveSHA256": sha256(inner),
                         "artifactIDs": {key: value["id"] for key, value in metadata.items()},
                         "artifactDigests": {key: value["digest"] for key, value in metadata.items()}},
               "app": inspected, "physicalDeviceTested": False,
               "personalChatGPTPairingTested": False, "providerInferenceTested": False}
    save_json(args.output / "preflight.json", receipt)


def finalize(args: argparse.Namespace) -> None:
    receipt = json.loads((args.output / "preflight.json").read_text(encoding="utf-8"))
    require(receipt["status"] == "prepared" and receipt["compiledCodeSHA"] == SOURCE_SHA,
            "Successful source verification is required")
    require(receipt["recovery"] == execution_identity(), "Recovery identity changed")
    app = Path(receipt["app"]["path"])
    require(app_tree_sha256(app) == receipt["app"]["treeSHA256"],
            "Compiled application changed during recovery")
    report = json.loads((args.output / "smoke/result.json").read_text(encoding="utf-8"))
    screenshots = validate_smoke(report, args.output / "smoke", app)
    receipt.update(status="passed", acceptance="reused-native-build-and-fresh-simulator-smoke",
                   simulatorSmoke=report, screenshots=screenshots)
    save_json(args.output / "combined-acceptance.json", receipt)
    print("Both simulator families passed against the verified source binary.", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "finalize"))
    parser.add_argument("--source-run", default=str(SOURCE_RUN))
    parser.add_argument("--expected-source-sha", default=SOURCE_SHA)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        if args.phase == "prepare":
            require(args.cache is not None, "A separate download cache is required")
            prepare(args)
        else:
            finalize(args)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError,
            zipfile.BadZipFile) as error:
        save_json(args.output / "recovery-error.json",
                  {"status": "failed", "phase": args.phase, "error": str(error),
                   "sourceRunID": SOURCE_RUN, "compiledCodeSHA": SOURCE_SHA})
        print(f"RECOVERY FAILED: {error}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
