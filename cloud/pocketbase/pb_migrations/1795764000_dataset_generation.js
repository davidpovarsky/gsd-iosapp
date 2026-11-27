// Private metadata only: existing account, task and library rows are unchanged.
migrate((app) => {
  const users = app.findCollectionByNameOrId("users");
  const common = () => [
    {type:"autodate", name:"created", onCreate:true, onUpdate:false},
    {type:"autodate", name:"updated", onCreate:true, onUpdate:true},
    {type:"relation", name:"owner", collectionId:users.id, maxSelect:1, required:true, cascadeDelete:true}
  ];
  app.save(new Collection({
    name:"gsd_dataset_state", type:"base",
    listRule:null, viewRule:null, createRule:null, updateRule:null, deleteRule:null,
    fields:common().concat([{type:"text", name:"generation", required:true, max:128}]),
    indexes:["CREATE UNIQUE INDEX idx_gsd_dataset_state_owner ON gsd_dataset_state (owner)"]
  }));
  app.save(new Collection({
    name:"gsd_dataset_resets", type:"base",
    listRule:null, viewRule:null, createRule:null, updateRule:null, deleteRule:null,
    fields:common().concat([
      {type:"text", name:"request_id", required:true, max:128},
      {type:"text", name:"expected_generation", required:true, max:128},
      {type:"text", name:"receipt", required:true, max:8192}
    ]),
    indexes:["CREATE UNIQUE INDEX idx_gsd_dataset_resets_owner_request ON gsd_dataset_resets (owner,request_id)"]
  }));
}, () => { /* Preserve generations and idempotent receipts on rollback. */ });
