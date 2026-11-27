// GSD Cloud: first-party account auth + PocketBase compatibility + ChatGPT OAuth MCP.
// Node.js 24+, no npm dependencies. Runs behind TLS terminating Tailscale/Cloudflare.
import http from 'node:http';
import { createHash, randomBytes, createCipheriv, createDecipheriv, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { quadrant, validDate, nextRecurringTask, dependencyWouldCycle, builtInViews } from './task-domain.mjs';
import {createRequestLedger,requestIDSchema} from './request-ledger.mjs';

const sha = x => createHash('sha256').update(String(x)).digest('hex');
const rand = (n=32) => randomBytes(n).toString('base64url');
const cleanCompare = (a,b) => typeof a === 'string' && typeof b === 'string' &&
  Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a),Buffer.from(b));
const isoNow = () => new Date().toISOString();
const tokenTTL = 3600000;
const refreshTTL = 30*24*3600000;
const authTTL = 10*60000;
const allowedScopes = new Set(['gsd.read','gsd.write','offline_access']);
const protocolVersion = offered => ['2025-03-26','2025-06-18','2025-11-25'].includes(offered) ? offered : '2025-11-25';
const toolScopes = tool => tool?.writes ? ['gsd.read','gsd.write'] : ['gsd.read'];
const toolSecurity = tool => [{type:'oauth2',scopes:toolScopes(tool)}];
const safeId = x => typeof x === 'string' && /^[A-Za-z0-9_-]{8,160}$/.test(x);

const catalog = JSON.parse(fs.readFileSync(new URL('./tool-catalog.json',import.meta.url),'utf8'));
for(const tool of catalog)if(tool.writes)tool.inputSchema={...tool.inputSchema,
  properties:{...tool.inputSchema.properties,request_id:requestIDSchema}};
const byName = new Map(catalog.map(x=>[x.name,x]));
if (byName.size !== 22) throw Error('Unexpected GSD Hanlin catalog shape');

function filterValidArgs(schema,args) {
  if (!args || typeof args !== 'object' || Array.isArray(args)) return false;
  if (Object.keys(args).some(k=>!(k in schema.properties))) return false;
  for (const k of schema.required || []) if (!(k in args)) return false;
  for (const [k,v] of Object.entries(args)) {
    const def=schema.properties[k];
    if (!def) return false;
    if (def.type==='string') {
      if(typeof v!=='string'||v.length<(def.minLength||0)||v.length>(def.maxLength||10000) ||
        (def.enum&&!def.enum.includes(v)))return false;
    } else if (def.type==='boolean') {
      if(typeof v!=='boolean')return false;
    } else if (def.type==='integer') {
      if(!Number.isInteger(v)||v<(def.minimum??Number.MIN_SAFE_INTEGER)||v>(def.maximum??Number.MAX_SAFE_INTEGER))return false;
    } else if (def.type==='array') {
      if(!Array.isArray(v)||v.length>(def.maxItems||100)||!v.every(y=>
        typeof y==='string'&&y.length>=(def.items?.minLength||0)&&y.length<=(def.items?.maxLength||10000)))return false;
    } else return false;
  }
  return true;
}

function validRedirect(value) {
  try {
    const u=new URL(value);
    if(u.username||u.password||u.hash) return false;
    if(u.protocol==='http:' && ['127.0.0.1','localhost'].includes(u.hostname))return true;
    if(u.protocol!=='https:')return false;
    return u.hostname==='chatgpt.com'||u.hostname.endsWith('.chatgpt.com')||
      u.hostname==='chat.openai.com'||u.hostname==='openai.com'||u.hostname.endsWith('.openai.com');
  } catch{return false;}
}
const htmlEscape=x=>String(x).replaceAll('&','&amp;').replaceAll('"','&quot;')
  .replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll("'",'&#39;');

const oauthLabels={
  en:{
    email:'Email',password:'Password',confirm:'Confirm password',title:'Sign in to GSD',
    intro:'Connect ChatGPT to your GSD account with your usual email and password. No pairing code or open iPad is required.',
    login:'Sign in and allow',newAccount:'Create account and allow',existing:'Existing GSD account',create:'New GSD account',
    requested:'Requested permissions',read:'Read your tasks and reports',write:'Create, edit and delete your tasks',
    offline:'Keep access until you revoke this connection',footer:'Only this GSD account is shared with ChatGPT. You can revoke this connection in ChatGPT.',
    language:'Page language',passwordHint:'Use 10–128 characters.',
    errorTitle:'Sign-in could not be completed',
    expired:'Authorization request expired. Return to ChatGPT and connect again.',
    invalidOrigin:'Invalid request origin. Open the connection again from ChatGPT.',
    invalidRequest:'Invalid authorization request. Open the connection again from ChatGPT.',
    rateLimit:'Too many attempts. Please try again later.'
  },
  he:{
    email:'דואר אלקטרוני',password:'סיסמה',confirm:'אימות סיסמה',title:'התחברות לחשבון GSD',
    intro:'חבר את ChatGPT לחשבון המשימות שלך באמצעות כניסה רגילה. אין צורך בקוד צימוד או באייפד פתוח.',
    login:'התחברות ואישור',newAccount:'יצירת חשבון ואישור',existing:'כניסה לחשבון קיים',create:'חשבון GSD חדש',
    requested:'הרשאות מבוקשות',read:'קריאת המשימות והדוחות שלך',write:'יצירה, עריכה ומחיקה של משימות',
    offline:'גישה מתמשכת עד לביטול החיבור',footer:'רק חשבון GSD זה משותף עם ChatGPT. אפשר לבטל את החיבור בהגדרות ChatGPT.',
    language:'שפת הדף',passwordHint:'הסיסמה חייבת להכיל 10–128 תווים.',
    errorTitle:'ההתחברות לא הושלמה',
    expired:'החיבור פג תוקף. יש לחזור ל־ChatGPT ולהתחבר מחדש.',
    invalidOrigin:'מקור הבקשה אינו תקין. יש לפתוח מחדש את ההתחברות מתוך ChatGPT.',
    invalidRequest:'בקשת הרשאה לא תקינה. יש לפתוח מחדש את ההתחברות מתוך ChatGPT.',
    rateLimit:'יותר מדי ניסיונות. יש לנסות שוב מאוחר יותר.'
  }
};
const supportedLanguage=value=>/^(en|he)(?:-[a-z0-9]+)*$/i.test(value)?value.slice(0,2).toLowerCase():null;
function oauthLanguage(uiLocales,acceptLanguage) {
  for(const tag of String(uiLocales||'').trim().split(/\s+/)) {
    const language=supportedLanguage(tag);
    if(language)return language;
  }
  const preferences=String(acceptLanguage||'').split(',').flatMap((part,index)=>{
    const [range,...parameters]=part.trim().split(/\s*;\s*/);
    const language=range==='*'?'*':supportedLanguage(range);
    const quality=parameters.length?parameters[0].match(/^q=(0(?:\.\d{0,3})?|1(?:\.0{0,3})?)$/i):null;
    if(!language||parameters.length>1||(parameters.length&&!quality))return [];
    return [{language,quality:quality?Number(quality[1]):1,index}];
  });
  // A specific exclusion wins over a wildcard; ties retain the user's listed order.
  const candidates=['he','en'].flatMap(language=>{
    const exact=preferences.filter(item=>item.language===language);
    const matches=exact.length?exact:preferences.filter(item=>item.language==='*');
    const best=matches.sort((a,b)=>b.quality-a.quality||a.index-b.index)[0];
    return best?.quality>0?[{...best,language}]:[];
  });
  return candidates.sort((a,b)=>b.quality-a.quality||a.index-b.index)[0]?.language||'he';
}
const browserHTML=(language,title,body)=>
  '<!doctype html><html dir="'+(language==='en'?'ltr':'rtl')+'" lang="'+(language==='en'?'en':'he')+'"><head><meta charset="utf-8">'+
  '<meta name="viewport" content="width=device-width, initial-scale=1">'+
  '<title>'+htmlEscape(title)+'</title><style>body{font-family:system-ui;max-width:460px;padding:24px;margin:5vh auto;line-height:1.55}'+
  'input{direction:ltr;text-align:left;display:block;box-sizing:border-box;width:100%;padding:12px;margin:6px 0 15px;border:1px solid #aaa;border-radius:9px}'+
  'button{background:#2357ae;border:0;border-radius:9px;color:white;padding:12px 22px;font-size:17px}'+
  'section{padding:14px;border:1px solid #ddd;border-radius:14px;margin:15px 0}p{color:#555}'+
  '.language{display:flex;flex-wrap:wrap;gap:10px;align-items:center}.language button[aria-pressed="true"]{outline:2px solid #2357ae;outline-offset:2px}'+
  '</style></head><body>'+body+'</body></html>';

export function createGateway({
  publicOrigin=process.env.GSD_CLOUD_ORIGIN||'https://torah-social.tail0a6c7d.ts.net:10000/gsd-cloud',
  pbOrigin=process.env.GSD_POCKETBASE_ORIGIN||'http://127.0.0.1:8095',
  stateDir=process.env.GSD_CLOUD_STATE_DIR||path.resolve('state'),
  clock=Date.now
}={}) {
  const base=publicOrigin.replace(/\/$/,'');
  const frontPath=new URL(base).pathname.replace(/\/$/,'');
  const authChallenge=(scopes,error)=>'Bearer resource_metadata="'+base+'/.well-known/oauth-protected-resource", scope="'+scopes.join(' ')+'", error="'+error+'", error_description="'+(error==='insufficient_scope'?'Additional account permission is required.':'Connect your GSD account again.')+'"';
  const toolAuthError=(scopes,error)=>({isError:true,content:[{type:'text',
    text:error==='insufficient_scope'?'Connect GSD with the required permissions.':'Connect your GSD account to use this tool.'}],
    _meta:{'mcp/www_authenticate':[authChallenge(scopes,error)]}});

  const stateFile=path.join(stateDir,'gateway-state.json');
  const keyFile=path.join(stateDir,'gateway.key');
  fs.mkdirSync(stateDir,{recursive:true,mode:0o700});
  let key;
  if(fs.existsSync(keyFile))key=fs.readFileSync(keyFile);
  else {
    key=randomBytes(32);
    fs.writeFileSync(keyFile,key,{mode:0o600,flag:'wx'});
  }
  if(key.length!==32)throw Error('Invalid gateway encryption key');
  const seal=value=>{
    const iv=randomBytes(12);
    const cipher=createCipheriv('aes-256-gcm',key,iv);
    const data=Buffer.concat([cipher.update(String(value),'utf8'),cipher.final()]);
    return Buffer.concat([iv,cipher.getAuthTag(),data]).toString('base64url');
  };
  const open=coded=>{
    const raw=Buffer.from(coded,'base64url');
    if(raw.length<29)throw Error('Invalid encrypted session');
    const decipher=createDecipheriv('aes-256-gcm',key,raw.subarray(0,12));
    decipher.setAuthTag(raw.subarray(12,28));
    return Buffer.concat([decipher.update(raw.subarray(28)),decipher.final()]).toString('utf8');
  };
  const store={clients:{},pending:{},codes:{},access:{},refresh:{},receipts:{},audit:{}};
  if(fs.existsSync(stateFile)) {
    const prev=JSON.parse(fs.readFileSync(stateFile,'utf8'));
    for(const field of Object.keys(store))if(prev[field])Object.assign(store[field],prev[field]);
  }
  const save=()=>{
    for(const group of ['pending','codes','access','refresh'])
      for(const [id,record] of Object.entries(store[group]))
        if(record.expires<=clock())delete store[group][id];
    const tmp=stateFile+'.'+process.pid+'.tmp';
    fs.writeFileSync(tmp,JSON.stringify(store),{mode:0o600,flush:true});
    fs.renameSync(tmp,stateFile);
    const directory=fs.openSync(stateDir,'r');
    try{fs.fsyncSync(directory);}finally{fs.closeSync(directory);}
  };
  const writeWithReceipt=createRequestLedger({store,save,seal,open,clock});
  const json=(res,status,value,extra={})=>{
    res.writeHead(status,{
      'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store',
      'X-Content-Type-Options':'nosniff',...extra
    });
    res.end(JSON.stringify(value));
  };
  const document=(res,status,text)=>{
    res.writeHead(status,{
      'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store',
      'Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'",
      'X-Content-Type-Options':'nosniff','Referrer-Policy':'same-origin'
    });
    res.end(text);
  };
  const readBody=async(req,max=32768)=>{
    let size=0;const parts=[];
    for await(const part of req){
      size+=part.length;if(size>max)throw Error('body_too_large');
      parts.push(part);
    }
    return Buffer.concat(parts).toString('utf8');
  };
  const pb = async(uri,{method='GET',token=null,body=null}={})=>{
    const headers={Accept:'application/json'};
    if(token)headers.Authorization=token;
    if(body!==null)headers['Content-Type']='application/json';
    const result=await fetch(pbOrigin+uri,{
      method,headers,body:body===null?undefined:JSON.stringify(body),
      signal:AbortSignal.timeout(16000),redirect:'manual'
    });
    const text=await result.text();
    let data;
    try{data=JSON.parse(text)}catch{data={message:text.slice(0,300)}}
    if(!result.ok)throw Object.assign(Error(data.message||'Account service error'),{http:result.status,data});
    return data;
  };
  const rateBuckets=new Map();
  const rate=(req,group,limit,window=900000)=>{
    const ip=(req.headers['x-forwarded-for']||req.socket.remoteAddress||'').toString().split(',')[0].slice(0,80);
    const k=sha(group+ip);const now=clock();
    const prior=rateBuckets.get(k);
    if(!prior||now>prior.start+window){rateBuckets.set(k,{count:1,start:now});return true;}
    prior.count+=1;return prior.count<=limit;
  };
  const pendingRequest=id=>typeof id==='string'&&Object.hasOwn(store.pending,id)?store.pending[id]:undefined;
  const renderOAuthError=(res,status,language,error)=>{
    const label=oauthLabels[language==='en'?'en':'he'];
    return document(res,status,browserHTML(language,label.errorTitle,
      '<h1>GSD Tasks</h1><h2>'+label.errorTitle+'</h2><p role="alert">'+htmlEscape(label[error])+'</p>'));
  };
  const renderLogin=(res,requestId,error='',fallbackLanguage='he')=>{
    const pending=pendingRequest(requestId);
    if(!pending||pending.expires<=clock())return renderOAuthError(res,400,pending?.language||fallbackLanguage,'expired');
    const en=pending.language==='en', label=oauthLabels[en?'en':'he'];
    const errorEnglish={
      'כתובת דוא"ל או סיסמה לא תקינה':'Enter a valid email address and password.',
      'שתי הסיסמאות אינן זהות':'The two passwords do not match.',
      'לא ניתן ליצור חשבון עם הפרטים האלו':'An account could not be created with these details.',
      'פרטי ההתחברות לא נכונים':'The email address or password is incorrect.'
    };
    const form=(action,text,registration)=>(
      '<form method="post" action="'+htmlEscape(frontPath+action)+'">' +
      '<input type="hidden" name="request" value="'+htmlEscape(requestId)+'">' +
      '<label>'+label.email+'<input name="email" type="email" autocomplete="email" required maxlength="254"></label>'+
      '<label>'+label.password+'<input name="password" type="password" autocomplete="'+(registration?'new-password':'current-password')+'" required minlength="'+(registration?10:1)+'" maxlength="128"'+(registration?' aria-describedby="password-hint"':'')+'></label>'+
      (registration?'<p id="password-hint">'+label.passwordHint+'</p><label>'+label.confirm+'<input name="confirm" type="password" autocomplete="new-password" required></label>':'')+
      '<button type="submit">'+text+'</button></form>'
    );
    const permissions=pending.scopes.map(scope=>({
      'gsd.read':label.read,'gsd.write':label.write,'offline_access':label.offline
    })[scope]).filter(Boolean).map(value=>'<li>'+htmlEscape(value)+'</li>').join('');
    const languageForm='<form class="language" method="post" action="'+htmlEscape(frontPath+'/oauth/language')+'" aria-label="'+label.language+'">'+
      '<input type="hidden" name="request" value="'+htmlEscape(requestId)+'"><span>'+label.language+'</span>'+
      '<button type="submit" name="language" value="he" lang="he" dir="rtl" aria-pressed="'+(!en)+'">עברית</button>'+
      '<button type="submit" name="language" value="en" lang="en" dir="ltr" aria-pressed="'+en+'">English</button></form>';
    document(res,200,browserHTML(pending.language,label.title,
      languageForm+'<h1>GSD Tasks</h1><p>'+label.intro+'</p><h2>'+label.requested+'</h2><ul>'+permissions+'</ul>'+
      (error?'<p role="alert" style="color:#ba1717">'+htmlEscape(en?(errorEnglish[error]||'Sign-in failed. Please try again.'):error)+'</p>':'')+
      '<section><h2>'+label.existing+'</h2>'+form('/oauth/login',label.login,false)+'</section>'+
      '<section><h2>'+label.create+'</h2>'+form('/oauth/create-account',label.newAccount,true)+'</section>'+
      '<p>'+label.footer+'</p>'));
  };
  const authBearer=req=>{
    const h=req.headers.authorization||'';
    return h.startsWith('Bearer ')?h.slice(7):'';
  };
  const sessionFor=req=>{
    const token=store.access[sha(authBearer(req))];
    if(!token||token.expires<=clock())return null;
    return token;
  };
  async function sessionPbToken(session) {
    let token=open(session.pbToken);
    const parts=token.split('.');
    if(parts.length===3){
      try{
        const payload=JSON.parse(Buffer.from(parts[1],'base64url').toString('utf8'));
        if(payload.exp && payload.exp*1000<clock()+4*24*3600000){
          const refreshed=await pb('/api/collections/users/auth-refresh',{method:'POST',token});
          token=refreshed.token;
          session.pbToken=seal(token);
          save();
        }
      }catch(error){
        if(error.http)throw error;
      }
    }
    return token;
  }
  const rpcOk=(id,result)=>({jsonrpc:'2.0',id,result});
  const rpcError=(id,message,code=-32000)=>({jsonrpc:'2.0',id,error:{code,message}});
  const toolError=(message)=>({isError:true,content:[{type:'text',text:String(message).slice(0,1400)}]});
  const validIdentity=x=>typeof x==='string'&&x.length>=3&&x.length<=254&&/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(x);
  const fullList=async(token)=>{
    let page=1,out=[];
    while(true) {
      const d=await pb('/api/collections/tasks/records?page='+page+'&perPage=100&sort=updated',{token});
      if(!Array.isArray(d.items))throw Error('Invalid task listing');
      out.push(...d.items);
      if(out.length>10000)throw Error('Too many tasks to summarize safely');
      if(page>=d.totalPages)break;
      page+=1;
    }
    return out;
  };
  const localId=()=>rand(13);
  const getRow=async(token,id)=>{
    if(!safeId(id))throw Error('Invalid task ID');
    const tasks=await fullList(token);
    const row=tasks.find(t=>t.task_id===id);
    if(!row)throw Error('Task not found in this account');
    return row;
  };
  const iso=()=>new Date(clock()).toISOString();
  const dueDate=t=>t?Date.parse(t):NaN;
  const saved=t=>Boolean(t.saved_at);
  async function updateRow(token,row,changes,extra={}) {
    const prior=Date.parse(row.client_updated_at)||0;
    const patch={...changes,client_updated_at:new Date(Math.max(clock(),prior+1)).toISOString(),device_id:'chatgpt-cloud'};
    if(patch.task_id!==undefined)delete patch.task_id;
    const endpoint='/api/gsd/tasks/'+encodeURIComponent(row.id);
    const response=await pb(endpoint,{method:'PATCH',token,body:{
      expected_version:row.client_updated_at||'',data:patch,...extra
    }});
    return {taskId:row.task_id,updated:true,serverConfirmed:true,changes:patch};
  }
  async function createRow(token,account,args) {
    const now=iso();
    const row={
      owner:account,title:args.title,
      task_id:localId(),description:args.description||'',
      urgent:args.urgent||false,important:args.important??true,
      quadrant:quadrant(args.urgent||false,args.important??true),
      due_date:args.due_at?validDate(args.due_at):'',completed:false,completed_at:'',
      recurrence:'none',tags:args.tags||[],subtasks:[],dependencies:[],
      notification_enabled:true,notification_sent:false,
      notify_before:0,last_notification_at:'',
      estimated_minutes:args.estimate_minutes||0,time_spent:0,time_entries:[],
      snoozed_until:'',client_updated_at:now,client_created_at:now,
      device_id:'chatgpt-cloud',saved_at:'',focus_date:'',focus_rank:0
    };
    const created=await pb('/api/collections/tasks/records',{method:'POST',token,body:row});
    return {taskId:created.task_id,recordId:created.id,title:created.title,created:true};
  }
  async function libraryRows(token,kind) {
    const out=[];
    for(let page=1;page<=100;page++){
      const result=await pb('/api/collections/gsd_library/records?perPage=100&page='+page,{token});
      for(const row of result.items||[])if(row.kind===kind&&!row.deleted){
        const payload=JSON.parse(row.payload);
        out.push({...payload,cloudVersion:row.client_updated_at});
      }
      if(page>=result.totalPages)return out;
    }
    throw Error('Library listing incomplete');
  }
  async function completeRow(token,row,completed) {
    if(saved(row))throw Error('Return this saved item to a quadrant before completing it');
    if(Boolean(row.completed)===completed)return {taskId:row.task_id,completed,unchanged:true};
    const next=completed?nextRecurringTask(row,iso(),localId):null;
    return updateRow(token,row,{completed,completed_at:completed?iso():''},next?{spawn_next:next}:{});
  }
  const groupFor=t=>{
    if(t.urgent&&t.important)return 'do_first';
    if(!t.urgent&&t.important)return 'schedule';
    if(t.urgent&&!t.important)return 'delegate';
    return 'eliminate';
  };
  async function executeTool(spec,args,session) {
    const token=await sessionPbToken(session);
    const data=await fullList(token);
    const a=args||{};
    switch(spec.name) {
    case 'list_tasks':{
      let rows=data;
      if(a.status==='open')rows=rows.filter(t=>!t.completed);
      if(a.status==='completed')rows=rows.filter(t=>t.completed);
      if(a.quadrant)rows=rows.filter(t=>groupFor(t)===a.quadrant);
      if(a.query)rows=rows.filter(t=>[t.title,t.description,...(t.tags||[])].some(s=>String(s||'').toLowerCase().includes(a.query.toLowerCase())));
      return {tasks:rows.slice(0,a.limit||100),total:rows.length,truncated:rows.length>(a.limit||100)};
    }
    case 'get_task':return {task:await getRow(token,a.id)};
    case 'get_dashboard':{
      const active=data.filter(t=>!t.completed&&!saved(t));
      const now=clock();
      const byQuadrant={do_first:0,schedule:0,delegate:0,eliminate:0};
      for(const t of active)byQuadrant[groupFor(t)]+=1;
      return {total:data.length,open:active.length,completed:data.filter(t=>t.completed).length,
        overdue:active.filter(t=>Number.isFinite(dueDate(t.due_date))&&dueDate(t.due_date)<now).length,
        saved:data.filter(saved).length,
        estimatedOpenMinutes:active.reduce((x,t)=>x+(Number(t.estimated_minutes)||0),0),
        byQuadrant,source:'GSD Cloud',serverTimestamp:iso()};
    }
    case 'list_tags':return {tags:[...new Set(data.flatMap(t=>t.tags||[]))].sort()};
    case 'list_saved_tasks':return {tasks:data.filter(saved)};
    case 'list_archived_tasks':return {tasks:(await libraryRows(token,'archive')).filter(t=>!data.some(r=>r.task_id===t.id))};
    case 'list_trashed_tasks':return {tasks:(await libraryRows(token,'trash')).filter(t=>!data.some(r=>r.task_id===t.id))};
    case 'list_smart_views':return {views:[...builtInViews,...await libraryRows(token,'view')]};
    case 'create_task':return createRow(token,session.userId,a);
    case 'delete_task':{
      const row=await getRow(token,a.id);
      await pb('/api/gsd/tasks/'+encodeURIComponent(row.id),{method:'DELETE',token,
        body:{expected_version:row.client_updated_at||'',disposition:'trash'}});
      return {taskId:a.id,deleted:true,trashed:true,undoAvailableInCloud:true};
    }
    case 'update_task':{
      const row=await getRow(token,a.id);
      const patch={};
      for(const [arg,field] of [['title','title'],['description','description'],
        ['urgent','urgent'],['important','important'],['tags','tags'],
        ['estimate_minutes','estimated_minutes']])if(a[arg]!==undefined)patch[field]=a[arg];
      if(a.clear_due)patch.due_date='';
      else if(a.due_at!==undefined)patch.due_date=validDate(a.due_at);
      if(patch.urgent!==undefined||patch.important!==undefined){
        const urgent=patch.urgent??row.urgent;
        const important=patch.important??row.important;
        patch.quadrant=urgent?(important?'urgentImportant':'urgentNotImportant'):
          (important?'notUrgentImportant':'notUrgentNotImportant');
      }
      if(Object.keys(patch).length===0)return {taskId:a.id,updated:false,reason:'No changed fields'};
      return updateRow(token,row,patch);
    }
    case 'set_completed':{
      const row=await getRow(token,a.id);
      return completeRow(token,row,a.completed);
    }
    case 'add_subtask':{
      const row=await getRow(token,a.id);
      const subtasks=Array.isArray(row.subtasks)?[...row.subtasks]:[];
      subtasks.push({id:localId(),title:a.title,completed:false});
      return updateRow(token,row,{subtasks});
    }
    case 'toggle_subtask':{
      const row=await getRow(token,a.id);
      const subtasks=Array.isArray(row.subtasks)?[...row.subtasks]:[];
      let touched=false;
      for(const st of subtasks)if(st.id===a.subtask_id){st.completed=!st.completed;touched=true;}
      if(!touched)throw Error('Subtask not found');
      return updateRow(token,row,{subtasks});
    }
    case 'add_dependency':
    case 'remove_dependency':{
      const row=await getRow(token,a.id);
      const set=new Set(Array.isArray(row.dependencies)?row.dependencies:[]);
      if(spec.name==='add_dependency'){
        if(!data.some(t=>t.task_id===a.dependency_id))throw Error('Dependency not found in this account');
        if(dependencyWouldCycle(data,a.id,a.dependency_id))throw Error('Dependency would create a cycle');
        set.add(a.dependency_id);
      }
      else set.delete(a.dependency_id);
      return updateRow(token,row,{dependencies:[...set]});
    }
    case 'set_focus':{
      const row=await getRow(token,a.id);
      if(!a.clear && (!a.date||!a.rank||!/^\d{4}-\d{2}-\d{2}$/.test(a.date)||
        new Date(a.date+'T00:00:00Z').toISOString().slice(0,10)!==a.date))
        throw Error('A valid date and a focus rank are required');
      if(saved(row))throw Error('Return this saved item to a quadrant before choosing focus');
      return updateRow(token,row,{focus_date:a.clear?'':a.date,focus_rank:a.clear?0:a.rank});
    }
    case 'bulk_complete':
    case 'bulk_add_tags':
    case 'bulk_move':{
      const completed=[],failures=[];
      for(const id of a.ids){
        try{
          const row=await getRow(token,id);
          let changes={};
          if(spec.name==='bulk_complete'){await completeRow(token,row,true);completed.push(id);continue;}
          if(spec.name==='bulk_add_tags')changes={tags:[...new Set([...(row.tags||[]),...a.tags])]};
          if(spec.name==='bulk_move'){
            changes={
              urgent:['do_first','delegate'].includes(a.quadrant),
              important:['do_first','schedule'].includes(a.quadrant),
              quadrant:{do_first:'urgentImportant',schedule:'notUrgentImportant',
                delegate:'urgentNotImportant',eliminate:'notUrgentNotImportant'}[a.quadrant]
            };
          }
          await updateRow(token,row,changes);
          completed.push(id);
        }catch(e){failures.push({id,message:String(e.message).slice(0,170)})}
      }
      return {completedIds:completed,failures,partial:failures.length>0};
    }
    case 'start_timer':{
      const row=await getRow(token,a.id);
      if(saved(row))throw Error('Return this saved item to a quadrant before starting a timer');
      const entries=[...(row.time_entries||[])];
      if(entries.some(t=>t.endedAt===''))throw Error('A timer is already running');
      entries.push({id:localId(),startedAt:iso(),endedAt:'',minutes:0});
      await updateRow(token,row,{time_entries:entries});
      return {taskId:a.id,started:true};
    }
    case 'stop_timer':{
      const row=await getRow(token,a.id),entries=[...(row.time_entries||[])];
      const running=entries.find(t=>t.endedAt==='');
      if(!running)throw Error('No timer is running');
      running.endedAt=iso();
      running.minutes=Math.max(0,Math.floor((Date.parse(running.endedAt)-Date.parse(running.startedAt))/60000));
      if(a.notes!==undefined)running.notes=a.notes;
      const milliseconds=entries.reduce((sum,t)=>sum+(t.endedAt
        ?Math.max(0,Date.parse(t.endedAt)-Date.parse(t.startedAt))
        :(t.endedAt===undefined?(Number(t.minutes)||0)*60000:0)),0);
      const minutes=Math.floor(milliseconds/60000);
      await updateRow(token,row,{time_entries:entries,time_spent:minutes});
      return {taskId:a.id,stopped:true,totalMinutes:minutes};
    }
    default:throw Error('Unsupported GSD tool');
    }
  }
  const proxyAllowed=(u,method)=>{
    if(u==='/api/health'&&method==='GET')return true;
    if(u==='/api/realtime'&&['GET','POST'].includes(method))return true;
    if(u==='/api/gsd/account'&&method==='DELETE')return true;
    if(u==='/api/gsd/dataset'&&method==='GET')return true;
    if(u==='/api/gsd/dataset/reset'&&method==='POST')return true;
    if(u==='/api/collections/gsd_library/records'&&method==='GET')return true;
    if(/^\/api\/gsd\/library\/(archive|trash|view)\/[A-Za-z0-9_-]{1,160}$/.test(u)&&method==='PUT')return true;
    if(/^\/api\/gsd\/tasks\/[A-Za-z0-9_-]{10,80}$/.test(u)&&['PATCH','DELETE'].includes(method))return true;
    if(u==='/api/collections/users/auth-methods'&&method==='GET')return true;
    if(u==='/api/collections/users/auth-with-password'&&method==='POST')return true;
    if(u==='/api/collections/users/auth-refresh'&&method==='POST')return true;
    if(u==='/api/collections/users/records'&&method==='POST')return true;
    if(/^\/api\/collections\/users\/records\/[A-Za-z0-9_-]{10,80}$/.test(u)&&['GET','PATCH','DELETE'].includes(method))return true;
    if(u==='/api/collections/tasks/records'&&['GET','POST'].includes(method))return true;
    if(/^\/api\/collections\/tasks\/records\/[A-Za-z0-9_-]{10,80}$/.test(u)&&['GET','DELETE'].includes(method))return true;
    return false;
  };
  function proxyToPocketBase(req,res,url) {
    // IncomingMessage.headers coalesces duplicate fields; the generation is one opaque value.
    let generations=0;
    for(let index=0;index<req.rawHeaders.length;index+=2)
      if(req.rawHeaders[index].toLowerCase()==='x-gsd-dataset-generation')generations++;
    if(generations>1)return json(res,400,{status:400,message:'invalid_dataset_generation',data:{}});
    const forwarded=new URL(url.pathname+url.search,pbOrigin);
    const headers={
      'Accept':req.headers.accept||'application/json',
      'Authorization':req.headers.authorization||'',
      'Content-Type':req.headers['content-type']||'application/json'
    };
    if(req.headers['x-gsd-dataset-generation']!==undefined)
      headers['X-GSD-Dataset-Generation']=req.headers['x-gsd-dataset-generation'];
    const upstream=http.request(forwarded,{method:req.method,headers,timeout:60000},response=>{
      const allowedHeaders=['content-type','cache-control','etag','last-modified'];
      const result={};
      for(const field of allowedHeaders)if(response.headers[field])result[field]=response.headers[field];
      result['Cache-Control']='no-store';
      res.writeHead(response.statusCode||502,result);
      response.pipe(res);
    });
    upstream.on('timeout',()=>upstream.destroy(Error('Upstream timeout')));
    upstream.on('error',()=>{
      if(!res.headersSent)json(res,502,{error:'account_service_unavailable'});
      else res.destroy();
    });
    req.pipe(upstream);
  }
  const pageFor=async(request,login,form)=>{
    let auth;
    const email=form.get('email'),password=form.get('password');
    if(!validIdentity(email)||typeof password!=='string'||password.length<(login?1:10)||password.length>128)
      throw Error('כתובת דוא"ל או סיסמה לא תקינה');
    if(!login) {
      const confirm=form.get('confirm');
      if(password!==confirm)throw Error('שתי הסיסמאות אינן זהות');
      try{await pb('/api/collections/users/records',{method:'POST',
        body:{email,password,passwordConfirm:confirm,display_name:email.split('@')[0]}});
      }catch(e){throw Error('לא ניתן ליצור חשבון עם הפרטים האלו')}
    }
    try{auth=await pb('/api/collections/users/auth-with-password',{
      method:'POST',body:{identity:email,password}
    });}catch(e){throw Error('פרטי ההתחברות לא נכונים')}
    return auth;
  };
  const server=http.createServer(async(req,res)=>{
    let pageLanguage=oauthLanguage('',req.headers['accept-language']),browserRoute=false;
    try {
      const url=new URL(req.url,'http://localhost');
      const u=url.pathname;
      const method=req.method;
      browserRoute=(u==='/oauth/authorize'&&method==='GET')||
        (['/oauth/login','/oauth/create-account','/oauth/language'].includes(u)&&method==='POST');
      if(browserRoute)pageLanguage=oauthLanguage(url.searchParams.get('ui_locales'),req.headers['accept-language']);
      if(u==='/ios-oauth-redirect/' && method==='GET') {
        const code=url.searchParams.get('code')||'';
        const state=url.searchParams.get('state')||'';
        if(!code || !state || code.length>2000 || state.length>500)
          return json(res,400,{error:'invalid_oauth_redirect'});
        const callback=new URL('gsd://oauth-callback');
        callback.searchParams.set('code',code);
        callback.searchParams.set('iss',base);
        callback.searchParams.set('state',state);
        res.writeHead(302,{Location:callback.toString(),'Cache-Control':'no-store'});
        return res.end();
      }
      if(u==='/health'&&method==='GET')
        return json(res,200,{ok:true,name:'GSD Cloud',mode:'cloud-account',version:'1.0.0'});
      if(u==='/api/health'||u.startsWith('/api/')){
        if(!proxyAllowed(u,method))return json(res,403,{error:'not_allowed'});
        if(u==='/api/collections/users/records'&&method==='POST'&&!rate(req,'signup',7,3600000))
          return json(res,429,{error:'signup_rate_limit'});
        // Keep PocketBase's body/identity binding intact; all native auth formats share this IP budget.
        if(u==='/api/collections/users/auth-with-password'&&method==='POST'&&!rate(req,'native-login',22,900000))
          return json(res,429,{status:429,message:'Too many authentication attempts. Please try again later.',data:{}},
            {'Retry-After':'900'});
        return proxyToPocketBase(req,res,url);
      }
      if(['/.well-known/oauth-protected-resource','/.well-known/oauth-protected-resource/mcp'].includes(u)&&method==='GET')
        return json(res,200,{resource:base+'/mcp',authorization_servers:[base],
          scopes_supported:[...allowedScopes],bearer_methods_supported:['header']});
      if(u==='/.well-known/oauth-authorization-server'&&method==='GET')
        return json(res,200,{issuer:base,authorization_endpoint:base+'/oauth/authorize',
          token_endpoint:base+'/oauth/token',registration_endpoint:base+'/oauth/register',revocation_endpoint:base+'/oauth/revoke',
          response_types_supported:['code'],authorization_response_iss_parameter_supported:true,
          grant_types_supported:['authorization_code','refresh_token'],
          code_challenge_methods_supported:['S256'],
          token_endpoint_auth_methods_supported:['none'],scopes_supported:[...allowedScopes]});
      if(u==='/oauth/register'&&method==='POST'){
        const data=JSON.parse(await readBody(req));
        if(!Array.isArray(data.redirect_uris)||!data.redirect_uris.length||
          data.redirect_uris.length>5||!data.redirect_uris.every(validRedirect))
          return json(res,400,{error:'invalid_redirect_uri'});
        if(Object.keys(store.clients).length>1000)return json(res,429,{error:'client_limit'});
        const client=rand(24);
        store.clients[client]={redirects:data.redirect_uris,registeredAt:clock()};
        save();
        return json(res,201,{client_id:client,client_id_issued_at:Math.floor(clock()/1000),
          client_name:'GSD Tasks',redirect_uris:data.redirect_uris,
          token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],
          response_types:['code']});
      }
      if(u==='/oauth/authorize'&&method==='GET'){
        const clientId=url.searchParams.get('client_id'), client=store.clients[clientId];
        const redirect=url.searchParams.get('redirect_uri');
        const challenge=url.searchParams.get('code_challenge');
        const requestedResource=url.searchParams.get('resource');
        const scopes=(url.searchParams.get('scope')||'gsd.read gsd.write offline_access').split(/\s+/);
        if(!client||!client.redirects.includes(redirect)||url.searchParams.get('response_type')!=='code'||
          typeof challenge!=='string'||challenge.length<43||challenge.length>180||
          url.searchParams.get('code_challenge_method')!=='S256'||
          scopes.some(s=>!allowedScopes.has(s))||
          (requestedResource && requestedResource!==base+'/mcp'))
          return renderOAuthError(res,400,pageLanguage,'invalidRequest');
        const requestId=rand(20);
        store.pending[requestId]={clientId,redirect,challenge,scopes,
          state:url.searchParams.get('state')||'',language:pageLanguage,created:clock(),expires:clock()+authTTL,failures:0};
        save();
        return renderLogin(res,requestId,'',pageLanguage);
      }
      if(['/oauth/login','/oauth/create-account','/oauth/language'].includes(u)&&method==='POST'){
        const form=new URLSearchParams(await readBody(req,8000));
        const id=form.get('request'),pending=pendingRequest(id),languageOnly=u==='/oauth/language';
        if(pending)pageLanguage=pending.language==='en'?'en':'he';
        if(!rate(req,languageOnly?'language':'login',languageOnly?60:22,900000))
          return renderOAuthError(res,429,pageLanguage,'rateLimit');
        if((languageOnly||req.headers.origin)&&req.headers.origin!==new URL(base).origin)
          return renderOAuthError(res,403,pageLanguage,'invalidOrigin');
        if(!pending||pending.expires<clock())return renderOAuthError(res,400,pageLanguage,'expired');
        if(languageOnly){
          if(pending.expires<=clock())return renderOAuthError(res,400,pageLanguage,'expired');
          const language=form.get('language');
          if(!['he','en'].includes(language))return renderOAuthError(res,400,pageLanguage,'invalidRequest');
          // This action must never refresh the request lifetime, reset failures, or alter consent.
          pending.language=language;
          save();
          return renderLogin(res,id,'',language);
        }
        if(pending.failures>=7)return renderOAuthError(res,429,pageLanguage,'rateLimit');
        let result;
        try{result=await pageFor(id,u==='/oauth/login',form);}
        catch(e){
          pending.failures+=1;save();
          return renderLogin(res,id,String(e.message).slice(0,150),pageLanguage);
        }
        const code=rand(32);
        store.codes[sha(code)]={...pending,type:'code',
          userId:result.record.id,pbToken:seal(result.token),expires:clock()+authTTL};
        delete store.pending[id];
        save();
        const callback=new URL(pending.redirect);
        callback.searchParams.set('code',code);
        callback.searchParams.set('iss',base);
        if(pending.state)callback.searchParams.set('state',pending.state);
        res.writeHead(302,{Location:callback.toString(),'Cache-Control':'no-store'});
        return res.end();
      }
      if(u==='/oauth/token'&&method==='POST'){
        const form=new URLSearchParams(await readBody(req,8000));
        const type=form.get('grant_type'),clientId=form.get('client_id');
        const resource=form.get('resource');
        if(resource && resource!==base+'/mcp')return json(res,400,{error:'invalid_target'});
        let record;
        if(type==='authorization_code'){
          const key=sha(form.get('code')||''),stored=store.codes[key];
          const verifier=form.get('code_verifier')||'';
          const expected=createHash('sha256').update(verifier).digest('base64url');
          if(!stored||stored.expires<=clock()||stored.clientId!==clientId||
            stored.redirect!==form.get('redirect_uri')||!/^[-._~A-Za-z0-9]{43,128}$/.test(verifier)||
            !cleanCompare(stored.challenge,expected))
            return json(res,400,{error:'invalid_grant'});
          record=stored;delete store.codes[key];
        }else if(type==='refresh_token'){
          const key=sha(form.get('refresh_token')||'');
          const stored=store.refresh[key];
          if(!stored||stored.expires<=clock()||stored.clientId!==clientId)
            return json(res,400,{error:'invalid_grant'});
          record=stored;
          // Claim the refresh credential before network I/O. Concurrent replays cannot both rotate it.
          delete store.refresh[key];save();
          try{
            const renewed=await pb('/api/collections/users/auth-refresh',{method:'POST',token:open(record.pbToken)});
            if(renewed.record.id!==record.userId)throw Error('Identity changed');
            record.pbToken=seal(renewed.token);
          }catch{return json(res,400,{error:'invalid_grant'});}
          delete store.refresh[key];
        }else return json(res,400,{error:'unsupported_grant_type'});
        const access=rand(32),refresh=rand(32),scope=record.scopes||['gsd.read','gsd.write','offline_access'];
        const session={userId:record.userId,pbToken:record.pbToken,
          family:record.family||rand(20),clientId,scopes:scope,expires:clock()+tokenTTL};
        store.access[sha(access)]=session;
        if(scope.includes('offline_access'))store.refresh[sha(refresh)]={...session,expires:clock()+refreshTTL};
        save();
        return json(res,200,{access_token:access,token_type:'Bearer',
          expires_in:tokenTTL/1000,...(scope.includes('offline_access')?{refresh_token:refresh}:{}),scope:scope.join(' ')});
      }
      if(u==='/oauth/revoke'&&method==='POST'){
        const form=new URLSearchParams(await readBody(req,8000)),hash=sha(form.get('token')||'');
        const entry=store.refresh[hash]||store.access[hash],clientId=form.get('client_id');
        if(entry&&entry.clientId===clientId){
          for(const field of ['access','refresh'])for(const [id,record] of Object.entries(store[field]))
            if(record.family===entry.family)delete store[field][id];
          save();
        }
        return json(res,200,{});
      }
      if(u==='/mcp'){
        if(method!=='POST')return json(res,405,{error:'use_streamable_http_post'});
        const raw=JSON.parse(await readBody(req,50000));
        if(!raw||raw.jsonrpc!=='2.0')return json(res,400,rpcError(null,'Invalid JSON-RPC',-32600));
        if(raw.method==='initialize')
          return json(res,200,rpcOk(raw.id,{protocolVersion:protocolVersion(raw.params?.protocolVersion),
            capabilities:{tools:{listChanged:false}},
            serverInfo:{name:'GSD Cloud MCP',version:'1.0.0'}}));
        if(raw.method==='notifications/initialized'||raw.method?.startsWith('notifications/')){
          res.writeHead(202);return res.end();
        }
        if(raw.method==='ping')return json(res,200,rpcOk(raw.id,{}));
        const session=sessionFor(req);
        const requestedTool=raw.method==='tools/call'?byName.get(raw.params?.name):null;
        const requiredScopes=toolScopes(requestedTool);
        if(!session){
          if(requestedTool)return json(res,200,rpcOk(raw.id,toolAuthError(requiredScopes,'invalid_token')));
          return json(res,401,{error:'unauthorized'},
            {'WWW-Authenticate':authChallenge(requiredScopes,'invalid_token')});
        }
        if(!requiredScopes.every(scope=>session.scopes.includes(scope))){
          if(requestedTool)return json(res,200,rpcOk(raw.id,toolAuthError(requiredScopes,'insufficient_scope')));
          return json(res,403,{error:'insufficient_scope'},
            {'WWW-Authenticate':authChallenge(requiredScopes,'insufficient_scope')});
        }
        if(raw.method==='tools/list'){
          const tools=catalog.filter(t=>!t.writes||session.scopes.includes('gsd.write'))
            .map(t=>({name:t.name,description:t.description,inputSchema:t.inputSchema,
              annotations:{readOnlyHint:!t.writes,destructiveHint:t.name==='delete_task',
                openWorldHint:false},securitySchemes:toolSecurity(t),
               _meta:{securitySchemes:toolSecurity(t)}}));
          return json(res,200,rpcOk(raw.id,{tools}));
        }
        if(raw.method==='tools/call'){
          const name=raw.params?.name, args=raw.params?.arguments||{};
          const def=byName.get(name);
          if(!def||!filterValidArgs(def.inputSchema,args))
            return json(res,200,rpcOk(raw.id,toolError('Invalid tool or parameters')));
          try {
            const result=def.writes?
              await writeWithReceipt(session.userId,name,args,parameters=>executeTool(def,parameters,session)):
              await executeTool(def,args,session);
            return json(res,200,rpcOk(raw.id,{isError:Boolean(result.failures?.length),content:[{type:'text',text:JSON.stringify(result)}]}));
          }catch(error){
            if(error.http===401)return json(res,200,rpcOk(raw.id,toolAuthError(requiredScopes,'invalid_token')));
            return json(res,200,rpcOk(raw.id,toolError(error.message||'Operation failed')));
          }
        }
        return json(res,200,rpcError(raw.id,'Unknown RPC method',-32601));
      }
      return json(res,404,{error:'not_found'});
    }catch(error){
      // No credentials, passwords or task text in logs.
      console.error('GSD gateway error',String(error.name||'Error'));
      if(!res.headersSent){
        if(browserRoute)renderOAuthError(res,400,pageLanguage,'invalidRequest');
        else json(res,400,{error:'invalid_request'});
      }else res.end();
    }
  });
  return {server,store,catalog,save,close:()=>new Promise(r=>server.close(r))};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const port=Number(process.env.GSD_CLOUD_PORT||8770);
  const address=process.env.GSD_CLOUD_HOST||'127.0.0.1';
  const gateway=createGateway();
  gateway.server.listen(port,address,()=>{
    console.log('GSD Cloud gateway listening on '+address+':'+port);
  });
}
