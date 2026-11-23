#!/usr/bin/env python3
"""Black-box GSD cloud acceptance. Uses ephemeral synthetic accounts only."""
import json, secrets, urllib.request, urllib.error, sys
BASE="http://127.0.0.1:8095"
def request(method,path,body=None,token=None,expect=None):
    data=json.dumps(body).encode() if body is not None else None
    headers={"Accept":"application/json"}
    if data is not None: headers["Content-Type"]="application/json"
    if token:headers["Authorization"]=token
    req=urllib.request.Request(BASE+path,data=data,headers=headers,method=method)
    try:
        with urllib.request.urlopen(req,timeout=14) as result:
            status=result.status
            text=result.read().decode()
    except urllib.error.HTTPError as e:
        status=e.code
        text=e.read().decode()
    payload=json.loads(text) if text else {}
    if expect is not None and status not in (expect if isinstance(expect,tuple) else (expect,)):
        raise AssertionError(f"{method} {path}: expected {expect}, got HTTP {status}: {str(payload)[:600]}")
    return status,payload

tag=secrets.token_hex(5)
accounts=[]
try:
    for n in ("a","b"):
        email=f"gsd-contract-{tag}-{n}@example.invalid"
        password=secrets.token_urlsafe(22)+"Az2!"
        status,user=request("POST","/api/collections/users/records",{
            "email":email,"password":password,"passwordConfirm":password,
            "display_name":"GSD Cloud test"
        },expect=(200,201))
        status,auth=request("POST","/api/collections/users/auth-with-password",{
            "identity":email,"password":password
        },expect=200)
        accounts.append({"id":auth["record"]["id"],"token":auth["token"]})
    a,b=accounts
    print("PASS_TWO_ACCOUNT_AUTH")
    stamp="2026-11-23T16:30:00.000Z"
    _,created=request("POST","/api/collections/tasks/records",{
        "owner":a["id"],"task_id":"contract-"+tag,"title":"A private task",
        "urgent":True,"important":True,"tags":["private"],"subtasks":[],
        "dependencies":[],"time_entries":[],"client_updated_at":stamp,
        "client_created_at":stamp,"device_id":"contract_test_device"
    },a["token"],expect=(200,201))
    rid=created["id"]
    assert created["owner"]==a["id"]
    print("PASS_OWNER_CREATE")
    _,listingA=request("GET","/api/collections/tasks/records?page=1&perPage=20",token=a["token"],expect=200)
    _,listingB=request("GET","/api/collections/tasks/records?page=1&perPage=20",token=b["token"],expect=200)
    assert any(t["id"]==rid for t in listingA["items"])
    assert not any(t["id"]==rid for t in listingB["items"])
    status,_=request("GET",f"/api/collections/tasks/records/{rid}",token=b["token"],expect=(403,404))
    print("PASS_CROSS_USER_TASK_ISOLATION")
    _,changed=request("PATCH",f"/api/gsd/tasks/{rid}",{
        "expected_version":stamp,"data":{"title":"A versioned updated task",
            "client_updated_at":"2026-11-23T16:31:00.000Z"}
    },a["token"],expect=204)
    _,after=request("GET",f"/api/collections/tasks/records/{rid}",token=a["token"],expect=200)
    assert after["title"]=="A versioned updated task"
    status,_=request("PATCH",f"/api/gsd/tasks/{rid}",{
        "expected_version":stamp,"data":{"title":"Stale overwriting attempt"}
    },a["token"],expect=412)
    print("PASS_ATOMIC_GUARDED_VERSION_CONFLICT")
    status,_=request("DELETE",f"/api/gsd/tasks/{rid}",{
        "expected_version":"2026-11-23T16:31:00.000Z"
    },a["token"],expect=204)
    print("PASS_GUARDED_DELETE")
    _,createdB=request("POST","/api/collections/tasks/records",{
        "owner":b["id"],"task_id":"contract-b-"+tag,
        "title":"B is not visible to A","client_updated_at":stamp
    },b["token"],expect=(200,201))
    _,aList=request("GET","/api/collections/tasks/records?page=1&perPage=50",token=a["token"],expect=200)
    assert not any(t["id"]==createdB["id"] for t in aList["items"])
    print("PASS_TWO_WAY_ISOLATION")
finally:
    for account in accounts:
        try:
            status,_=request("DELETE","/api/gsd/account",token=account["token"],expect=(200,204))
            print("CLEANUP_ACCOUNT_OK",account["id"][:5])
        except Exception as e:
            print("CLEANUP_FAILED",type(e).__name__,str(e)[:240],file=sys.stderr)
