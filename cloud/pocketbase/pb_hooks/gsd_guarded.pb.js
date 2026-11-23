// GSD guarded write handlers. PocketBase JSVM callbacks execute in isolated runtimes.
routerAdd("PATCH","/api/gsd/tasks/{id}",(e) => {
  const remove = false;
  const auth = e.auth;
  if (!auth || auth.collection().name !== "users") throw new UnauthorizedError();
  const id=e.request.pathValue("id");
  const payload=e.requestInfo().body||{};
  const expected=payload.expected_version;
  if (typeof expected!=="string" || expected.length>100) throw new BadRequestError("expected_version is required");
  const fields=new Set([
    "task_id","title","description","urgent","important","quadrant",
    "due_date","completed","completed_at","recurrence","tags","subtasks",
    "dependencies","notification_enabled","notification_sent","notify_before",
    "last_notification_at","estimated_minutes","time_spent","time_entries",
    "snoozed_until","client_updated_at","client_created_at","device_id",
    "saved_at","focus_date","focus_rank"
  ]);
  const patch=payload.data;
  if (!remove && (!patch||typeof patch!=="object"||Array.isArray(patch))) throw new BadRequestError("Invalid task payload");
  if (!remove)for(const k of Object.keys(patch))if(!fields.has(k))throw new BadRequestError("Field not allowed: "+k);
  e.app.runInTransaction((tx)=>{
    let task;
    try { task=tx.findRecordById("tasks",id); } catch (_) { throw new NotFoundError("Task not found"); }
    if (task.getString("owner")!==auth.id) throw new NotFoundError("Task not found");
    if (task.getString("client_updated_at")!==expected) throw new ApiError(412,"Task version conflict");
    if (remove) { tx.delete(task); return; }
    if (patch.task_id!==undefined && patch.task_id!==task.getString("task_id")) throw new BadRequestError("Immutable task id");
    for(const k of Object.keys(patch))task.set(k,patch[k]);
    tx.save(task);
  });
  return e.noContent(204);
},$apis.requireAuth("users"));
routerAdd("DELETE","/api/gsd/tasks/{id}",(e) => {
  const remove = true;
  const auth = e.auth;
  if (!auth || auth.collection().name !== "users") throw new UnauthorizedError();
  const id=e.request.pathValue("id");
  const payload=e.requestInfo().body||{};
  const expected=payload.expected_version;
  if (typeof expected!=="string" || expected.length>100) throw new BadRequestError("expected_version is required");
  const fields=new Set([
    "task_id","title","description","urgent","important","quadrant",
    "due_date","completed","completed_at","recurrence","tags","subtasks",
    "dependencies","notification_enabled","notification_sent","notify_before",
    "last_notification_at","estimated_minutes","time_spent","time_entries",
    "snoozed_until","client_updated_at","client_created_at","device_id",
    "saved_at","focus_date","focus_rank"
  ]);
  const patch=payload.data;
  if (!remove && (!patch||typeof patch!=="object"||Array.isArray(patch))) throw new BadRequestError("Invalid task payload");
  if (!remove)for(const k of Object.keys(patch))if(!fields.has(k))throw new BadRequestError("Field not allowed: "+k);
  e.app.runInTransaction((tx)=>{
    let task;
    try { task=tx.findRecordById("tasks",id); } catch (_) { throw new NotFoundError("Task not found"); }
    if (task.getString("owner")!==auth.id) throw new NotFoundError("Task not found");
    if (task.getString("client_updated_at")!==expected) throw new ApiError(412,"Task version conflict");
    if (remove) { tx.delete(task); return; }
    if (patch.task_id!==undefined && patch.task_id!==task.getString("task_id")) throw new BadRequestError("Immutable task id");
    for(const k of Object.keys(patch))task.set(k,patch[k]);
    tx.save(task);
  });
  return e.noContent(204);
},$apis.requireAuth("users"));

routerAdd("DELETE","/api/gsd/account",(e)=>{
  if(!e.auth||e.auth.collection().name!=="users")throw new UnauthorizedError();
  e.app.delete(e.auth);
  return e.noContent(204);
},$apis.requireAuth("users"));
