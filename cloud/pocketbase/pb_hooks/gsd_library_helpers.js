function domainTask(row) {
  const stamp=v=>v&&Number.isFinite(Date.parse(v))?Date.parse(v):null;
  const out={id:row.task_id,title:row.title,description:row.description||'',
    urgent:!!row.urgent,important:!!row.important,completed:!!row.completed,
    createdAt:stamp(row.client_created_at)||0,updatedAt:stamp(row.client_updated_at)||0,
    recurrence:row.recurrence||'none',tags:row.tags||[],subtasks:row.subtasks||[],
    dependencies:row.dependencies||[],notificationEnabled:row.notification_enabled!==false,
    notificationSent:!!row.notification_sent,notifyBefore:row.notify_before||0,
    estimatedMinutes:row.estimated_minutes||0,timeSpent:row.time_spent||0,
    timeEntries:(row.time_entries||[]).map(t=>{
      const started=stamp(t.startedAt)||0;
      const result={id:t.id,startedAt:started};
      if(t.endedAt===undefined)result.endedAt=started+(t.minutes||0)*60000;
      else if(t.endedAt)result.endedAt=stamp(t.endedAt);
      if(t.notes)result.notes=t.notes;
      return result;
    })};
  for(const [from,to] of [['completed_at','completedAt'],['due_date','dueDate'],
    ['saved_at','savedAt'],['last_notification_at','lastNotificationAt'],['snoozed_until','snoozedUntil']]){
    const value=stamp(row[from]);if(value!==null)out[to]=value;
  }
  if(row.focus_date&&row.focus_rank){out.focusDate=row.focus_date;out.focusRank=row.focus_rank;}
  return out;
}
function find(app, owner,kind,id) {
  try{return app.findFirstRecordByFilter("gsd_library","owner={:owner} && kind={:kind} && entity_id={:id}",{owner,kind,id});}
  catch(_){return null;}
}
function save(app,owner,kind,id,payload,version,deleted,expected) {
  let record=find(app,owner,kind,id);
  if(expected!==undefined && (record?record.getString("client_updated_at"):"")!==expected)
    throw new ApiError(412,"Library version conflict");
  if(!record){record=new Record(app.findCollectionByNameOrId("gsd_library"));
    record.set("owner",owner);record.set("kind",kind);record.set("entity_id",id);}
  record.set("payload",payload);record.set("client_updated_at",version);record.set("deleted",!!deleted);
  app.save(record);
  return record;
}
module.exports={domainTask,find,save};
