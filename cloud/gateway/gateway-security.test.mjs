import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { createGateway } from './server.mjs';

test('OAuth consent shows exact scopes in Hebrew and English; durable grants rotate once across restart', async () => {
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'gsd-gateway-test-'));
  const token='h.'+Buffer.from(JSON.stringify({id:'user12345678901',exp:9999999999})).toString('base64url')+'.s';
  const fakePB=http.createServer(async(req,res)=>{
    let body='';for await(const chunk of req)body+=chunk;
    if(req.url.endsWith('/auth-refresh'))await new Promise(resolve=>setTimeout(resolve,25));
    res.writeHead(200,{'content-type':'application/json'});
    res.end(JSON.stringify({token,record:{id:'user12345678901',email:'fixture@example.invalid'}}));
  });
  await new Promise(resolve=>fakePB.listen(0,'127.0.0.1',resolve));
  const pbOrigin='http://127.0.0.1:'+fakePB.address().port;
  const publicOrigin='https://cloud.example/gsd-cloud';
  let gateway, origin;
  const start=async()=>{
    gateway=createGateway({publicOrigin,pbOrigin,stateDir});
    await new Promise(resolve=>gateway.server.listen(0,'127.0.0.1',resolve));
    origin='http://127.0.0.1:'+gateway.server.address().port;
  };
  const post=(route,body,form=false)=>fetch(origin+route,{method:'POST',redirect:'manual',
    headers:{'Content-Type':form?'application/x-www-form-urlencoded':'application/json'},
    body:form?new URLSearchParams(body):JSON.stringify(body)});
  try {
    await start();
    const redirect='http://127.0.0.1:8765/callback';
    const registration=await post('/oauth/register',{redirect_uris:[redirect]});
    assert.equal(registration.status,201);
    const client=(await registration.json()).client_id;
    const verifier=randomBytes(36).toString('base64url');
    const challenge=createHash('sha256').update(verifier).digest('base64url');
    const query={client_id:client,redirect_uri:redirect,response_type:'code',
      code_challenge:challenge,code_challenge_method:'S256',scope:'gsd.read',state:'preserved',
      resource:publicOrigin+'/mcp',ui_locales:'en'};
    const english=await (await fetch(origin+'/oauth/authorize?'+new URLSearchParams(query))).text();
    assert.match(english,/dir="ltr" lang="en"/);
    assert.match(english,/Read your tasks and reports/);
    assert.doesNotMatch(english,/Create, edit and delete your tasks/);
    assert.doesNotMatch(english,/Keep access until you revoke/);
    assert.match(english,/Sign in and allow/);
    const hebrew=await (await fetch(origin+'/oauth/authorize?'+new URLSearchParams({
      ...query,scope:'gsd.read gsd.write offline_access',ui_locales:'he'}))).text();
    assert.match(hebrew,/dir="rtl" lang="he"/);
    assert.match(hebrew,/הרשאות מבוקשות/);
    assert.match(hebrew,/יצירה, עריכה ומחיקה של משימות/);
    const request=hebrew.match(/name="request" value="([^"]+)"/)[1];
    const login=await post('/oauth/login',{request,email:'fixture@example.invalid',password:'synthetic-password'},true);
    assert.equal(login.status,302);
    const callback=new URL(login.headers.get('location'));
    assert.equal(callback.searchParams.get('state'),'preserved');
    const exchanged=await post('/oauth/token',{grant_type:'authorization_code',client_id:client,
      redirect_uri:redirect,code:callback.searchParams.get('code'),code_verifier:verifier,
      resource:publicOrigin+'/mcp'},true);
    assert.equal(exchanged.status,200);
    const grant=await exchanged.json();
    const persisted=await fs.readFile(path.join(stateDir,'gateway-state.json'),'utf8');
    assert.ok(!persisted.includes(token),'PocketBase token must be encrypted at rest');
    assert.ok(!persisted.includes(grant.access_token),'Opaque bearer must be stored only by hash');
    await gateway.close();
    await start();
    const catalog=await fetch(origin+'/mcp',{method:'POST',
      headers:{authorization:'Bearer '+grant.access_token,'content-type':'application/json'},
      body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/list'})});
    assert.equal(catalog.status,200);
    assert.equal((await catalog.json()).result.tools.length,22);
    const rotate=()=>post('/oauth/token',{grant_type:'refresh_token',client_id:client,
      refresh_token:grant.refresh_token,resource:publicOrigin+'/mcp'},true);
    const rotations=await Promise.all([rotate(),rotate()]);
    assert.deepEqual(rotations.map(r=>r.status).sort(),[200,400]);
    const renewed=await rotations.find(r=>r.status===200).json();
    assert.notEqual(renewed.refresh_token,grant.refresh_token);
    const revoked=await post('/oauth/revoke',{token:renewed.refresh_token,client_id:client},true);
    assert.equal(revoked.status,200);
    const denied=await fetch(origin+'/mcp',{method:'POST',
      headers:{authorization:'Bearer '+renewed.access_token,'content-type':'application/json'},
      body:JSON.stringify({jsonrpc:'2.0',id:2,method:'tools/list'})});
    assert.equal(denied.status,401);
  } finally {
    if(gateway)await gateway.close();
    await new Promise(resolve=>fakePB.close(resolve));
    await fs.rm(stateDir,{recursive:true,force:true});
  }
});
