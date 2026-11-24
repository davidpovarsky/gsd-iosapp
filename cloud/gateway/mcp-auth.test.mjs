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
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'gsd-mcp-auth-'));
  let pbCalls=0,pbStatus=200;
  const pbToken='h.'+Buffer.from(JSON.stringify({id:'fixture-user',exp:9999999999})).toString('base64url')+'.s';
  const pb=http.createServer(async(req,res)=>{
    for await(const chunk of req) {}
    pbCalls++;
    res.writeHead(pbStatus,{'content-type':'application/json'});
    res.end(JSON.stringify({token:pbToken,record:{id:'fixture-user'},items:[]}));
  });
  await new Promise(r=>pb.listen(0,'127.0.0.1',r));
  const app=createGateway({publicOrigin:issuer,pbOrigin:'http://127.0.0.1:'+pb.address().port,stateDir});
  await new Promise(r=>app.server.listen(0,'127.0.0.1',r));
  const origin='http://127.0.0.1:'+app.server.address().port;
  const request=async(route,body=null,token=null,form=false)=>{
    const res=await fetch(origin+route,{method:body===null?'GET':'POST',redirect:'manual',
      headers:{...(body!==null?{'content-type':form?'application/x-www-form-urlencoded':'application/json'}:{}),
        ...(token?{authorization:'Bearer '+token}:{})},
      body:body===null?undefined:form?new URLSearchParams(body):JSON.stringify(body)});
    const text=await res.text();let value;try{value=JSON.parse(text);}catch{value=text;}
    return {status:res.status,headers:res.headers,value};
  };
  t.after(async()=>{app.server.closeAllConnections();await app.close();pb.closeAllConnections();
    await new Promise(r=>pb.close(r));await fs.rm(stateDir,{recursive:true,force:true});});
  const grant=async(scope='gsd.read gsd.write offline_access')=>{
    const redirect='https://chatgpt.com/connector_platform_oauth_redirect';
    const client=(await request('/oauth/register',{redirect_uris:[redirect],token_endpoint_auth_method:'none'})).value.client_id;
    const verifier=randomBytes(48).toString('base64url');
    const page=await request('/oauth/authorize?'+new URLSearchParams({
      client_id:client,redirect_uri:redirect,response_type:'code',state:'state-unchanged',
      code_challenge:createHash('sha256').update(verifier).digest('base64url'),code_challenge_method:'S256',scope,resource:issuer+'/mcp'
    }));
    const id=page.value.match(/name="request" value="([^"]+)"/)[1];
    const login=await request('/oauth/login',{request:id,email:'fixture@example.invalid',password:'fixture-password'},null,true);
    assert.equal(login.status,302);
    const callback=new URL(login.headers.get('location'));
    const token=await request('/oauth/token',{grant_type:'authorization_code',client_id:client,
      redirect_uri:redirect,code:callback.searchParams.get('code'),code_verifier:verifier,resource:issuer+'/mcp'},null,true);
    return {...token.value,client,callback};
  };
  const rpc=(method,params={},token=null)=>request('/mcp',{jsonrpc:'2.0',id:1,method,params},token);
  return {app,request,grant,rpc,pbCalls:()=>pbCalls,rejectAccount:()=>{pbStatus=401;}};
}
test('MCP descriptors declare required OAuth scopes at both supported metadata locations',async t=>{
  const f=await fixture(t),g=await f.grant();
  const listed=await f.rpc('tools/list',{},g.access_token);
  assert.equal(listed.status,200);assert.equal(listed.value.result.tools.length,22);
  for(const tool of listed.value.result.tools) {
    const scopes=tool.annotations.readOnlyHint?['gsd.read']:['gsd.read','gsd.write'];
    assert.deepEqual(tool.securitySchemes,[{type:'oauth2',scopes}]);
    assert.deepEqual(tool._meta.securitySchemes,tool.securitySchemes);
  }
});
test('MCP unauthenticated and under-scoped calls prompt linking without a host operation',async t=>{
  const f=await fixture(t);
  const none=await f.rpc('tools/call',{name:'list_tasks',arguments:{}});
  assert.equal(none.status,200);assert.equal(none.value.result.isError,true);
  assert.match(none.value.result._meta['mcp/www_authenticate'][0],/error="invalid_token"/);
  assert.equal(f.pbCalls(),0);
  assert.equal((await f.rpc('tools/list')).status,401);
  const g=await f.grant('gsd.read offline_access'),before=f.pbCalls();
  const denied=await f.rpc('tools/call',{name:'create_task',arguments:{title:'Must not exist'}},g.access_token);
  assert.equal(denied.status,200);assert.equal(denied.value.result.isError,true);
  assert.match(denied.value.result._meta['mcp/www_authenticate'][0],/error="insufficient_scope"/);
  assert.match(denied.value.result._meta['mcp/www_authenticate'][0],/scope="gsd.read gsd.write"/);
  assert.equal(f.pbCalls(),before);
  await f.request('/oauth/revoke',{token:g.refresh_token,client_id:g.client},null,true);
  const expired=await f.rpc('tools/call',{name:'list_tasks',arguments:{}},g.access_token);
  assert.equal(expired.value.result.isError,true);
  assert.equal(f.pbCalls(),before);
});
test('OAuth issuer identification and MCP version negotiation match the advertised contract',async t=>{
  const f=await fixture(t);
  const meta=await f.request('/.well-known/oauth-authorization-server');
  assert.equal(meta.value.authorization_response_iss_parameter_supported,true);
  const grant=await f.grant();
  assert.equal(grant.callback.searchParams.get('iss'),issuer);
  assert.equal(grant.callback.searchParams.get('state'),'state-unchanged');
  for(const protocolVersion of ['2025-03-26','2025-06-18','2025-11-25']) {
    const init=await f.rpc('initialize',{protocolVersion});
    assert.equal(init.value.result.protocolVersion,protocolVersion);
  }
  const unknown=await f.rpc('initialize',{protocolVersion:'1900-01-01'});
  assert.equal(unknown.value.result.protocolVersion,'2025-11-25');
});

test('An expired account service credential prompts reconnect without disclosing its error',async t=>{
  const f=await fixture(t),g=await f.grant();
  f.rejectAccount();
  const result=await f.rpc('tools/call',{name:'list_tasks',arguments:{}},g.access_token);
  assert.equal(result.status,200);assert.equal(result.value.result.isError,true);
  assert.match(result.value.result._meta['mcp/www_authenticate'][0],/error="invalid_token"/);
  assert.match(result.value.result.content[0].text,/Connect your GSD account/);
});
