import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash,randomBytes} from 'node:crypto';
import {createGateway} from './server.mjs';

const sha=value=>createHash('sha256').update(value).digest('hex');
const receiptPath=process.argv[2];
if(!receiptPath)throw Error('A new receipt path is required');
const temporary=await fs.mkdtemp(path.join(os.tmpdir(),'gsd-cloud-acceptance-'));
const stateDir=path.join(temporary,'state');
const issuer='https://gsd-acceptance.invalid/gsd-cloud';
const accounts=[],grants=[];
const proof={passed:false,mode:'isolated-candidate-real-pocketbase',checks:{},cleanup:[],started:new Date().toISOString()};
let app,base;
const start=async()=>{
  app=createGateway({publicOrigin:issuer,pbOrigin:'http://127.0.0.1:8095',stateDir});
  await new Promise(resolve=>app.server.listen(0,'127.0.0.1',resolve));
  base='http://127.0.0.1:'+app.server.address().port;
};
const request=async(route,body,token,{form=false,method}={})=>{
  const response=await fetch(base+route,{method:method??(body===undefined?'GET':'POST'),redirect:'manual',
    headers:{'content-type':form?'application/x-www-form-urlencoded':'application/json',
      ...(token?{authorization:'Bearer '+token}:{})},
    body:body===undefined?undefined:form?new URLSearchParams(body):JSON.stringify(body)});
  const raw=await response.text();let value;
  try{value=JSON.parse(raw);}catch{value=raw;}
  return {status:response.status,headers:response.headers,value};
};
const call=async(token,name,args={})=>{
  const response=await request('/mcp',{jsonrpc:'2.0',id:1,method:'tools/call',params:{name,arguments:args}},token);
  assert.equal(response.status,200,'MCP transport status');return response.value.result;
};
const value=result=>{assert.equal(result.isError,false,'MCP tool rejected');return JSON.parse(result.content[0].text);};
const grant=async(account,scope='gsd.read gsd.write offline_access')=>{
  const redirect='https://chatgpt.com/connector_platform_oauth_redirect';
  const registered=await request('/oauth/register',{redirect_uris:[redirect],client_name:'GSD synthetic cloud acceptance'});
  assert.equal(registered.status,201,'DCR registration');
  const client=registered.value.client_id,verifier=randomBytes(36).toString('base64url');
  const state=randomBytes(20).toString('base64url');
  const authorization=await request('/oauth/authorize?'+new URLSearchParams({client_id:client,redirect_uri:redirect,
    response_type:'code',code_challenge:shaChallenge(verifier),code_challenge_method:'S256',scope,state,resource:issuer+'/mcp',ui_locales:'he'}));
  assert.equal(authorization.status,200,'OAuth consent page');
  assert.match(authorization.value,/<html dir="rtl" lang="he">/,'Hebrew OAuth');
  const id=authorization.value.match(/name="request" value="([^"]+)"/)[1];
  const login=await request('/oauth/login',{request:id,email:account.email,password:account.password},null,{form:true});
  assert.equal(login.status,302,'Normal account sign-in');
  const callback=new URL(login.headers.get('location'));
  assert.equal(callback.searchParams.get('state'),state,'OAuth state');
  const fields={grant_type:'authorization_code',client_id:client,redirect_uri:redirect,
    code:callback.searchParams.get('code'),code_verifier:verifier,resource:issuer+'/mcp'};
  assert.equal((await request('/oauth/token',{...fields,code_verifier:'x'.repeat(48)},null,{form:true})).status,400,'PKCE mismatch rejected');
  const token=await request('/oauth/token',fields,null,{form:true});
  assert.equal(token.status,200,'PKCE token grant');
  assert.equal((await request('/oauth/token',fields,null,{form:true})).status,400,'Authorization code single-use');
  const result={...token.value,client_id:client};grants.push(result);return result;
};
const shaChallenge=value=>createHash('sha256').update(value).digest('base64url');

try {
  await start();
  for(let i=0;i<2;i++){
    const email='gsd-cloud-acceptance-'+randomBytes(10).toString('hex')+'@example.invalid';
    const password=randomBytes(28).toString('base64url')+'Az2!';
    const created=await request('/api/collections/users/records',{email,password,passwordConfirm:password});
    assert.ok([200,201].includes(created.status),'Synthetic signup');
    const login=await request('/api/collections/users/auth-with-password',{identity:email,password});
    assert.equal(login.status,200,'Synthetic native login');
    accounts.push({email,password,id:login.value.record.id,pbToken:login.value.token});
  }
  const a=await grant(accounts[0]),b=await grant(accounts[1]);
  const token=a.access_token;
  const listed=await request('/mcp',{jsonrpc:'2.0',id:2,method:'tools/list'},token);
  assert.equal(listed.value.result.tools.length,22,'Cloud catalog');
  proof.checks.oauth_dcr_pkce_scopes=true;
  const title='בדיקת ענן ללא מכשיר '+randomBytes(4).toString('hex');
  const args={title,due_at:'2026-12-03T09:00:00Z',request_id:'acceptance-create'};
  const results=await Promise.all([call(token,'create_task',args),call(token,'create_task',args)]);
  assert.deepEqual(results[0],results[1],'Concurrent create replay');
  const task=value(results[0]);
  assert.equal(value(await call(token,'list_tasks')).total,1,'No duplicate task');
  assert.match(JSON.stringify(await call(token,'create_task',{...args,title:'Changed'})),/request_id_conflict/);
  const other=value(await call(b.access_token,'create_task',{title:'Other account',request_id:'acceptance-create'}));
  assert.notEqual(other.taskId,task.taskId,'Account-scoped receipt');
  assert.equal((await call(b.access_token,'get_task',{id:task.taskId})).isError,true,'Foreign task hidden');
  assert.equal(value(await call(b.access_token,'list_tasks')).total,1,'Account isolated list');
  proof.checks.concurrent_create_replay_and_account_isolation=true;
  value(await call(token,'update_task',{id:task.taskId,title:title+' מעודכן',due_at:'2026-12-04T10:30:00Z',request_id:'acceptance-update'}));
  const updated=value(await call(token,'get_task',{id:task.taskId})).task;
  assert.ok(updated.due_date.startsWith('2026-12-04'),'Date persisted');
  assert.equal(value(await call(token,'list_tasks',{query:title})).total,1,'Search readback');
  const dependency=value(await call(token,'create_task',{title:'תלות לבדיקה',request_id:'acceptance-dependency'}));
  value(await call(token,'add_dependency',{id:task.taskId,dependency_id:dependency.taskId,request_id:'acceptance-link'}));
  assert.deepEqual(value(await call(token,'get_task',{id:task.taskId})).task.dependencies,[dependency.taskId]);
  assert.equal((await call(token,'add_dependency',{id:dependency.taskId,dependency_id:task.taskId,request_id:'acceptance-cycle'})).isError,true,'Cycle rejected');
  value(await call(token,'remove_dependency',{id:task.taskId,dependency_id:dependency.taskId,request_id:'acceptance-unlink'}));
  value(await call(token,'set_completed',{id:task.taskId,completed:true,request_id:'acceptance-complete'}));
  assert.equal(value(await call(token,'get_task',{id:task.taskId})).task.completed,true,'Completion persisted');
  proof.checks.crud_dates_dependencies_search_completion=true;
  const readOnly=await grant(accounts[0],'gsd.read offline_access');
  const denied=await call(readOnly.access_token,'create_task',{title:'Denied',request_id:'acceptance-create'});
  assert.match(denied._meta['mcp/www_authenticate'][0],/insufficient_scope/,'Write scope enforced before replay');
  const refreshed=await request('/oauth/token',{grant_type:'refresh_token',client_id:a.client_id,refresh_token:a.refresh_token,resource:issuer+'/mcp'},null,{form:true});
  assert.equal(refreshed.status,200,'Token refresh');
  assert.equal((await request('/oauth/token',{grant_type:'refresh_token',client_id:a.client_id,refresh_token:a.refresh_token,resource:issuer+'/mcp'},null,{form:true})).status,400,'Refresh rotated once');
  Object.assign(a,refreshed.value);
  value(await call(a.access_token,'get_task',{id:task.taskId}));
  proof.checks.refresh_rotation_and_write_scope=true;
  const deletion={id:task.taskId,request_id:'acceptance-delete'};
  const removed=value(await call(a.access_token,'delete_task',deletion));
  assert.equal(removed.trashed,true,'Recoverable deletion');
  assert.ok(value(await call(a.access_token,'list_trashed_tasks')).tasks.some(t=>t.id===task.taskId),'Trash persisted');
  const saved=await fs.readFile(path.join(stateDir,'gateway-state.json'),'utf8');
  assert.ok(!saved.includes(title),'Receipt task text encrypted');
  app.server.closeAllConnections();await app.close();await start();
  assert.deepEqual(value(await call(a.access_token,'delete_task',deletion)),removed,'Delete receipt survived restart');
  assert.deepEqual(value(await call(a.access_token,'create_task',args)),task,'Create receipt survived restart');
  assert.equal(value(await call(a.access_token,'list_tasks')).total,1,'Restart did not recreate deleted task');
  proof.checks.trash_encrypted_receipts_and_restart_replay=true;
  assert.equal((await request('/oauth/revoke',{token:a.refresh_token,client_id:a.client_id},null,{form:true})).status,200,'Revoke');
  assert.match((await call(a.access_token,'get_task',{id:dependency.taskId}))._meta['mcp/www_authenticate'][0],/invalid_token/,'Revoked access rejected');
  proof.checks.revocation=true;
  proof.passed=true;
}catch(error){proof.failure={name:error.name,code:error.code??null,message:error.message};}
finally {
  for(const account of accounts){
    try{const result=await request('/api/gsd/account',undefined,account.pbToken,{method:'DELETE'});
      proof.cleanup.push({accountDeleted:result.status===204,status:result.status});}
    catch(error){proof.cleanup.push({accountDeleted:false,error:error.name});}
  }
  if(app){app.server.closeAllConnections();await app.close();}
  await fs.rm(temporary,{recursive:true,force:true});
  proof.passed=proof.passed&&accounts.length===2&&proof.cleanup.every(x=>x.accountDeleted);
  proof.finished=new Date().toISOString();
  proof.source_sha256={};
  for(const name of ['server.mjs','request-ledger.mjs','live-acceptance.mjs'])
    proof.source_sha256[name]=sha(await fs.readFile(new URL('./'+name,import.meta.url)));
  await fs.writeFile(receiptPath,JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o600});
}
console.log(JSON.stringify({passed:proof.passed,checks:proof.checks,cleanup:proof.cleanup,failure:proof.failure}));
process.exitCode=proof.passed?0:1;
