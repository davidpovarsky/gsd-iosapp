import {createHash,randomUUID} from 'node:crypto';

const hash=value=>createHash('sha256').update(value).digest('hex');
const canonical=value=>Array.isArray(value)?value.map(canonical):
  value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
const replayTTL=30*24*3600000;
const maxReceipts=50000;
const maxAudit=10000;

export const requestIDSchema={type:'string',minLength:1,maxLength:128,
  description:'Reuse this ID with identical arguments to retry this write safely. Keep the same ID until the outcome is known.'};

// Intent is durable before PocketBase is called. A lost upstream response is
// deliberately not retried: the gateway cannot atomically commit its receipt
// and a transaction in the separate PocketBase process.
export function createRequestLedger({store,save,seal,open,clock=Date.now}) {
  const running=new Map();
  const audit=(account,tool,status,request=null)=>{
    store.audit[randomUUID()]={account,tool,status,request,at:clock()};
    const keys=Object.keys(store.audit);
    for(const key of keys.slice(0,Math.max(0,keys.length-maxAudit)))delete store.audit[key];
  };
  const replay=record=>{
    if(record.status==='pending'||record.status==='uncertain')throw Error('request_reconciliation_required');
    if(record.expires<=clock()) {
      if(record.result){delete record.result;save();}
      throw Error('request_receipt_expired');
    }
    const result=JSON.parse(open(record.result));
    if(!result.ok)throw Object.assign(Error(result.message),{http:result.http});
    return result.value;
  };
  return async function write(accountId,tool,args,execute) {
    const account=hash(accountId), {request_id:requestId,...parameters}=args;
    if(requestId===undefined) {
      audit(account,tool,'started');save();
      try {const result=await execute(parameters);audit(account,tool,'completed');save();return result;}
      catch(error){audit(account,tool,'failed');save();throw error;}
    }
    const key=hash(JSON.stringify([accountId,requestId]));
    const fingerprint=hash(JSON.stringify(canonical({tool,arguments:parameters})));
    const previous=store.receipts[key];
    if(previous) {
      if(previous.fingerprint!==fingerprint)throw Error('request_id_conflict');
      if(running.has(key))return running.get(key);
      return replay(previous);
    }
    if(Object.keys(store.receipts).length>=maxReceipts)throw Error('request_ledger_capacity');
    const record={account,tool,fingerprint,status:'pending',created:clock(),expires:clock()+replayTTL};
    store.receipts[key]=record;
    audit(account,tool,'started',key);
    try{save();}catch(error){delete store.receipts[key];throw error;}
    const promise=Promise.resolve().then(async()=>{
      try {
        const value=await execute(parameters);
        record.result=seal(JSON.stringify({ok:true,value}));
        record.status='completed';record.updated=clock();
        audit(account,tool,'completed',key);
        try{save();}catch(error){record.status='uncertain';delete record.result;throw error;}
        return value;
      }catch(error){
        const ambiguous=!error.http||error.http>=500;
        record.status=ambiguous?'uncertain':'failed';record.updated=clock();
        if(!ambiguous)record.result=seal(JSON.stringify({ok:false,message:error.message,http:error.http}));
        audit(account,tool,record.status,key);save();
        throw error;
      }finally{running.delete(key);}
    });
    running.set(key,promise);
    return promise;
  };
}
