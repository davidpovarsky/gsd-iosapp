// Version checks and writes share one SQLite transaction.
routerAdd("PATCH","/api/gsd/tasks/{id}",(e)=>{
  const auth=e.auth, body=e.requestInfo().body||{}, patch=body.data;
  if(!auth||auth.collection().name!=="users")throw new UnauthorizedError();
  if(typeof body.expected_version!=="string"||body.expected_version.length>100||
    !patch||typeof patch!=="object"||Array.isArray(patch))throw new BadRequestError("Invalid guarded payload");
  const fields=new Set(["owner","task_id","title","description","urgent","important","quadrant",
    "due_date","completed","completed_at","recurrence","tags","subtasks","dependencies",
    "notification_enabled","notification_sent","notify_before","last_notification_at",
    "estimated_minutes","time_spent","time_entries","snoozed_until","client_updated_at",
    "client_created_at","device_id","saved_at","focus_date","focus_rank"]);
  for(const k of Object.keys(patch))if(!fields.has(k))throw new BadRequestError("Field not allowed: "+k);
  e.app.runInTransaction(tx=>{
    let task;
    try{task=tx.findRecordById("tasks",e.request.pathValue("id"));}catch(_){throw new NotFoundError("Task not found");}
    if(task.getString("owner")!==auth.id)throw new NotFoundError("Task not found");
    if(patch.owner!==undefined&&patch.owner!==auth.id)throw new BadRequestError("Immutable owner");
    if(patch.task_id!==undefined&&patch.task_id!==task.getString("task_id"))throw new BadRequestError("Immutable task id");
    if(task.getString("client_updated_at")!==body.expected_version)throw new ApiError(412,"Task version conflict");
    if(typeof patch.client_updated_at!=="string"||!Number.isFinite(Date.parse(patch.client_updated_at)))
      throw new BadRequestError("Valid client_updated_at is required");
    const wasComplete=task.getBool("completed");
    for(const k of Object.keys(patch))task.set(k,patch[k]);
    tx.save(task);
    if(body.spawn_next){
      if(wasComplete||patch.completed!==true||!["daily","weekly","monthly"].includes(task.getString("recurrence")))
        throw new BadRequestError("Invalid recurrence transition");
      const next=body.spawn_next;
      if(next.owner!==auth.id||next.completed!==false||!next.task_id||next.task_id===task.getString("task_id"))
        throw new BadRequestError("Invalid recurrence task");
      const record=new Record(tx.findCollectionByNameOrId("tasks"));
      for(const k of Object.keys(next))if(fields.has(k))record.set(k,next[k]);
      tx.save(record);
    }
  });
  return e.noContent(204);
},$apis.requireAuth("users"));

routerAdd("DELETE","/api/gsd/tasks/{id}",(e)=>{
  const auth=e.auth,body=e.requestInfo().body||{};
  if(!auth||auth.collection().name!=="users")throw new UnauthorizedError();
  if(typeof body.expected_version!=="string"||body.expected_version.length>100)
    throw new BadRequestError("expected_version is required");
  const kind=body.disposition||"trash";
  if(!["archive","trash","erase"].includes(kind))throw new BadRequestError("Invalid disposition");
  const helper=require(__hooks+"/gsd_library_helpers.js");
  e.app.runInTransaction(tx=>{
    let task;
    try{task=tx.findRecordById("tasks",e.request.pathValue("id"));}catch(_){throw new NotFoundError("Task not found");}
    if(task.getString("owner")!==auth.id)throw new NotFoundError("Task not found");
    if(task.getString("client_updated_at")!==body.expected_version)throw new ApiError(412,"Task version conflict");
    if(kind!=="erase"){
      const stamp=typeof body.deleted_at==="string"&&Number.isFinite(Date.parse(body.deleted_at))
        ? body.deleted_at : new Date().toISOString();
      const prior=helper.find(tx,auth.id,kind,task.getString("task_id"));
      if(!prior||Date.parse(prior.getString("client_updated_at"))<Date.parse(stamp))
        helper.save(tx,auth.id,kind,task.getString("task_id"),
          JSON.stringify(helper.domainTask(task.publicExport())),stamp,false);
    }
    tx.delete(task);
  });
  return e.noContent(204);
},$apis.requireAuth("users"));

routerAdd("PUT","/api/gsd/library/{kind}/{id}",(e)=>{
  const auth=e.auth,body=e.requestInfo().body||{};
  const kind=e.request.pathValue("kind"),id=e.request.pathValue("id");
  if(!["archive","trash","view"].includes(kind)||!id||id.length>160)throw new BadRequestError("Invalid library identity");
  if(typeof body.expected_version!=="string"||typeof body.client_updated_at!=="string"||
    !Number.isFinite(Date.parse(body.client_updated_at))||typeof body.payload!=="string"||
    body.payload.length>1048576||typeof body.deleted!=="boolean")
    throw new BadRequestError("Invalid library payload");
  if(!body.deleted){
    let payload;try{payload=JSON.parse(body.payload);}catch(_){throw new BadRequestError("Invalid JSON payload");}
    if(payload.id!==id)throw new BadRequestError("Mismatched library identity");
  }
  const helper=require(__hooks+"/gsd_library_helpers.js");
  e.app.runInTransaction(tx=>{
    if(kind!=="view"&&!body.deleted){
      let active;
      try{active=tx.findFirstRecordByFilter("tasks","owner={:owner} && task_id={:id}",{owner:auth.id,id});}catch(_){}
      if(active){
        if(Date.parse(active.getString("client_updated_at"))>Date.parse(body.client_updated_at))
          throw new ApiError(412,"A newer task edit exists");
        tx.delete(active);
      }
    }
    helper.save(tx,auth.id,kind,id,body.payload,body.client_updated_at,body.deleted,body.expected_version);
  });
  return e.noContent(204);
},$apis.requireAuth("users"));

routerAdd("DELETE","/api/gsd/account",(e)=>{
  if(!e.auth||e.auth.collection().name!=="users")throw new UnauthorizedError();
  e.app.runInTransaction(tx=>tx.delete(tx.findRecordById("users",e.auth.id)));
  return e.noContent(204);
},$apis.requireAuth("users"));
