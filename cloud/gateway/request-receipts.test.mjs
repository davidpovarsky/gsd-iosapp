import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash,randomBytes} from 'node:crypto';
import {createGateway} from './server.mjs';

const issuer='https://cloud.example/gsd-cloud';
async function fixture(t) {
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'gsd-request-receipts-'));
  const rows=new Map(),tokens=new Map();let writes=0,dropNext=false,app,origin;
  const pb=http.createServer(async(req,res)=>{
    let raw='';for await(const chunk of req)raw+=chunk;
    const body=raw?JSON.parse(raw):{};
    const reply=(status,value)=>{res.writeHead(status,{'content-type':'application/json'});res.end(JSON.stringify(value));};
    if(req.url.endsWith('/auth-with-password')) {
      const id=body.identity.startsWith('second')?'account22222222':'account11111111';
      const token='h.'+Buffer.from(JSON.stringify({id,exp:9999999999})).toString('base64url')+'.s';
      tokens.set(token,id);return reply(200,{token,record:{id}});
    }
    const owner=tokens.get(req.headers.authorization);
    if(!owner)return reply(401,{message:'Authentication required'});
    if(req.url.startsWith('/api/collections/tasks/records')&&req.method==='GET')
      return reply(200,{items:[...rows.values()].filter(r=>r.owner===owner),totalPages:1});
    if(req.url==='/api/collections/tasks/records'&&req.method==='POST') {
      writes++;const row={...body,id:'record'+String(writes).padStart(10,'0')};rows.set(row.id,row);
      if(dropNext){dropNext=false;req.socket.destroy();return;}
      await new Promise(r=>setTimeout(r,20));return reply(200,row);
    }
    if(req.url.startsWith('/api/gsd/tasks/')) {
      const id=req.url.split('/').at(-1),row=rows.get(id);
      if(!row||row.owner!==owner)return reply(404,{message:'Not found'});
      if(row.client_updated_at!==body.expected_version)return reply(412,{message:'Conflict'});
      writes++;
      if(req.method==='DELETE'){rows.delete(id);return reply(200,{deleted:true});}
      Object.assign(row,body.data);return reply(200,row);
    }
    return reply(404,{message:'Unexpected fixture endpoint'});
  });
  await new Promise(r=>pb.listen(0,'127.0.0.1',r));
  const start=async()=>{
    app=createGateway({publicOrigin:issuer,pbOrigin:'http://127.0.0.1:'+pb.address().port,stateDir});
    await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
    origin='http://127.0.0.1:'+app.server.address().port;
  };
  await start();
  const request=async(route,body,token,form=false)=>{
    const res=await fetch(origin+route,{method:body===undefined?'GET':'POST',redirect:'manual',
      headers:{'content-type':form?'application/x-www-form-urlencoded':'application/json',...(token?{authorization:'Bearer '+token}:{})},
      body:body===undefined?undefined:form?new URLSearchParams(body):JSON.stringify(body)});
    const raw=await res.text();let value;try{value=JSON.parse(raw);}catch{value=raw;}
    return {status:res.status,headers:res.headers,value};
  };
  const grant=async(identity='first@example.invalid',scope='gsd.read gsd.write offline_access')=>{
    const redirect='https://chatgpt.com/connector_platform_oauth_redirect';
    const client=(await request('/oauth/register',{redirect_uris:[redirect]})).value.client_id;
    const verifier=randomBytes(36).toString('base64url');
    const page=await request('/oauth/authorize?'+new URLSearchParams({client_id:client,redirect_uri:redirect,
      response_type:'code',code_challenge:createHash('sha256').update(verifier).digest('base64url'),
      code_challenge_method:'S256',scope,resource:issuer+'/mcp'}));
    const login=await request('/oauth/login',{request:page.value.match(/name="request" value="([^"]+)"/)[1],
      email:identity,password:'fixture-password'},null,true);
    const code=new URL(login.headers.get('location')).searchParams.get('code');
    return (await request('/oauth/token',{grant_type:'authorization_code',client_id:client,redirect_uri:redirect,
      code,code_verifier:verifier,resource:issuer+'/mcp'},null,true)).value.access_token;
  };
  const rpc=async(token,method,params={})=>(await request('/mcp',{jsonrpc:'2.0',id:1,method,params},token)).value.result;
  const call=(token,name,args)=>rpc(token,'tools/call',{name,arguments:args});
  const restart=async()=>{app.server.closeAllConnections();await app.close();await start();};
  t.after(async()=>{app.server.closeAllConnections();await app.close();pb.closeAllConnections();
    await new Promise(r=>pb.close(r));await fs.rm(stateDir,{recursive:true,force:true});});
  return {grant,call,rpc,restart,stateDir,rows,writes:()=>writes,dropNext:()=>{dropNext=true;}};
}
const value=result=>{assert.equal(result.isError,false,JSON.stringify(result));return JSON.parse(result.content[0].text);};

test('Cloud write descriptors accept bounded retry IDs without changing read descriptors',async t=>{
  const f=await fixture(t),token=await f.grant(),tools=(await f.rpc(token,'tools/list')).tools;
  assert.equal(tools.length,22);
  for(const tool of tools)assert.equal(Boolean(tool.inputSchema.properties.request_id),!tool.annotations.readOnlyHint);
});
test('Concurrent identical writes and restart replay return the original result without another mutation',async t=>{
  const f=await fixture(t),token=await f.grant();
  const args={title:'PRIVATE-TITLE-RECEIPT-TEST',request_id:'create-001'};
  const pair=await Promise.all([f.call(token,'create_task',args),f.call(token,'create_task',args)]);
  const first=value(pair[0]);assert.deepEqual(pair[1],pair[0]);assert.equal(f.writes(),1);
  const disk=await fs.readFile(path.join(f.stateDir,'gateway-state.json'),'utf8');
  assert.ok(!disk.includes(args.title),'Results must be encrypted at rest');
  assert.ok(!disk.includes(token),'Bearer tokens must not enter receipts');
  await f.restart();
  assert.deepEqual(value(await f.call(token,'create_task',{request_id:'create-001',title:args.title})),first);
  assert.equal(f.writes(),1);assert.equal(f.rows.size,1);
});
test('Request IDs bind to the account, tool, and complete arguments',async t=>{
  const f=await fixture(t),a=await f.grant(),b=await f.grant('second@example.invalid');
  const first=value(await f.call(a,'create_task',{title:'First',request_id:'shared-id'}));
  assert.match(JSON.stringify(await f.call(a,'create_task',{title:'Changed',request_id:'shared-id'})),/request_id_conflict/);
  assert.match(JSON.stringify(await f.call(a,'add_subtask',{id:first.taskId,title:'Child',request_id:'shared-id'})),/request_id_conflict/);
  const second=value(await f.call(b,'create_task',{title:'First',request_id:'shared-id'}));
  assert.notEqual(second.taskId,first.taskId);assert.equal(f.writes(),2);
});
test('Nonidempotent subtask toggle and controlled delete are replayed exactly once',async t=>{
  const f=await fixture(t),token=await f.grant();
  const created=value(await f.call(token,'create_task',{title:'Parent'}));
  const added=value(await f.call(token,'add_subtask',{id:created.taskId,title:'Child',request_id:'add-child'}));
  const args={id:created.taskId,subtask_id:added.changes.subtasks[0].id,request_id:'toggle-child'};
  const toggled=value(await f.call(token,'toggle_subtask',args));
  assert.equal(toggled.changes.subtasks[0].completed,true);
  assert.deepEqual(value(await f.call(token,'toggle_subtask',args)),toggled);
  assert.equal([...f.rows.values()][0].subtasks[0].completed,true);
  const deleted=value(await f.call(token,'delete_task',{id:created.taskId,request_id:'delete-parent'}));
  await f.restart();
  assert.deepEqual(value(await f.call(token,'delete_task',{id:created.taskId,request_id:'delete-parent'})),deleted);
  assert.equal(f.rows.size,0);assert.equal(f.writes(),4);
});
test('An ambiguous upstream completion is never repeated after connection failure or restart',async t=>{
  const f=await fixture(t),token=await f.grant();f.dropNext();
  const args={title:'Written before transport failure',request_id:'ambiguous-write'};
  const failed=await f.call(token,'create_task',args);assert.equal(failed.isError,true);
  assert.equal(f.rows.size,1);assert.equal(f.writes(),1);
  await f.restart();
  assert.match(JSON.stringify(await f.call(token,'create_task',args)),/request_reconciliation_required/);
  assert.equal(f.writes(),1);
});
test('Scope checks precede receipt replay and malformed keys never reach PocketBase',async t=>{
  const f=await fixture(t),token=await f.grant();
  const args={title:'Scoped',request_id:'scoped-write'};value(await f.call(token,'create_task',args));
  const read=await f.grant('first@example.invalid','gsd.read offline_access');
  const denied=await f.call(read,'create_task',args);
  assert.match(denied._meta['mcp/www_authenticate'][0],/insufficient_scope/);
  for(const key of ['',true,'x'.repeat(129)])assert.equal((await f.call(token,'create_task',{title:'No',request_id:key})).isError,true);
  assert.equal(f.writes(),1);
});
