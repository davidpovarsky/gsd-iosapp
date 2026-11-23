// Archive, trash and custom smart views complement the existing tasks collection.
migrate((app) => {
  const users=app.findCollectionByNameOrId("users");
  try { app.findCollectionByNameOrId("gsd_library"); return; } catch (_) {}
  app.save(new Collection({
    name:"gsd_library",type:"base",
    listRule:"owner = @request.auth.id && @request.auth.id != ''",
    viewRule:"owner = @request.auth.id && @request.auth.id != ''",
    createRule:null,updateRule:null,deleteRule:null,
    fields:[
      {type:"autodate",name:"created",onCreate:true,onUpdate:false},
      {type:"autodate",name:"updated",onCreate:true,onUpdate:true},
      {type:"relation",name:"owner",collectionId:users.id,maxSelect:1,required:true,cascadeDelete:true},
      {type:"text",name:"kind",required:true,max:16},
      {type:"text",name:"entity_id",required:true,max:160},
      {type:"text",name:"payload",max:1048576},
      {type:"text",name:"client_updated_at",required:true,max:80},
      {type:"bool",name:"deleted"}
    ],
    indexes:["CREATE UNIQUE INDEX idx_gsd_library_owner_kind_id ON gsd_library (owner,kind,entity_id)"]
  }));
},(app)=>{ /* User data remains intact on rollback. */ });
