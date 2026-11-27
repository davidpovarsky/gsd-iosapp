#!/usr/bin/env python3
"""Real isolated PocketBase/gateway ordering tests; never uses a production DB.

The fixture-only model hook blocks after relation validation and before INSERT.
Its barrier, accounts, processes and database belong to this one invocation.
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import http.server
import http.client
import json
import os
import pathlib
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request


BASELINE = "ed379d60d4c41da91d8b5dfe32601956c8abf7c3"
STAMP = "2026-11-27T07:00:00.000Z"


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Barrier:
    def __init__(self, output):
        self.events, self.releases, self.lock = {}, {}, threading.Lock()
        self.trace = output / "barrier.jsonl"
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                action, name = self.path.strip("/").split("/", 1)
                with owner.lock:
                    event = owner.events.setdefault((action, name), threading.Event())
                    release = owner.releases.setdefault(name, threading.Event())
                    with owner.trace.open("a") as stream:
                        stream.write(json.dumps({"utc": utc(), "action": action, "name": name}) + "\n")
                    event.set()
                if action == "block" and not release.wait(20):
                    self.send_error(504)
                    return
                self.send_response(204)
                self.end_headers()

            def log_message(self, *_args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @property
    def origin(self):
        return "http://127.0.0.1:" + str(self.server.server_port)

    def wait(self, action, name):
        with self.lock:
            event = self.events.setdefault((action, name), threading.Event())
        assert event.wait(12), "fixture barrier was not reached: " + action + "/" + name

    def release(self, name):
        with self.lock:
            self.releases.setdefault(name, threading.Event()).set()

    def arm(self, action, name):
        with self.lock:
            self.events.setdefault((action, name), threading.Event()).clear()

    def close(self):
        with self.lock:
            for event in self.releases.values():
                event.set()
        self.server.shutdown()
        self.server.server_close()


class Fixture:
    def __init__(self, args):
        self.args = args
        self.root = pathlib.Path(args.run_root)
        assert self.root.parent.resolve() == pathlib.Path("/var/tmp"), "fixture must be directly under /var/tmp"
        assert not self.root.exists(), "immutable run directory already exists"
        assert shutil.disk_usage(self.root.parent).free > 150 * 1024 * 1024, "fixture disk reserve"
        self.root.mkdir(mode=0o700)
        self.source = pathlib.Path(args.source).resolve(strict=True)
        self.binary = pathlib.Path(args.pocketbase).resolve(strict=True)
        self.processes, self.live, self.streams, self.checks, self.requests = [], [], [], [], []
        self.profile = "baseline"
        self.start_count = 0
        self.started = utc()
        self.controller = {"path": str(pathlib.Path(__file__).resolve()), "sha256": sha(pathlib.Path(__file__))}
        self.barrier = Barrier(self.root)
        self.executor = concurrent.futures.ThreadPoolExecutor(max_workers=4)
        self.pb_port, self.gateway_port = free_port(), free_port()
        assert self.pb_port != self.gateway_port
        self.origin = "http://127.0.0.1:" + str(self.gateway_port)
        self.pb_origin = "http://127.0.0.1:" + str(self.pb_port)
        self.paths = self.prepare_source()
        self.inputs = {str(p.relative_to(self.root)): sha(p) for p in self.paths}

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.source), *args],
                                       env={**os.environ, "GIT_OPTIONAL_LOCKS": "0",
                                            "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0"})

    def prepare_source(self):
        paths = []
        for profile in (["baseline", "candidate"] if self.args.phase == "green" else ["baseline"]):
            names = self.git("ls-tree", "-r", "--name-only", BASELINE, "cloud/gateway", "cloud/pocketbase/pb_hooks", "cloud/pocketbase/pb_migrations").decode().splitlines()
            if profile == "candidate":
                names = sorted(set(names) | {str(p.relative_to(self.source)) for folder in ("pb_hooks", "pb_migrations")
                                             for p in (self.source / "cloud/pocketbase" / folder).glob("*.js")})
            for rel in names:
                if not rel.endswith((".js", ".mjs", ".json")):
                    continue
                destination = self.root / profile / rel.removeprefix("cloud/")
                destination.parent.mkdir(parents=True, exist_ok=True)
                content = self.git("show", BASELINE + ":" + rel) if profile == "baseline" else (self.source / rel).read_bytes()
                destination.write_bytes(content)
                paths.append(destination)
            paths.extend(self.prepare_fixture_hooks(profile))
        return paths

    def prepare_fixture_hooks(self, profile):
        hooks = self.root / profile / "pocketbase/pb_hooks"
        (hooks / "fixture-config.json").write_text(json.dumps({"barrier": self.barrier.origin}))
        barrier_hook = hooks / "fixture_ordering.pb.js"
        barrier_hook.write_text('''// ISOLATED TEST ONLY. This file is never a production hook.
onRecordCreateExecute((e) => {
  const id = e.record.getString("task_id");
  if (!id.startsWith("fixture-block-")) return e.next();
  const config = JSON.parse(toString($os.readFile(__hooks + "/fixture-config.json")));
  const before = $http.send({url:config.barrier + "/block/" + id,timeout:22});
  if (before.statusCode !== 204) throw new Error("fixture barrier timeout");
  e.next();
  const after = $http.send({url:config.barrier + "/after/" + id,timeout:3});
  if (after.statusCode !== 204) throw new Error("fixture completion failed");
}, "tasks");
routerUse((e) => {
  const path = e.request.url.path;
  if (path === "/api/gsd/account" || path === "/api/gsd/dataset/reset") {
    const config = JSON.parse(toString($os.readFile(__hooks + "/fixture-config.json")));
    const name = path.endsWith("/reset") ? "reset" : "account";
    const mark = $http.send({url:config.barrier + "/entered/" + name,timeout:3});
    if (mark.statusCode !== 204) throw new Error("fixture admission failed");
  }
  return e.next();
});
''')
        bootstrap = self.root / profile / "pocketbase/pb_migrations/9999999999_fixture_bootstrap.js"
        bootstrap.write_text('''// ISOLATED TEST ONLY: suppress the first-superuser setup token log.
migrate((app) => {
  const record = new Record(app.findCollectionByNameOrId("_superusers"));
  record.set("email", "dataset-fixture-bootstrap@example.invalid");
  record.set("password", $security.randomString(48));
  app.save(record);
}, () => {});
''')
        return [barrier_hook, bootstrap, hooks / "fixture-config.json"]

    def launch(self, command, name, env):
        stream = (self.root / (name + ".log")).open("xb")
        self.streams.append(stream)
        process = subprocess.Popen(command, cwd=self.root, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        self.processes.append({"process": process, "name": name, "command": command})
        self.live.append(process)
        return process

    def start(self):
        self.start_count += 1
        suffix = "-" + self.profile + "-" + str(self.start_count)
        env = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(self.root), "LANG": "C.UTF-8"}
        self.launch([str(self.binary), "serve", "--http=127.0.0.1:" + str(self.pb_port),
                     "--dir=" + str(self.root / "pb_data"),
                     "--hooksDir=" + str(self.root / self.profile / "pocketbase/pb_hooks"),
                     "--migrationsDir=" + str(self.root / self.profile / "pocketbase/pb_migrations")], "pocketbase" + suffix, env)
        self.ready(self.pb_origin)
        env.update(GSD_CLOUD_PORT=str(self.gateway_port), GSD_CLOUD_HOST="127.0.0.1",
                   GSD_CLOUD_ORIGIN=self.origin, GSD_POCKETBASE_ORIGIN=self.pb_origin,
                   GSD_CLOUD_STATE_DIR=str(self.root / "gateway-state"))
        self.launch(["/usr/local/bin/node", str(self.root / self.profile / "gateway/server.mjs")], "gateway" + suffix, env)
        self.ready(self.origin)

    def ready(self, origin):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            assert all(process.poll() is None for process in self.live), "fixture process exited; inspect retained log"
            try:
                with urllib.request.urlopen(origin + "/api/health", timeout=1) as result:
                    if result.status == 200:
                        return
            except (urllib.error.URLError, TimeoutError):
                time.sleep(0.05)
        raise AssertionError("fixture health timeout")

    def stop_services(self):
        for process in reversed(self.live):
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
        self.live.clear()

    def request(self, method, path, body=None, token=None, generation=None, expect=200):
        headers = {"Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = token
        if generation is not None:
            headers["X-GSD-Dataset-Generation"] = generation
        request = urllib.request.Request(self.origin + path,
                                         data=json.dumps(body).encode() if body is not None else None,
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=25) as response:
                status, raw = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, raw = error.code, error.read()
        self.requests.append({"utc": utc(), "method": method, "path": path, "status": status})
        accepted = (expect,) if isinstance(expect, int) else expect
        assert status in accepted, f"{method} {path}: expected {accepted}, observed {status}"
        return json.loads(raw) if raw else {}

    def account(self):
        email = "dataset-" + secrets.token_hex(8) + "@example.invalid"
        password = secrets.token_urlsafe(28) + "Az2!"
        self.request("POST", "/api/collections/users/records", {"email": email, "password": password,
                                                                "passwordConfirm": password}, expect=(200, 201))
        auth = self.request("POST", "/api/collections/users/auth-with-password",
                            {"identity": email, "password": password})
        return {"id": auth["record"]["id"], "token": auth["token"]}

    def task(self, account, task_id):
        return {"owner": account["id"], "task_id": task_id, "title": task_id,
                "client_updated_at": STAMP, "client_created_at": STAMP,
                "device_id": "dataset_ordering_fixture"}

    def disconnected_create(self, account, task_id, generation=None):
        body = json.dumps(self.task(account, task_id)).encode()
        headers = ["POST /api/collections/tasks/records HTTP/1.1",
                   "Host: 127.0.0.1:" + str(self.gateway_port),
                   "Content-Type: application/json", "Authorization: " + account["token"],
                   "Content-Length: " + str(len(body)), "Connection: close"]
        if generation is not None:
            headers.append("X-GSD-Dataset-Generation: " + generation)
        sock = socket.create_connection(("127.0.0.1", self.gateway_port), timeout=5)
        sock.sendall(("\r\n".join(headers) + "\r\n\r\n").encode() + body)
        self.barrier.wait("block", task_id)
        sock.close()
        self.check("actual_client_disconnected_" + task_id, True)

    def rows(self, query, values=()):
        database = self.root / "pb_data/data.db"
        with sqlite3.connect("file:" + str(database) + "?mode=ro", uri=True) as connection:
            connection.execute("PRAGMA query_only=ON")
            return connection.execute(query, values).fetchall()

    def check(self, name, condition, **evidence):
        item = {"name": name, "utc": utc(), "passed": bool(condition), **evidence}
        self.checks.append(item)
        with (self.root / "checks.jsonl").open("a") as stream:
            stream.write(json.dumps(item, sort_keys=True) + "\n")
        assert condition, name

    def red(self):
        a = self.account()
        control = self.request("POST", "/api/collections/tasks/records", self.task(a, "red-control"), a["token"], expect=(200, 201))
        late = "fixture-block-reset-red"
        self.disconnected_create(a, late)
        listing = self.request("GET", "/api/collections/tasks/records?perPage=500", token=a["token"])
        self.check("red_delayed_create_absent_from_erase_snapshot", {x["id"] for x in listing["items"]} == {control["id"]})
        for row in listing["items"]:
            self.request("DELETE", "/api/collections/tasks/records/" + row["id"], token=a["token"], expect=204)
        self.barrier.release(late)
        self.barrier.wait("after", late)
        self.check("red_erase_invariant_violated", self.rows("SELECT task_id FROM tasks WHERE owner=?", (a["id"],)) == [(late,)],
                   expectedRemaining=0, observedRemaining=1)
        b = self.account()
        orphan = "fixture-block-account-red"
        self.disconnected_create(b, orphan)
        self.request("DELETE", "/api/gsd/account", token=b["token"], expect=204)
        self.check("red_account_deleted_before_late_insert", self.rows("SELECT id FROM users WHERE id=?", (b["id"],)) == [])
        self.barrier.release(orphan)
        self.barrier.wait("after", orphan)
        self.check("red_account_orphan_invariant_violated", self.rows("SELECT task_id FROM tasks WHERE owner=?", (b["id"],)) == [(orphan,)],
                   expectedOrphans=0, observedOrphans=1)

    def digest(self, table, owner=None):
        assert table in ("users", "tasks", "gsd_library")
        query = "SELECT * FROM " + table + (" WHERE owner=?" if owner else "") + " ORDER BY id"
        rows = self.rows(query, (owner,) if owner else ())
        return {"count": len(rows), "sha256": hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()}

    def library(self, account, kind, identity, stamp=STAMP, deleted=False):
        payload = "retained-deleted-marker" if deleted else json.dumps({"id": identity, "name": "fixture"})
        self.request("PUT", "/api/gsd/library/" + kind + "/" + identity,
                     {"expected_version": "", "client_updated_at": stamp, "payload": payload, "deleted": deleted},
                     account["token"], expect=204)

    def upgrade_populated_fixture(self):
        a, b = self.account(), self.account()
        for account, identity in ((a, "upgrade-control-a"), (b, "upgrade-control-b")):
            self.request("POST", "/api/collections/tasks/records", self.task(account, identity), account["token"], expect=(200, 201))
        for kind in ("archive", "trash", "view"):
            self.library(a, kind, "upgrade-" + kind, "2030-01-01T00:00:00.000Z")
        self.library(a, "trash", "already-deleted", deleted=True)
        self.library(b, "view", "private-view-b")
        self.stop_services()
        # Historical orphan setup belongs only to this already-stopped disposable DB.
        with sqlite3.connect(self.root / "pb_data/data.db") as database:
            database.execute("INSERT INTO tasks(id,owner,task_id,title) VALUES(?,?,?,?)",
                             ("fixtureorphan01", "missingowner001", "historical-orphan", "preserve historical orphan"))
        before = {table: self.digest(table) for table in ("users", "tasks", "gsd_library")}
        self.profile = "candidate"
        self.start()
        after = {table: self.digest(table) for table in before}
        self.check("populated_upgrade_preserves_all_original_rows", before == after, before=before, after=after)
        self.check("historical_orphan_preserved_by_migration", self.rows("SELECT task_id FROM tasks WHERE owner='missingowner001'") == [("historical-orphan",)])
        self.check("private_metadata_starts_empty", self.rows("SELECT count(*) FROM gsd_dataset_state")[0][0] == 0 and self.rows("SELECT count(*) FROM gsd_dataset_resets")[0][0] == 0)
        self.check("existing_jwt_and_default_generation_work", self.request("GET", "/api/gsd/dataset", token=a["token"]) == {"generation": "0"})
        return a, b

    def assert_error(self, name, payload, status, message):
        self.check(name, payload == {"status": status, "message": message, "data": {}})

    def green_reset_order(self, a, b):
        other_before = {table: self.digest(table, b["id"]) for table in ("tasks", "gsd_library")}
        deleted_before = self.rows("SELECT * FROM gsd_library WHERE owner=? AND entity_id='already-deleted'", (a["id"],))
        late = "fixture-block-reset-green"
        self.disconnected_create(a, late, "0")
        body = {"expected_generation": "0", "request_id": "reset-after-admitted-create"}
        self.barrier.arm("entered", "reset")
        future = self.executor.submit(self.request, "POST", "/api/gsd/dataset/reset", body, a["token"])
        self.barrier.wait("entered", "reset")
        self.check("reset_waits_for_admitted_create_transaction", not concurrent.futures.wait([future], timeout=0.2).done)
        self.barrier.release(late)
        self.barrier.wait("after", late)
        receipt = future.result(timeout=10)
        self.check("reset_deletes_late_create_and_control", receipt["deleted_tasks"] == 2 and self.rows("SELECT id FROM tasks WHERE owner=?", (a["id"],)) == [])
        self.check("reset_rotates_and_returns_exact_receipt_schema", set(receipt) == {"generation", "request_id", "deleted_tasks", "tombstoned_library"} and len(receipt["generation"]) == 32 and receipt["request_id"] == body["request_id"])
        self.check("reset_tombstones_all_three_library_kinds", receipt["tombstoned_library"] == 3 and self.rows("SELECT kind FROM gsd_library WHERE owner=? AND deleted=0", (a["id"],)) == [])
        rows = self.rows("SELECT payload,client_updated_at FROM gsd_library WHERE owner=? AND entity_id!='already-deleted'", (a["id"],))
        self.check("library_payloads_empty_and_versions_strictly_advance", len(rows) == 3 and all(payload == "" and stamp > "2030-01-01T00:00:00.000Z" for payload, stamp in rows))
        self.check("already_deleted_library_metadata_preserved", deleted_before == self.rows("SELECT * FROM gsd_library WHERE owner=? AND entity_id='already-deleted'", (a["id"],)))
        self.check("other_account_data_and_generation_unchanged", other_before == {table: self.digest(table, b["id"]) for table in other_before} and self.request("GET", "/api/gsd/dataset", token=b["token"]) == {"generation": "0"})
        return body, receipt

    def green_idempotency(self, a, b, body, receipt):
        generation = receipt["generation"]
        self.request("POST", "/api/collections/tasks/records", self.task(a, "post-reset-task"), a["token"], generation, expect=(200, 201))
        replay = self.request("POST", "/api/gsd/dataset/reset", body, a["token"])
        self.check("exact_reset_retry_replays_without_second_erase", replay == receipt and self.rows("SELECT task_id FROM tasks WHERE owner=?", (a["id"],)) == [("post-reset-task",)])
        changed = {**body, "expected_generation": generation}
        self.assert_error("changed_fingerprint_is_standard_409", self.request("POST", "/api/gsd/dataset/reset", changed, a["token"], expect=409), 409, "request_id_conflict")
        stale = {"expected_generation": "0", "request_id": "new-stale-reset-id"}
        self.assert_error("stale_reset_is_standard_409", self.request("POST", "/api/gsd/dataset/reset", stale, a["token"], expect=409), 409, "dataset_generation_mismatch")
        self.assert_error("stale_create_is_standard_409", self.request("POST", "/api/collections/tasks/records", self.task(a, "must-not-resurrect"), a["token"], "0", expect=409), 409, "dataset_generation_mismatch")
        self.check("stale_create_does_not_insert", self.rows("SELECT id FROM tasks WHERE task_id='must-not-resurrect'") == [])
        self.request("POST", "/api/collections/tasks/records", self.task(a, "legacy-headerless-after-reset"), a["token"], expect=(200, 201))
        self.check("legacy_headerless_create_keeps_existing_meaning", self.request("GET", "/api/gsd/dataset", token=a["token"]) == {"generation": generation})
        duplicate = {"expected_generation": generation, "request_id": "simultaneous-reset"}
        futures = [self.executor.submit(self.request, "POST", "/api/gsd/dataset/reset", duplicate, a["token"]) for _ in range(2)]
        results = [future.result(timeout=10) for future in futures]
        self.check("concurrent_duplicate_reset_rotates_once", results[0] == results[1] and results[0]["deleted_tasks"] == 2 and self.rows("SELECT count(*) FROM gsd_dataset_resets WHERE owner=? AND request_id=?", (a["id"], duplicate["request_id"])) == [(1,)])
        b_result = self.request("POST", "/api/gsd/dataset/reset", body, b["token"])
        self.check("request_ids_are_account_scoped", b_result["generation"] != receipt["generation"] and b_result["deleted_tasks"] == 1)
        self.check("historical_orphan_survives_other_account_resets", self.rows("SELECT task_id FROM tasks WHERE owner='missingowner001'") == [("historical-orphan",)])

    def green_account_order(self):
        account = self.account()
        late = "fixture-block-account-green"
        # Headerless legacy clients also receive the atomic owner-existence guard.
        self.disconnected_create(account, late)
        self.barrier.arm("entered", "account")
        future = self.executor.submit(self.request, "DELETE", "/api/gsd/account", None, account["token"], None, 204)
        self.barrier.wait("entered", "account")
        self.check("account_delete_waits_for_legacy_create_transaction", not concurrent.futures.wait([future], timeout=0.2).done)
        self.barrier.release(late)
        self.barrier.wait("after", late)
        future.result(timeout=10)
        self.check("account_delete_cascades_admitted_late_insert", self.rows("SELECT id FROM users WHERE id=?", (account["id"],)) == [] and self.rows("SELECT id FROM tasks WHERE owner=?", (account["id"],)) == [])
        self.request("POST", "/api/collections/tasks/records", self.task(account, "after-deleted-account"), account["token"], expect=(400, 401, 403))
        self.check("same_user_write_after_deletion_is_rejected", self.rows("SELECT id FROM tasks WHERE task_id='after-deleted-account'") == [])

    def green_token_bounds(self, a):
        current = self.request("GET", "/api/gsd/dataset", token=a["token"])["generation"]
        valid = ["a" * 128, "é" * 64, "😀" * 32, "  opaque א  ", "é", "e\u0301"]
        for index, identity in enumerate(valid):
            body = {"expected_generation": current, "request_id": identity}
            receipt = self.request("POST", "/api/gsd/dataset/reset", body, a["token"])
            self.check("request_id_exact_utf8_boundary_" + str(index),
                       receipt["request_id"] == identity and
                       self.request("POST", "/api/gsd/dataset/reset", body, a["token"]) == receipt,
                       utf8Bytes=len(identity.encode("utf-8")))
            current = receipt["generation"]
        invalid = ["", "a" * 129, "é" * 65, "😀" * 33, "control\u0000", "control\t", "control\u007f"]
        for field in ("request_id", "expected_generation"):
            for index, value in enumerate(invalid):
                body = {"expected_generation": current, "request_id": "invalid-boundary"}
                body[field] = value
                self.assert_error("invalid_" + field + "_boundary_" + str(index),
                    self.request("POST", "/api/gsd/dataset/reset", body, a["token"], expect=400),
                    400, "invalid_dataset_reset")
        self.assert_error("valid_utf8_expected_generation_reaches_compare",
            self.request("POST", "/api/gsd/dataset/reset",
                         {"expected_generation": "é" * 64, "request_id": "valid-opaque-stale"},
                         a["token"], expect=409), 409, "dataset_generation_mismatch")
        self.check("invalid_tokens_do_not_rotate_or_save_receipts",
                   self.request("GET", "/api/gsd/dataset", token=a["token"]) == {"generation": current} and
                   self.rows("SELECT id FROM gsd_dataset_resets WHERE owner=? AND request_id=?",
                             (a["id"], "invalid-boundary")) == [])
        # HTTP field duplication must fail before Node coalesces it to an opaque string.
        payload = json.dumps(self.task(a, "duplicate-generation-must-not-insert")).encode()
        connection = http.client.HTTPConnection("127.0.0.1", self.gateway_port, timeout=10)
        try:
            connection.putrequest("POST", "/api/collections/tasks/records")
            connection.putheader("Authorization", a["token"])
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", str(len(payload)))
            connection.putheader("X-GSD-Dataset-Generation", current)
            connection.putheader("X-GSD-Dataset-Generation", current)
            connection.endheaders(payload)
            response = connection.getresponse()
            status, result = response.status, json.loads(response.read())
            self.requests.append({"utc": utc(), "method": "POST", "path": "/api/collections/tasks/records", "status": status})
            self.check("duplicate_generation_headers_are_rejected_without_insert", status == 400 and
                       result == {"status": 400, "message": "invalid_dataset_generation", "data": {}} and
                       self.rows("SELECT id FROM tasks WHERE task_id='duplicate-generation-must-not-insert'") == [])
        finally:
            connection.close()

    def green_restart(self, a, original_body, original_receipt):
        current = self.request("GET", "/api/gsd/dataset", token=a["token"])["generation"]
        self.request("POST", "/api/collections/tasks/records", self.task(a, "restart-survivor"),
                     a["token"], current, expect=(200, 201))
        before = self.rows("SELECT * FROM gsd_dataset_resets WHERE owner=? ORDER BY id", (a["id"],))
        self.stop_services()
        self.start()
        self.check("generation_and_receipts_survive_actual_service_restart",
                   self.request("GET", "/api/gsd/dataset", token=a["token"]) == {"generation": current} and
                   before == self.rows("SELECT * FROM gsd_dataset_resets WHERE owner=? ORDER BY id", (a["id"],)))
        self.check("durable_reset_replay_preserves_newer_generation_and_task",
                   self.request("POST", "/api/gsd/dataset/reset", original_body, a["token"]) == original_receipt and
                   self.request("GET", "/api/gsd/dataset", token=a["token"]) == {"generation": current} and
                   self.rows("SELECT task_id FROM tasks WHERE owner=?", (a["id"],)) == [("restart-survivor",)])

    def green_policy(self, a):
        self.request("GET", "/api/gsd/dataset", expect=401)
        self.request("POST", "/api/gsd/dataset/reset", {"expected_generation": "0", "request_id": "unauthenticated"}, expect=401)
        self.check("both_dataset_routes_require_authentication", True)
        self.assert_error("reset_rejects_unrecognized_fields", self.request("POST", "/api/gsd/dataset/reset", {"expected_generation": "0", "request_id": "invalid", "extra": True}, a["token"], expect=400), 400, "invalid_dataset_reset")
        self.assert_error("generation_header_empty_is_not_legacy", self.request("POST", "/api/collections/tasks/records", self.task(a, "empty-generation"), a["token"], "", expect=400), 400, "invalid_dataset_generation")
        self.assert_error("generation_header_bounded", self.request("POST", "/api/collections/tasks/records", self.task(a, "oversized-generation"), a["token"], "x" * 129, expect=400), 400, "invalid_dataset_generation")
        for collection in ("gsd_dataset_state", "gsd_dataset_resets"):
            self.request("GET", "/api/collections/" + collection + "/records", token=a["token"], expect=403)
        self.check("metadata_collections_not_exposed_by_native_proxy", True)
        self.request("DELETE", "/api/gsd/account", token=a["token"], expect=204)
        self.check("account_delete_cascades_private_generation_and_receipts", self.rows("SELECT id FROM gsd_dataset_state WHERE owner=?", (a["id"],)) == [] and self.rows("SELECT id FROM gsd_dataset_resets WHERE owner=?", (a["id"],)) == [])

    def green(self):
        a, b = self.upgrade_populated_fixture()
        body, receipt = self.green_reset_order(a, b)
        self.green_idempotency(a, b, body, receipt)
        self.green_account_order()
        self.green_token_bounds(a)
        self.green_restart(a, body, receipt)
        self.green_policy(a)

    def close(self, error):
        self.barrier.close()
        self.executor.shutdown(wait=True, cancel_futures=True)
        stopped = []
        for item in reversed(self.processes):
            process = item["process"]
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            stopped.append({"name": item["name"], "pid": process.pid, "command": item["command"], "exit": process.returncode})
        for stream in self.streams:
            stream.close()
        unchanged = self.inputs == {str(p.relative_to(self.root)): sha(p) for p in self.paths} and self.controller["sha256"] == sha(pathlib.Path(__file__))
        if not unchanged and error is None:
            error = {"type": "AssertionError", "message": "fixture inputs/controller changed during execution"}
        receipt = {"schema": 1, "phase": self.args.phase, "startedUTC": self.started, "finishedUTC": utc(),
                   "scope": "isolated real PocketBase/gateway dataset reset and create ordering",
                   "controller": self.controller, "productionAcceptanceComplete": False, "nativeShareSheetAcceptance": False,
                   "sourceAttribution": "baseline Git source plus exact candidate file hashes; no uncommitted candidate execution is attributed to the parent SHA",
                   "result": "RED_REPRODUCED" if error is None and self.args.phase == "red" else "PASS" if error is None else "FAIL",
                   "acceptanceComplete": error is None and self.args.phase == "green", "productionTouched": False,
                   "sourceRoot": str(self.source), "sourceSHA": self.git("rev-parse", "HEAD").decode().strip(),
                   "baselineSHA": BASELINE, "fixtureRoot": str(self.root), "binary": {"path": str(self.binary), "sha256": sha(self.binary)},
                   "inputHashes": self.inputs, "inputsUnchangedAfter": unchanged, "checks": self.checks,
                   "requests": self.requests, "ownedProcesses": stopped, "error": error,
                   "logs": {p.name: {"sha256": sha(p), "bytes": p.stat().st_size} for p in self.root.glob("*.log")},
                   "fixtureOnlyHooksNeverDeploy": ["fixture_ordering.pb.js", "9999999999_fixture_bootstrap.js"]}
        (self.root / "receipt.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"receipt": str(self.root / "receipt.json"), "sha256": sha(self.root / "receipt.json"),
                          "result": receipt["result"], "checks": len(self.checks), "inputsUnchangedAfter": unchanged}))


def main():
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt("owned fixture interrupted")

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("red", "green"), required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--pocketbase", required=True)
    parser.add_argument("--run-root", required=True)
    args = parser.parse_args()
    fixture, error = None, None
    try:
        fixture = Fixture(args)
        fixture.start()
        if args.phase == "red":
            fixture.red()
        else:
            fixture.green()
    except BaseException as exception:
        error = {"type": type(exception).__name__, "message": str(exception)}
        raise
    finally:
        if fixture is not None:
            fixture.close(error)


if __name__ == "__main__":
    main()
