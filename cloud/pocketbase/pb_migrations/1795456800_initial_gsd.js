// First-party GSD PocketBase 0.40 schema. Own account, owner-scoped tasks.
migrate((app) => {
  let users;
  try { users = app.findCollectionByNameOrId("users"); }
  catch (_) {
    users = new Collection({
      name:"users",type:"auth",
      listRule:"id = @request.auth.id",viewRule:"id = @request.auth.id",
      createRule:"",updateRule:"id = @request.auth.id",deleteRule:"id = @request.auth.id",
      passwordAuth:{enabled:true,identityFields:["email"]},
      fields:[{type:"text",name:"display_name",max:160}]
    });
    app.save(users);
  }
  try { app.findCollectionByNameOrId("tasks"); return; } catch (_) {}
  const tx=(name,max=10000)=>({type:"text",name,max});
  const bo=name=>({type:"bool",name});
  const j=name=>({type:"json",name,maxSize:1048576});
  const nu=name=>({type:"number",name});
  app.save(new Collection({
    name:"tasks",type:"base",
    listRule:"owner = @request.auth.id && @request.auth.id != ''",
    viewRule:"owner = @request.auth.id && @request.auth.id != ''",
    createRule:"@request.auth.id != '' && @request.body.owner = @request.auth.id",
    updateRule:"owner = @request.auth.id && @request.auth.id != '' && @request.body.owner:changed = false",
    deleteRule:"owner = @request.auth.id && @request.auth.id != ''",
    fields:[
      {type:"autodate",name:"created",onCreate:true,onUpdate:false},
      {type:"autodate",name:"updated",onCreate:true,onUpdate:true},
      {type:"relation",name:"owner",collectionId:users.id,maxSelect:1,required:true,cascadeDelete:true},
      {type:"text",name:"task_id",max:160,required:true},
      tx("title",500),tx("description",16000),bo("urgent"),bo("important"),tx("quadrant",64),
      tx("due_date",80),bo("completed"),tx("completed_at",80),tx("recurrence",120),
      j("tags"),j("subtasks"),j("dependencies"),bo("notification_enabled"),
      bo("notification_sent"),nu("notify_before"),tx("last_notification_at",80),
      nu("estimated_minutes"),nu("time_spent"),j("time_entries"),tx("snoozed_until",80),
      tx("client_updated_at",80),tx("client_created_at",80),tx("device_id",160),
      tx("saved_at",80),tx("focus_date",80),nu("focus_rank")
    ],
    indexes:[
      "CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_owner_task_id ON tasks (owner,task_id)",
      "CREATE INDEX IF NOT EXISTS idx_tasks_owner_updated ON tasks (owner,updated)"
    ]
  }));
},(app)=>{ /* Never drop or erase production task collections on rollback. */ });
