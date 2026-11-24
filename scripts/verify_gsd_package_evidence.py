#!/usr/bin/env python3
"""Reuse successful package steps only when their complete inputs are unchanged."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

WORKFLOW = ".github/workflows/gsd-hanlin-agent-ios.yml"
STEPS = (
    "Validate Hanlin tools and official ChatGPT contracts",
    "Validate account, cloud and sync conflict contracts",
)
INPUTS = ("GSDKit", "Packages/GSDHanlinAgent", "HanlinSDK.lock.json", "scripts/install_hanlin_sdk.py")


def command(arguments: list[str], timeout: int = 90) -> str:
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("Package evidence command failed: " + arguments[0])
    return result.stdout


def step_block(workflow: str, name: str) -> str:
    marker = "      - name: " + name + "\n"
    if workflow.count(marker) != 1:
        raise ValueError("Missing or ambiguous package test command: " + name)
    start = workflow.index(marker)
    end = workflow.find("\n      - ", start + len(marker))
    block = workflow[start:] if end < 0 else workflow[start:end]
    # The only permitted difference is whether the unchanged command executes.
    return "\n".join(line for line in block.splitlines() if not line.strip().startswith("if:")).strip()


def verify_workflow(previous: str, current: str) -> None:
    for name in STEPS:
        if step_block(previous, name) != step_block(current, name):
            raise ValueError("Package test command changed: " + name)
    for name in ("GSD_CLOUD_SYSTEM_TEST", "GSD_CLOUD_TEST_BASE"):
        pattern = r"(?m)^  " + name + r": (.+)$"
        old, new = re.findall(pattern, previous), re.findall(pattern, current)
        if len(old) != 1 or old != new:
            raise ValueError("Package test environment changed: " + name)


def verify_log_bindings(log: str, source: str, xcode: str) -> dict:
    current = xcode.strip().splitlines()
    if len(current) != 2 or not re.fullmatch(r"Build version [A-Za-z0-9.]+", current[1]):
        raise ValueError("Current full Xcode version/build identity is required")
    current_build = current[1].removeprefix("Build version ")
    log = re.sub(r"\x1b\[[0-9;]*m", "", log)
    sources = set(re.findall(r"(?m)^\S+Z\s+GSD_SOURCE_SHA: ([0-9a-f]{40})\s*$", log))
    versions = set(re.findall(r"(?m)^\S+Z (Xcode [0-9]+(?:\.[0-9]+)*)\s*$", log))
    direct_builds = set(re.findall(r"(?m)^\S+Z Build version ([A-Za-z0-9.]+)\s*$", log))
    metadata_builds = set(re.findall(
        r"(?m)^\S+Z[ \t]+/\S*/appintentsmetadataprocessor[^\n]*? --xcode-version ([A-Za-z0-9.]+)(?:[ \t]|$)", log))
    if sources != {source}:
        raise ValueError("Prior job logs do not identify exactly the expected source")
    if versions != {current[0]}:
        raise ValueError("Xcode version differs from the executed package tests")
    if direct_builds | metadata_builds != {current_build}:
        raise ValueError("Xcode build identity is absent, conflicting, or changed")
    return {"version": current[0], "build_version": current_build,
            "prior_build_provenance": "xcodebuild-version-log" if direct_builds else "xcode-appintents-command-log"}


def tree_digest(source: str) -> str:
    listing = command(["git", "ls-tree", "-r", source, "--", *INPUTS])
    for path in INPUTS:
        if not any(line.split("\t", 1)[-1] == path or line.split("\t", 1)[-1].startswith(path + "/")
                   for line in listing.splitlines()):
            raise ValueError("Package evidence source is missing " + path)
    return hashlib.sha256(listing.encode()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--current-sha", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+", args.run_id) or not re.fullmatch(r"[0-9a-f]{40}", args.current_sha):
        raise ValueError("An exact run ID and source SHA are required")
    repository = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Unexpected repository name")
    prefix = "repos/" + repository + "/actions/"
    run = json.loads(command(["gh", "api", prefix + "runs/" + args.run_id]))
    if run["path"] != WORKFLOW or run["status"] != "completed":
        raise ValueError("Prior evidence must be a completed run of this workflow")
    source = run["head_sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", source):
        raise ValueError("Invalid evidence source SHA")
    jobs = json.loads(command(["gh", "api", prefix + "runs/" + args.run_id + "/jobs?filter=latest&per_page=100"]))["jobs"]
    matches = [job for job in jobs if job["name"] == "native-acceptance"]
    if len(matches) != 1 or matches[0]["status"] != "completed":
        raise ValueError("Missing completed native evidence job")
    job = matches[0]
    for name in ("Verify immutable source and Xcode", "Materialize and audit the original pinned Hanlin SDK", *STEPS):
        match = [step for step in job["steps"] if step["name"] == name]
        if len(match) != 1 or match[0]["conclusion"] != "success":
            raise ValueError("Prior required package evidence did not pass: " + name)
    log = command(["gh", "api", prefix + "jobs/" + str(job["id"]) + "/logs"])
    xcode = verify_log_bindings(log, source, command(["xcodebuild", "-version"]))
    if command(["git", "rev-parse", "HEAD"]).strip() != args.current_sha:
        raise ValueError("Current source differs from requested validation source")
    command(["git", "fetch", "--no-tags", "--depth=1", "origin", source])
    previous_workflow = command(["git", "show", source + ":" + WORKFLOW])
    verify_workflow(previous_workflow, Path(WORKFLOW).read_text())
    previous_digest, current_digest = tree_digest(source), tree_digest(args.current_sha)
    if previous_digest != current_digest:
        raise ValueError("Package sources, tests, manifests, or SDK pin changed; rerun package tests")
    # Resolution must retain the checked-in immutable GRDB revision in both roots.
    expected_pins = json.loads(command(["git", "show", source + ":GSDKit/Package.resolved"]))["pins"]
    for root in (Path("GSDKit"), Path("Packages/GSDHanlinAgent")):
        actual_pins = json.loads((root / "Package.resolved").read_text())["pins"]
        if sorted(actual_pins, key=lambda p: p["identity"]) != sorted(expected_pins, key=lambda p: p["identity"]):
            raise ValueError("Materialized package dependency revisions changed")
    receipt = {"passed": True, "mode": "inherited-successful-package-steps",
               "current_source_sha": args.current_sha, "source_sha": source, "run_id": args.run_id,
               "job_id": job["id"], "prior_run_conclusion": run["conclusion"],
               "prior_job_conclusion": job["conclusion"], "passed_steps": list(STEPS),
               "xcode": xcode, "inputs": list(INPUTS), "input_tree_sha256": current_digest,
               "dependency_pins": expected_pins,
               "run_url": run["html_url"]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    print("GSD_UNCHANGED_PACKAGE_EVIDENCE_VERIFIED", args.run_id, source, current_digest)


if __name__ == "__main__":
    main()
