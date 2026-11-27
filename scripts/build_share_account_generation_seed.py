#!/usr/bin/env python3
"""Compile and preserve the real GSDSnapshot pending-capture fixture on the Apple runner."""
from __future__ import annotations
import argparse,datetime,hashlib,importlib.util,json,os,pathlib,platform,shutil,subprocess,sys,uuid
sys.dont_write_bytecode=True
P=pathlib.Path
GROUP_SHA="fcd0a9bb6465554381f7b62b816e028dda6ff707dead474a01d09b238d7a3896"
FIXTURE="Acceptance/ShareAccountGeneration/SeedPendingCapture.swift"
def digest(p):return hashlib.sha256(P(p).read_bytes()).hexdigest()
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def write(p,value):
    temporary=p.with_name(p.name+"."+uuid.uuid4().hex+".tmp")
    temporary.write_text(json.dumps(value,indent=2,sort_keys=True)+"\n");temporary.chmod(0o600);os.replace(temporary,p)
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--source",type=P,required=True);p.add_argument("--sha",required=True)
    p.add_argument("--scratch",type=P,required=True);p.add_argument("--output",type=P,required=True)
    p.add_argument("--group-helper",type=P,required=True);a=p.parse_args()
    source=a.source.resolve();scratch=a.scratch.resolve();out=a.output.resolve()
    assert platform.system()=="Darwin" and scratch.is_dir() and not out.exists()
    assert digest(a.group_helper)==GROUP_SHA
    spec=importlib.util.spec_from_file_location("share_seed_owned_group",a.group_helper)
    group=importlib.util.module_from_spec(spec);spec.loader.exec_module(group)
    env=dict(os.environ,DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer",PYTHONDONTWRITEBYTECODE="1")
    def git(*args):return subprocess.check_output(["git","-C",str(source),*args],text=True,env=env,timeout=30).strip()
    assert git("rev-parse","HEAD")==a.sha and not git("status","--porcelain")
    def inputs():
        names={p.relative_to(source).as_posix() for p in (source/"GSDKit/Sources").rglob("*") if p.is_file()}
        names|={"GSDKit/Package.swift","GSDKit/Package.resolved",FIXTURE,"scripts/build_share_account_generation_seed.py"}
        assert all(not (source/n).is_symlink() for n in names)
        return {n:digest(source/n) for n in sorted(names)}
    before=inputs();out.mkdir(parents=True,mode=0o700)
    state={"schemaVersion":1,"kind":"real-GSDSnapshot-native-fixture-producer","sourceSHA":a.sha,"sourceRoot":str(source),
           "platform":platform.system(),"productName":"ShareAccountGenerationSeed","passed":False,"nativeAppAcceptance":False,
           "startedUTC":now(),"controllerSHA256":digest(__file__),"inputs":before,"phases":[]}
    receipt=out/"receipt.json";lock=scratch/".gsd-focused-native-owner.json"
    nonce=uuid.uuid4().hex;owner={"pid":os.getpid(),"nonce":nonce,"sourceSHA":a.sha,"output":str(out),"kind":"account-share-seeder"}
    acquired=False;owner_written=False;quiescent=True;proc=None
    def run(label,command,timeout):
        nonlocal quiescent,proc
        log=out/(label+".log");phase={"label":label,"command":command,"startedUTC":now(),"log":str(log)}
        state["phases"].append(phase);write(receipt,state)
        with log.open("x") as stream:
            proc=subprocess.Popen(command,env=env,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
            quiescent=False;phase["pid"]=proc.pid;phase["pgid"]=proc.pid;write(receipt,state)
            try:code=proc.wait(timeout=timeout)
            finally:phase["ownedGroupCleanup"]=group.ensure_quiescent(proc.pid);quiescent=True
        phase.update(exit=code,finishedUTC=now(),logSHA256=digest(log));write(receipt,state)
        assert code==0,label+" failed; original log preserved"
        return log
    try:
        descriptor=os.open(lock,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600);acquired=True
        with os.fdopen(descriptor,"w") as f:
            json.dump(owner,f);f.flush();os.fsync(f.fileno())
        owner_written=True
        package=out/"package";target=package/"Sources/ShareAccountGenerationSeed";target.mkdir(parents=True)
        shutil.copy2(source/FIXTURE,target/"SeedPendingCapture.swift")
        text='''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "GSDShareAccountGenerationFixture", platforms: [.macOS(.v26)],
    dependencies: [.package(path: SOURCE)],
    targets: [.executableTarget(name: "ShareAccountGenerationSeed",
        dependencies: [.product(name: "GSDSnapshot", package: "GSDKit")])])
'''
        (package/"Package.swift").write_text(text.replace("SOURCE",json.dumps(str(source/"GSDKit"))))
        shutil.copy2(source/"GSDKit/Package.resolved",package/"Package.resolved")
        package_before={x.relative_to(package).as_posix():digest(x) for x in package.rglob("*") if x.is_file()}
        state["packageInputs"]=package_before
        xcode=subprocess.check_output(["xcodebuild","-version"],text=True,env=env,timeout=30).strip()
        assert xcode=="Xcode 27.0\nBuild version 27A266a"
        state["compilerVersion"]=xcode;state["compilerDeveloperDir"]=env["DEVELOPER_DIR"]
        jobs=os.cpu_count()
        assert isinstance(jobs,int) and jobs>0,"Useful native CPU count is unavailable"
        swift=P(subprocess.check_output(["xcrun","--find","swift"],text=True,env=env,timeout=30).strip())
        resolved_swift=swift.resolve();developer=P(env["DEVELOPER_DIR"]).resolve()
        assert swift.is_absolute() and swift.is_file() and resolved_swift.is_relative_to(developer)
        swift_version=subprocess.check_output([str(swift),"--version"],text=True,env=env,timeout=30).strip()
        assert "Swift version" in swift_version
        state["buildParallelism"]={"jobs":jobs,"measuredCPUCount":jobs,"measurement":"os.cpu_count()"}
        state["swiftCompiler"]={"path":str(swift),"resolvedPath":str(resolved_swift),"sha256":digest(swift),
            "version":swift_version,"selectionCommand":["xcrun","--find","swift"],
            "versionCommand":[str(swift),"--version"],"checkedUTC":now()}
        command=[str(swift),"build","--package-path",str(package),"--scratch-path",str(scratch),"-j",str(jobs),"--product","ShareAccountGenerationSeed"]
        run("build",command,900)
        paths=run("show-bin-path",[str(swift),"build","--package-path",str(package),"--scratch-path",str(scratch),"--show-bin-path"],120)
        binary=P(paths.read_text().strip())/"ShareAccountGenerationSeed"
        assert binary.is_file() and binary.resolve().is_relative_to(scratch)
        preserved=out/"products";preserved.mkdir()
        shutil.copy2(binary,preserved/binary.name)
        for resource in binary.parent.glob("*.bundle"):shutil.copytree(resource,preserved/resource.name)
        product=preserved/binary.name
        assert product.read_bytes()[:4] in {bytes.fromhex("cffaedfe"),bytes.fromhex("cafebabe")}
        libraries=subprocess.check_output(["otool","-L",str(product)],text=True,timeout=30)
        (out/"linked-libraries.log").write_text(libraries)
        linked=[line.strip().split(" (",1)[0] for line in libraries.splitlines()[1:] if line.strip()]
        assert linked and all(x.startswith(("/System/Library/","/usr/lib/")) for x in linked)
        pins=json.loads((source/"GSDKit/Package.resolved").read_text())["pins"]
        assert json.loads((package/"Package.resolved").read_text())["pins"]==pins
        deps=[]
        for pin in pins:
            assert pin["identity"]=="grdb.swift"
            checkout=scratch/"checkouts/GRDB.swift"
            head=subprocess.check_output(["git","-C",str(checkout),"rev-parse","HEAD"],text=True,timeout=30).strip()
            assert head==pin["state"]["revision"] and not subprocess.check_output(["git","-C",str(checkout),"status","--porcelain"],timeout=30)
            deps.append({"identity":pin["identity"],"revision":head})
        assert inputs()==before and git("rev-parse","HEAD")==a.sha and not git("status","--porcelain")
        assert {n:digest(package/n) for n in package_before if n!="Package.resolved"}=={n:h for n,h in package_before.items() if n!="Package.resolved"}
        state["packageInputsAfter"]={n:digest(package/n) for n in package_before}
        assert digest(__file__)==state["controllerSHA256"] and digest(swift)==state["swiftCompiler"]["sha256"]
        state.update(passed=True,sourceInputsUnchanged=True,dependencies=deps,product={"path":str(product),"sha256":digest(product)},
                     preservedProductFiles={x.relative_to(preserved).as_posix():digest(x) for x in preserved.rglob("*") if x.is_file()},
                     linkedLibraries=linked,linkedLibraryLog={"path":str(out/"linked-libraries.log"),"sha256":digest(out/"linked-libraries.log")})
    except BaseException as error:
        state.update(passed=False,errorType=type(error).__name__,error=str(error))
    finally:
        if proc is not None and not quiescent:
            try:state["finalOwnedGroupCleanup"]=group.ensure_quiescent(proc.pid);quiescent=True
            except BaseException as error:state.update(passed=False,cleanupError=str(error))
        if acquired and quiescent and owner_written:
            try:
                assert json.loads(lock.read_text())==owner;lock.unlink();state["cacheOwnerReleased"]=True
            except BaseException as error:
                state.update(passed=False,cacheOwnerReleased=False,ownerRetained=True,ownerReleaseError=str(error))
        elif acquired:state.update(passed=False,cacheOwnerReleased=False,ownerRetained=True)
        state["finishedUTC"]=now();write(receipt,state)
        print(json.dumps({"passed":state["passed"],"receipt":str(receipt),"sha256":digest(receipt),"error":state.get("error")}))
    return 0 if state["passed"] else 1
if __name__=="__main__":raise SystemExit(main())
