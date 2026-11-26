#!/usr/bin/env python3
"""Prove owner/task_id uniqueness using two temporary, self-deleted accounts."""
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import secrets
import urllib.error
import urllib.request
import uuid


def exercise(origin):
    accounts = []
    proof = {"passed": False, "cleanup": [], "checks": {}}

    def request(method, route, body=None, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(origin + route, method=method, headers=headers,
            data=json.dumps(body).encode() if body is not None else None)
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        return status, json.loads(raw) if raw else {}

    try:
        for _ in range(2):
            email = "gsd-uniqueness-" + secrets.token_hex(10) + "@example.invalid"
            password = secrets.token_urlsafe(28) + "Az2!"
            status, _ = request("POST", "/api/collections/users/records",
                {"email": email, "password": password, "passwordConfirm": password})
            assert status in (200, 201), "account_create_failed"
            status, auth = request("POST", "/api/collections/users/auth-with-password",
                {"identity": email, "password": password})
            assert status == 200, "account_auth_failed"
            accounts.append((auth["record"]["id"], auth["token"]))
        task_id = str(uuid.uuid4())
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
        payload = {"owner": accounts[0][0], "task_id": task_id,
            "title": "בדיקת מניעת כפילות", "description": "Synthetic constraint acceptance",
            "urgent": False, "important": True, "quadrant": "notUrgentImportant",
            "completed": False, "recurrence": "none", "tags": [], "subtasks": [],
            "dependencies": [], "time_entries": [], "client_created_at": stamp,
            "client_updated_at": stamp, "device_id": "unique-id-acceptance"}
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: request("POST", "/api/collections/tasks/records",
                payload, accounts[0][1]), range(2)))
        statuses = sorted(result[0] for result in results)
        assert statuses in ([200, 400], [201, 400]), "duplicate_not_rejected"
        row = next(result[1] for result in results if result[0] in (200, 201))
        failed = next(result[1] for result in results if result[0] == 400)
        proof["checks"]["same_owner_concurrent_statuses"] = statuses
        proof["checks"]["validation_codes"] = sorted(v.get("code") for v in failed.get("data", {}).values() if isinstance(v, dict))
        second = {**payload, "owner": accounts[1][0]}
        status, _ = request("POST", "/api/collections/tasks/records", second, accounts[1][1])
        assert status in (200, 201), "owner_scoped_identity_failed"
        for owner, token in accounts:
            status, listing = request("GET", "/api/collections/tasks/records?perPage=100", token=token)
            assert status == 200 and listing["totalItems"] == 1, "owner_visible_count_mismatch"
            assert listing["items"][0]["owner"] == owner, "owner_isolation_failed"
            assert listing["items"][0]["task_id"] == task_id, "stable_task_identity_failed"
        status, _ = request("GET", "/api/collections/tasks/records/" + row["id"], token=accounts[1][1])
        assert status in (403, 404), "cross_account_read_allowed"
        proof["checks"].update({"tasks_per_account": [1, 1], "cross_account_read_status": status,
            "same_task_id_other_account_allowed": True,
            "task_id_sha256": hashlib.sha256(task_id.encode()).hexdigest()})
        proof["passed"] = True
    finally:
        for _, token in accounts:
            status, _ = request("DELETE", "/api/gsd/account", token=token)
            proof["cleanup"].append({"account_deleted": status == 204, "status": status})
        proof["passed"] = proof["passed"] and len(proof["cleanup"]) == 2 and all(x["account_deleted"] for x in proof["cleanup"])
    return proof


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin", required=True)
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()
    result = exercise(args.origin.rstrip("/"))
    with open(args.receipt, "x", encoding="utf-8") as target:
        json.dump(result, target, ensure_ascii=False, indent=2)
        target.write("\n")
    print(json.dumps(result))
    raise SystemExit(0 if result["passed"] else 1)
