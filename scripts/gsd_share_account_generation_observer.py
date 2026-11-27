#!/usr/bin/env python3
"""Own only pending Share fixture files in one fresh simulator; SQLite stays read-only."""
from __future__ import annotations
import datetime,hashlib,importlib.util,json,os,pathlib,re,subprocess,threading,uuid
PHASES=["seed-current","verify-applied","seed-stale","verify-held","verify-held-relaunch"]
READONLY_SHA="05b6e29327ccab69b2d41b6e54d79b7dcaac84248936d4149ccd2903f93f4b81"
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def digest(p):return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
def append_json(path,value):
    path=pathlib.Path(path);assert not path.exists() and not path.is_symlink()
    temporary=path.with_name("."+path.name+"."+uuid.uuid4().hex+".tmp")
    with temporary.open("xb") as stream:
        os.chmod(temporary,0o600);stream.write(json.dumps(value,indent=2,sort_keys=True).encode()+b"\n")
        stream.flush();os.fsync(stream.fileno())
    try:os.link(temporary,path)
    finally:temporary.unlink()

class ShareAccountGenerationObserver:
    def __init__(self,*,source_sha,source,device,artifacts,evidence,environment,seeder_contract,seeder_contract_sha256,readonly_helper):
        assert re.fullmatch(r"[0-9a-f]{40}",source_sha)
        assert str(uuid.UUID(device)).upper()==device.upper()
        self.source_sha=source_sha;self.source=pathlib.Path(source).resolve();self.device=device
        self.artifacts=pathlib.Path(artifacts).resolve();self.child=self.artifacts/"share-account-generation"
        self.evidence=pathlib.Path(evidence);assert not self.evidence.exists();self.evidence.mkdir(mode=0o700)
        self.environment=dict(environment);self.contract_path=pathlib.Path(seeder_contract)
        assert digest(self.contract_path)==seeder_contract_sha256
        self.contract_sha=seeder_contract_sha256;self.contract=json.loads(self.contract_path.read_text())
        assert self.contract["passed"] is True and self.contract["sourceSHA"]==source_sha
        assert self.contract["platform"]=="Darwin" and self.contract["productName"]=="ShareAccountGenerationSeed"
        self.binary=pathlib.Path(self.contract["product"]["path"])
        assert self.binary.is_file() and digest(self.binary)==self.contract["product"]["sha256"]
        assert digest(readonly_helper)==READONLY_SHA
        spec=importlib.util.spec_from_file_location("gsd_share_native_readonly",readonly_helper)
        self.database=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.database)
        self._source_guard()
        self.records=[];self.errors=[];self.pending={};self.closed=False
        self.stop=threading.Event()
        self.thread=threading.Thread(target=self._run,name="gsd-owned-account-share-observer",daemon=True)
    def _source_guard(self):
        assert digest(self.contract_path)==self.contract_sha
        assert all(digest(self.source/n)==h for n,h in self.contract["inputs"].items())
        assert digest(self.binary)==self.contract["product"]["sha256"]
    def start(self):self.thread.start()
    def _app_stopped(self):
        proc=subprocess.run(["xcrun","simctl","get_app_container",self.device,"com.itorah.gsd","app"],
            capture_output=True,text=True,env=self.environment,check=True,timeout=30)
        bundle=pathlib.Path(proc.stdout.strip()).resolve()
        device=pathlib.Path("/Users/m1/Library/Developer/CoreSimulator/Devices")/self.device.upper()
        assert bundle.is_dir() and bundle.is_relative_to(device/"data/Containers/Bundle/Application")
        executable=str(bundle/"GSD")
        rows=subprocess.check_output(["ps","-axo","pid=,command="],text=True,timeout=30)
        matches=[line.strip() for line in rows.splitlines() if executable in line]
        assert not matches,"Owned app must be terminated before fixture preparation/readback"
        return {"appBundle":str(bundle),"matchingProcesses":matches,"verifiedUTC":now()}
    def _snapshot(self,group,phase,suffix):
        snapshot=self.database.logical_database_state(group/"gsd.sqlite",group)
        assert snapshot["mode"]=="ro" and snapshot["queryOnly"] is True and snapshot["sqlWrites"]==0
        path=self.evidence/(phase+"-"+suffix+".database.json");append_json(path,snapshot)
        return snapshot,{"path":str(path),"sha256":digest(path)}
    def _absent(self,snapshot,task_id):
        for table,key in [("tasks","id"),("syncQueue","taskId"),("deletedTasks","id"),("archivedTasks","id")]:
            assert key in snapshot["logicalState"]["tables"][table]["columns"]
            assert not any(row[key]==task_id for row in self.database.decoded_rows(snapshot,table)),table+" contains fixture capture"
    def _pending(self,group,task_id):
        result=[]
        for p in sorted((group/"share-outbox").glob("*.json")):
            assert p.is_file() and not p.is_symlink()
            value=json.loads(p.read_text())
            if value.get("taskID")==task_id:result.append((p,value))
        return result
    def _inflight(self,group,task_id):
        result=[]
        for p in sorted((group/"share-inflight").glob("*.json")):
            assert p.is_file() and not p.is_symlink()
            if json.loads(p.read_text()).get("taskID")==task_id:result.append(p)
        return result
    def _capture_inventory(self,group,phase,label):
        copies=self.evidence/(phase+"-"+label+"-capture-files");copies.mkdir(mode=0o700)
        inventory={"schemaVersion":1,"phase":phase,"label":label,"capturedUTC":now(),"directories":{}}
        for name in ["share-outbox","share-inflight"]:
            directory=group/name
            assert not directory.is_symlink()
            records=[]
            for path in sorted(directory.glob("*.json")):
                assert path.is_file() and not path.is_symlink()
                raw=path.read_bytes();value=json.loads(raw)
                destination=copies/(name+"-"+path.name)
                with destination.open("xb") as stream:
                    os.chmod(destination,0o600);stream.write(raw)
                assert digest(path)==digest(destination)
                records.append({"fileName":path.name,"taskID":value.get("taskID"),
                    "sha256":digest(destination),"copy":{"path":str(destination),"sha256":digest(destination)}})
            inventory["directories"][name]=records
        saved=self.evidence/(phase+"-"+label+"-capture-inventory.json");append_json(saved,inventory)
        return {"path":str(saved),"sha256":digest(saved)}
    def _collect(self,phase):
        self._source_guard();path=self.child/(phase+".request.json")
        assert not path.is_symlink() and path.resolve().is_relative_to(self.artifacts)
        request_hash=digest(path);request=json.loads(path.read_text())
        assert set(request)=={"schemaVersion","phase","nonce","sourceSHA","simulator","owner","generation","taskID","title","appTerminatedRequired"}
        assert request["schemaVersion"]==1 and request["phase"]==phase
        assert request["sourceSHA"]==self.source_sha and request["simulator"]==self.device
        uuid.UUID(request["nonce"]);uuid.UUID(request["taskID"])
        assert request["appTerminatedRequired"] is True and re.fullmatch(r"[A-Za-z0-9_-]{10,80}",request["owner"])
        assert isinstance(request["generation"],str) and 0<len(request["generation"].encode())<=128
        assert not any(x<32 or x==127 for x in request["generation"].encode())
        assert re.fullmatch(r"(Account share|Held share) [0-9A-Fa-f]{8}",request["title"])
        assert all(r["request"]["nonce"]!=request["nonce"] for r in self.records)
        if self.records:
            first=self.records[0]["request"]
            assert (request["owner"],request["generation"])==(first["owner"],first["generation"])
        started=now();app_before=self._app_stopped()
        group=self.database.owned_group_container(self.device,"com.itorah.gsd",self.environment)
        publication_path=group/"share-scope-publication.json";identity_path=group/"watch-dataset-identity.json"
        assert not publication_path.is_symlink() and not identity_path.is_symlink()
        publication=json.loads(publication_path.read_text());identity=json.loads(identity_path.read_text())
        origin=publication["scope"]
        assert publication["version"]==1 and origin["kind"]=="account" and origin["identifier"]==request["owner"]
        assert origin["datasetID"]==identity["datasetID"]
        scope={key:origin[key] for key in ["kind","identifier","datasetID"]}
        if self.records:assert scope==self.records[0]["ack"]["scope"]
        snapshot,before_ref=self._snapshot(group,phase,"before")
        captures_before=self._capture_inventory(group,phase,"before")
        task_id=request["taskID"]
        ack={key:request[key] for key in ["schemaVersion","phase","nonce","sourceSHA","simulator","owner","generation","taskID"]}
        ack.update(scope=scope,sqlWrites=0)
        extra={}
        if phase.startswith("seed-"):
            self._absent(snapshot,task_id);assert not self._pending(group,task_id) and not self._inflight(group,task_id)
            if phase=="seed-current":
                assert not self.database.decoded_rows(snapshot,"tasks"),"Fresh owned account must start without canonical tasks"
            else:
                assert task_id!=self.records[0]["request"]["taskID"]
            command=[str(self.binary),str(group),str(path)]
            run=subprocess.run(command,capture_output=True,text=True,env=self.environment,
                               timeout=30,start_new_session=True)
            (self.evidence/(phase+".producer.stdout")).write_text(run.stdout)
            (self.evidence/(phase+".producer.stderr")).write_text(run.stderr)
            assert run.returncode==0,"Real GSDSnapshot pending producer failed"
            producer=json.loads(run.stdout)
            assert producer["schemaVersion"]==1 and producer["realShareOutboxStore"] is True
            assert producer["sqlWrites"]==0 and producer["cloudRequests"]==0
            assert (producer["owner"],producer["taskID"],producer["generation"],producer["scope"])==(request["owner"],task_id,request["generation"],scope)
            pending=self._pending(group,task_id);assert len(pending)==1
            capture_path,capture=pending[0]
            assert capture["title"]==request["title"] and capture["origin"]==origin
            assert capture["serverDatasetGeneration"].encode()==request["generation"].encode()
            assert capture.get("remoteRecordID") is None and capture["taskID"]==task_id
            copy=self.evidence/(phase+".pending-capture.json");copy.write_bytes(capture_path.read_bytes());copy.chmod(0o600)
            self.pending[task_id]={"sha256":digest(capture_path),"scope":scope,"title":request["title"],"path":str(capture_path)}
            after,after_ref=self._snapshot(group,phase,"after")
            assert after["logicalSHA256"]==snapshot["logicalSHA256"],"Fixture producer must not write SQLite"
            ack.update(canonicalTaskAbsent=True,pendingCaptureWrittenByRealProducer=True,pendingCaptureSHA256=digest(capture_path))
            extra.update(producerCommand=command,producerExit=run.returncode,producer=producer,
                         producerStdout={"path":str(self.evidence/(phase+".producer.stdout")),"sha256":digest(self.evidence/(phase+".producer.stdout"))},
                         producerStderr={"path":str(self.evidence/(phase+".producer.stderr")),"sha256":digest(self.evidence/(phase+".producer.stderr"))},
                         pendingCaptureCopy={"path":str(copy),"sha256":digest(copy)},databaseAfter=after_ref)
        elif phase=="verify-applied":
            assert task_id==self.records[0]["request"]["taskID"]
            rows=[r for r in self.database.decoded_rows(snapshot,"tasks") if r["id"]==task_id]
            assert len(rows)==1 and rows[0]["title"]==request["title"]
            assert not self._pending(group,task_id) and not self._inflight(group,task_id)
            ack.update(canonicalTaskMatches=True,pendingCaptureAbsent=True,inFlightCaptureAbsent=True)
        else:
            assert task_id==self.records[2]["request"]["taskID"]
            self._absent(snapshot,task_id)
            pending=self._pending(group,task_id);assert len(pending)==1
            capture_path,capture=pending[0];record=self.pending[task_id]
            assert digest(capture_path)==record["sha256"]
            assert capture["title"]==request["title"] and capture["origin"]==origin
            assert capture["serverDatasetGeneration"].encode()==request["generation"].encode()
            ack.update(canonicalTaskAbsent=True,syncMutationAbsent=True,pendingCaptureByteIdentical=True,
                       pendingCaptureSHA256=digest(capture_path))
        captures_after=self._capture_inventory(group,phase,"after")
        self._source_guard();app_after=self._app_stopped();assert digest(path)==request_hash
        ack.update(captureComplete=True,appTerminatedVerified=True,databaseSnapshot=before_ref,capturedUTC=now())
        copied_request=self.evidence/(phase+".request.json");append_json(copied_request,request)
        ack_path=self.child/(phase+".ack.json");append_json(ack_path,ack)
        record={"phase":phase,"startedUTC":started,"finishedUTC":now(),"request":request,
                "requestPath":str(path),"requestSHA256":request_hash,
                "requestCopy":{"path":str(copied_request),"sha256":digest(copied_request)},
                "databaseBefore":before_ref,"captureInventoryBefore":captures_before,"captureInventoryAfter":captures_after,
                "appBefore":app_before,"appAfter":app_after,
                "ack":ack,"ackPath":str(ack_path),"ackSHA256":digest(ack_path),**extra}
        self.records.append(record);append_json(self.evidence/(phase+".observer-receipt.json"),record)
    def _run(self):
        try:
            while not self.stop.wait(0.2):
                if self.child.exists():
                    assert not self.child.is_symlink() and self.child.resolve().is_relative_to(self.artifacts)
                    if len(self.records)<len(PHASES):
                        phase=PHASES[len(self.records)]
                        assert not any((self.child/(p+".request.json")).exists() for p in PHASES[len(self.records)+1:]),"Checkpoint sequence changed"
                        if (self.child/(phase+".request.json")).is_file():self._collect(phase)
        except BaseException as error:
            self.errors.append({"type":type(error).__name__,"message":str(error),"atUTC":now()})
            append_json(self.evidence/"observer-error.json",self.errors[-1])
    def close(self):
        if self.closed:return
        self.stop.set();self.thread.join(timeout=40)
        assert not self.thread.is_alive(),"Owned Share observer did not stop"
        self.closed=True;append_json(self.evidence/"observer-summary.json",self.summary())
    def summary(self):
        return {"schemaVersion":1,"sourceSHA":self.source_sha,"simulator":self.device,"closed":self.closed,
                "phases":[r["phase"] for r in self.records],"errors":self.errors,
                "sqlWrites":0,"seederContract":{"path":str(self.contract_path),"sha256":self.contract_sha},
                "records":[{"path":str(self.evidence/(r["phase"]+".observer-receipt.json")),
                            "sha256":digest(self.evidence/(r["phase"]+".observer-receipt.json"))} for r in self.records]}
    def validate(self):
        assert self.closed and not self.errors and [r["phase"] for r in self.records]==PHASES
        self._source_guard()
        return {"passed":True,**self.summary()}
