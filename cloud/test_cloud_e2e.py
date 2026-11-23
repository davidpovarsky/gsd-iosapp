#!/usr/bin/env python3
"""Black-box GSD account, native wire and OAuth/MCP acceptance; no credentials logged."""
import base64, hashlib, json, os, secrets, urllib.parse, urllib.request, urllib.error
BASE = os.environ.get("GSD_TEST_BASE", "https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud").rstrip("/")
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl): return None
opener = urllib.request.build_opener(NoRedirect)
def request(method, path, body=None, token=None, form=False, expect=200):
    headers={"Accept":"application/json"}
    if token: headers["Authorization"]="Bearer "+token
    if body is not None:
        headers["Content-Type"]="application/x-www-form-urlencoded" if form else "application/json"
        data=(urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
    else: data=None
    req=urllib.request.Request(BASE+path,data=data,headers=headers,method=method)
    try:
        with opener.open(req,timeout=25) as r: status, text, hs=r.status,r.read().decode(),dict(r.headers)
    except urllib.error.HTTPError as e:
        status,text,hs=e.code,e.read().decode(),dict(e.headers)
    if status not in (expect if isinstance(expect,tuple) else (expect,)):
        raise AssertionError(f"{method} {path.split('?')[0]}: expected {expect}; got {status}")
    try: result=json.loads(text) if text else {}
    except json.JSONDecodeError: result=text
    return result,hs
checks=[]
def passed(name):
    checks.append(name)
    print("PASS",name,flush=True)
def oauth(account,scopes="gsd.read gsd.write offline_access"):
    callback="http://127.0.0.1:8765/callback"
    c,_=request("POST","/oauth/register",{"redirect_uris":[callback],"client_name":"GSD acceptance"},expect=201)
    verifier=secrets.token_urlsafe(40)
    challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    query=urllib.parse.urlencode({"client_id":c["client_id"],"redirect_uri":callback,
        "response_type":"code","code_challenge":challenge,"code_challenge_method":"S256",
        "scope":scopes,"state":"gsd-acceptance-state","resource":BASE+"/mcp"})
    page,_=request("GET","/oauth/authorize?"+query)
    import re
    rid=re.search(r'name="request" value="([^"]+)"',page).group(1)
    assert "קוד צימוד" in page
    _,headers=request("POST","/oauth/login",{"request":rid,"email":account["email"],
       "password":account["password"]},form=True,expect=302)
    location=headers.get("Location") or headers.get("location")
    q=urllib.parse.parse_qs(urllib.parse.urlsplit(location).query)
    assert q["state"]==["gsd-acceptance-state"]
    fields={"grant_type":"authorization_code","client_id":c["client_id"],
      "redirect_uri":callback,"code":q["code"][0],"code_verifier":verifier,"resource":BASE+"/mcp"}
    request("POST","/oauth/token",{**fields,"code_verifier":secrets.token_urlsafe(40)},form=True,expect=400)
    grant,_=request("POST","/oauth/token",fields,form=True)
    request("POST","/oauth/token",fields,form=True,expect=400)
    return {**grant,"client_id":c["client_id"]}
def tool(grant,name,args=None,error=False):
    payload,_=request("POST","/mcp",{"jsonrpc":"2.0","id":secrets.token_hex(3),"method":"tools/call",
       "params":{"name":name,"arguments":args or {}}},token=grant["access_token"])
    result=payload["result"]
    if error:
        assert result.get("isError"),name+" should fail"
        return result
    assert not result.get("isError"),name+" returned tool error: "+str(result.get("content"))[:180]
    data=json.loads(result["content"][0]["text"])
    assert "unavailable" not in data, name+" is a placeholder"
    return data
accounts=[]
tag=secrets.token_hex(7)
try:
    for suffix in ("a","b"):
        email=f"gsd-e2e-{tag}-{suffix}@example.invalid"; password=secrets.token_urlsafe(22)+"A2!"
        record,_=request("POST","/api/collections/users/records",
            {"email":email,"password":password,"passwordConfirm":password},expect=(200,201))
        auth,_=request("POST","/api/collections/users/auth-with-password",{"identity":email,"password":password})
        accounts.append({**auth,"email":email,"password":password})
    a,b=accounts
    passed("two_email_accounts")
    stamp="2026-11-23T20:00:00.000Z"
    task,_=request("POST","/api/collections/tasks/records",{
        "id":"","owner":a["record"]["id"],"task_id":"native-"+tag,"title":"Native wire fixture",
        "urgent":False,"important":True,"quadrant":"notUrgentImportant","due_date":"",
        "completed":False,"completed_at":"","recurrence":"none","tags":[],"subtasks":[],
        "dependencies":[],"notification_enabled":True,"notification_sent":False,"notify_before":0,
        "last_notification_at":"","estimated_minutes":25,"time_spent":0,"time_entries":[],
        "snoozed_until":"","client_updated_at":stamp,"client_created_at":stamp,
        "device_id":"gsd-native-fixture","saved_at":"","focus_date":"","focus_rank":0
    },token=a["token"],expect=(200,201))
    update={k:v for k,v in task.items() if k not in ("id","created","updated","collectionId","collectionName","expand")}
    update["title"]="Native guarded update"
    update["client_updated_at"]="2026-11-23T20:00:01.000Z"
    request("PATCH","/api/gsd/tasks/"+task["id"],{"expected_version":stamp,"data":update},token=a["token"],expect=204)
    request("PATCH","/api/gsd/tasks/"+task["id"],{"expected_version":stamp,"data":update},token=a["token"],expect=412)
    request("GET","/api/collections/tasks/records/"+task["id"],token=b["token"],expect=(403,404))
    request("PATCH","/api/gsd/tasks/"+task["id"],{"expected_version":update["client_updated_at"],
        "data":{**update,"owner":b["record"]["id"]}},token=a["token"],expect=(400,403,404))
    passed("native_wire_guarded_update_stale_conflict_and_owner_immutability")
    ga,gb=oauth(a),oauth(b)
    passed("oauth_pkce_login_two_accounts_single_use_codes")
    listing,_=request("POST","/mcp",{"jsonrpc":"2.0","id":1,"method":"tools/list"},token=ga["access_token"])
    assert len(listing["result"]["tools"])==22
    tool(gb,"get_task",{"id":task["task_id"]},error=True)
    assert len(tool(gb,"list_tasks")["tasks"])==0
    passed("mcp_22_catalog_and_cross_account_isolation")
    created=tool(ga,"create_task",{"title":"Created while native app closed","important":False,"urgent":True,"tags":["cloud"],"estimate_minutes":10})
    tid=created["taskId"]
    read=tool(ga,"get_task",{"id":tid})["task"]
    assert read["title"]=="Created while native app closed"
    assert read["urgent"] and not read["important"]
    assert tool(ga,"list_tasks",{"query":"native app closed"})["total"]==1
    assert "cloud" in tool(ga,"list_tags")["tags"]
    tool(ga,"update_task",{"id":tid,"title":"Updated by MCP","due_at":"2026-12-01T09:00:00Z","clear_due":False})
    tool(ga,"set_completed",{"id":tid,"completed":True})
    assert tool(ga,"get_task",{"id":tid})["task"]["completed"]
    tool(ga,"set_completed",{"id":tid,"completed":False})
    tool(ga,"add_subtask",{"id":tid,"title":"subtask"})
    sub=tool(ga,"get_task",{"id":tid})["task"]["subtasks"][0]["id"]
    tool(ga,"toggle_subtask",{"id":tid,"subtask_id":sub})
    assert tool(ga,"get_task",{"id":tid})["task"]["subtasks"][0]["completed"]
    other=tool(ga,"create_task",{"title":"Dependency"})["taskId"]
    tool(ga,"add_dependency",{"id":tid,"dependency_id":other})
    tool(ga,"add_dependency",{"id":other,"dependency_id":tid},error=True)
    tool(ga,"remove_dependency",{"id":tid,"dependency_id":other})
    tool(ga,"set_focus",{"id":tid,"date":"2026-12-01","rank":1})
    tool(ga,"bulk_add_tags",{"ids":[tid,other],"tags":["batch"]})
    tool(ga,"bulk_move",{"ids":[tid,other],"quadrant":"schedule"})
    timer=tool(ga,"start_timer",{"id":tid})
    assert timer.get("started") is True
    tool(ga,"start_timer",{"id":tid},error=True)
    stopped=tool(ga,"stop_timer",{"id":tid,"notes":"Remote timer retained"})
    assert stopped.get("stopped") is True
    after=tool(ga,"get_task",{"id":tid})["task"]
    assert after["time_entries"][-1]["endedAt"] and after["time_entries"][-1]["notes"]=="Remote timer retained"
    tool(ga,"bulk_complete",{"ids":[tid,other]})
    assert tool(ga,"get_dashboard")["completed"]>=2
    for name in ("list_saved_tasks","list_archived_tasks","list_trashed_tasks","list_smart_views"): tool(ga,name)
    tool(ga,"delete_task",{"id":tid})
    tool(ga,"get_task",{"id":tid},error=True)
    trashed=tool(ga,"list_trashed_tasks")
    assert any((t.get("task_id") or t.get("id"))==tid for t in trashed["tasks"])
    passed("all_22_tools_real_read_write_timer_soft_delete")
    # Native archive/custom-view wire uses the existing domain backup shape.
    import datetime
    instant=datetime.datetime.now(datetime.timezone.utc)
    library_stamp=instant.isoformat(timespec="milliseconds").replace("+00:00","Z")
    millis=int(instant.timestamp()*1000)
    archive_payload={"id":task["task_id"],"title":"Native archive payload","urgent":False,"important":True,
        "createdAt":millis,"updatedAt":millis,"timeEntries":[{"id":"archive-timer","startedAt":millis-90000,
        "endedAt":millis,"notes":"Keep rich timer"}]}
    archive_body={"expected_version":"","payload":json.dumps(archive_payload),
        "client_updated_at":library_stamp,"deleted":False}
    request("PUT","/api/gsd/library/archive/"+task["task_id"],archive_body,token=a["token"],expect=204)
    request("GET","/api/collections/tasks/records/"+task["id"],token=a["token"],expect=404)
    assert any(t["id"]==task["task_id"] and t["timeEntries"][0]["notes"]=="Keep rich timer"
               for t in tool(ga,"list_archived_tasks")["tasks"])
    view_id="view-"+tag
    view={"id":view_id,"name":"Cloud custom view","icon":"cloud","isBuiltIn":False,
          "createdAt":millis,"updatedAt":millis,"criteria":{"tags":["cloud"]}}
    view_body={"expected_version":"","payload":json.dumps(view),"client_updated_at":library_stamp,"deleted":False}
    request("PUT","/api/gsd/library/view/"+view_id,view_body,token=a["token"],expect=204)
    request("PUT","/api/gsd/library/view/"+view_id,view_body,token=a["token"],expect=412)
    assert any(v["id"]==view_id for v in tool(ga,"list_smart_views")["views"])
    assert not any(v["id"]==view_id for v in tool(gb,"list_smart_views")["views"])
    later=(instant+datetime.timedelta(milliseconds=1)).isoformat(timespec="milliseconds").replace("+00:00","Z")
    request("PUT","/api/gsd/library/view/"+view_id,{"expected_version":library_stamp,"payload":"",
        "client_updated_at":later,"deleted":True},token=a["token"],expect=204)
    assert not any(v["id"]==view_id for v in tool(ga,"list_smart_views")["views"])
    passed("native_archive_view_tombstones_version_conflicts_and_account_isolation")
    recurring=tool(ga,"create_task",{"title":"Monthly recurrence"})["taskId"]
    rows,_=request("GET","/api/collections/tasks/records?perPage=100",token=a["token"])
    row=next(t for t in rows["items"] if t["task_id"]==recurring)
    request("PATCH","/api/gsd/tasks/"+row["id"],{"expected_version":row["client_updated_at"],
       "data":{"recurrence":"monthly","due_date":"2027-01-31T09:00:00Z","client_updated_at":later}},
       token=a["token"],expect=204)
    tool(ga,"set_completed",{"id":recurring,"completed":True})
    tool(ga,"set_completed",{"id":recurring,"completed":True})
    recurrence_tasks=tool(ga,"list_tasks",{"query":"Monthly recurrence"})["tasks"]
    assert len(recurrence_tasks)==2
    next_task=next(t for t in recurrence_tasks if not t["completed"])
    assert next_task["due_date"].startswith("2027-02-28T09:00:00")
    passed("recurrence_month_end_and_idempotent_completion")
    readOnly=oauth(a,"gsd.read")
    tool(readOnly,"create_task",{"title":"Forbidden"},error=True)
    passed("oauth_read_scope_cannot_write")
    previous=ga["refresh_token"]
    rotated,_=request("POST","/oauth/token",{"grant_type":"refresh_token","client_id":ga["client_id"],"refresh_token":previous},form=True)
    request("POST","/oauth/token",{"grant_type":"refresh_token","client_id":ga["client_id"],"refresh_token":previous},form=True,expect=400)
    ga.update(rotated)
    tool(ga,"get_dashboard")
    request("POST","/oauth/revoke",{"token":ga["refresh_token"],"client_id":ga["client_id"]},form=True,expect=(200,204))
    request("POST","/mcp",{"jsonrpc":"2.0","id":2,"method":"tools/list"},token=ga["access_token"],expect=401)
    passed("refresh_rotation_replay_rejection_and_grant_revocation")
    print(json.dumps({"result":"PASS","checks":checks,"base":BASE},ensure_ascii=False))
finally:
    for account in accounts:
        try: request("DELETE","/api/gsd/account",token=account["token"],expect=(200,204))
        except Exception as e: print("CLEANUP_FAILED",type(e).__name__)
