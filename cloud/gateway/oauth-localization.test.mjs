import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { createGateway } from './server.mjs';

const publicOrigin='https://cloud.example/gsd-cloud';
const browserOrigin=new URL(publicOrigin).origin;

async function fixture(t) {
  const stateDir=await fs.mkdtemp(path.join(os.tmpdir(),'gsd-oauth-locale-'));
  let now=Date.now(), pbCalls=0, rejectAccount=false;
  const token='h.'+Buffer.from(JSON.stringify({id:'user12345678901',exp:9999999999})).toString('base64url')+'.s';
  const pb=http.createServer(async(req,res)=>{
    for await(const _ of req) {}
    pbCalls++;
    res.writeHead(rejectAccount?400:200,{'content-type':'application/json'});
    res.end(JSON.stringify(rejectAccount?{message:'<script>unsafe-account-error</script>'}:
      {token,record:{id:'user12345678901',email:'fixture@example.invalid'}}));
  });
  await new Promise(resolve=>pb.listen(0,'127.0.0.1',resolve));
  const gateway=createGateway({publicOrigin,pbOrigin:'http://127.0.0.1:'+pb.address().port,
    stateDir,clock:()=>now});
  await new Promise(resolve=>gateway.server.listen(0,'127.0.0.1',resolve));
  const origin='http://127.0.0.1:'+gateway.server.address().port;
  t.after(async()=>{
    gateway.server.closeAllConnections();
    await gateway.close();
    pb.closeAllConnections();
    await new Promise(resolve=>pb.close(resolve));
    await fs.rm(stateDir,{recursive:true,force:true});
  });
  const post=(route,body,headers={})=>fetch(origin+route,{method:'POST',redirect:'manual',
    headers:{'content-type':'application/x-www-form-urlencoded',...headers},
    body:new URLSearchParams(body)});
  const redirect='http://127.0.0.1:8765/callback';
  const registration=await fetch(origin+'/oauth/register',{method:'POST',
    headers:{'content-type':'application/json'},body:JSON.stringify({redirect_uris:[redirect]})});
  assert.equal(registration.status,201);
  const client=(await registration.json()).client_id;
  const verifier=randomBytes(36).toString('base64url');
  const challenge=createHash('sha256').update(verifier).digest('base64url');
  const query={client_id:client,redirect_uri:redirect,response_type:'code',code_challenge:challenge,
    code_challenge_method:'S256',scope:'gsd.read',state:'state<&"unchanged',
    resource:publicOrigin+'/mcp'};
  const authorize=async(params={},headers={})=>{
    const response=await fetch(origin+'/oauth/authorize?'+new URLSearchParams({...query,...params}),{headers});
    const html=await response.text();
    return {response,html,request:html.match(/name="request" value="([^"]+)"/)?.[1]};
  };
  return {gateway,origin,post,authorize,query,verifier,pbCalls:()=>pbCalls,
    advance:amount=>{now+=amount},rejectAccount:()=>{rejectAccount=true}};
}

function assertPage(html,language) {
  assert.match(html,new RegExp('<html dir="'+(language==='he'?'rtl':'ltr')+'" lang="'+language+'">'));
  assert.match(html,/<meta charset="utf-8">/);
}

test('OAuth page negotiates supported ui_locales then weighted Accept-Language',async t=>{
  const f=await fixture(t);
  const cases=[
    ['fr en-US he','he','en'],
    ['he-IL en','en','he'],
    ['', 'fr-FR, en-US;q=0.7, he;q=0.9','he'],
    ['', 'he;q=0.2, en;q=0.8','en'],
    ['', 'he;q=0, en;q=0.5','en'],
    ['fr', 'en-GB','en'],
    ['', 'fr, en;q=0.8, he;q=0.8','en'],
    ['', 'en;q=invalid, he;q=0.4','he'],
    ['', 'he;q=0, *;q=0.8','en'],
    ['', 'fr-FR','he']
  ];
  for(const [ui_locales,acceptLanguage,expected] of cases) {
    const page=await f.authorize({ui_locales},{'accept-language':acceptLanguage});
    assert.equal(page.response.status,200);
    assertPage(page.html,expected);
  }
});

test('OAuth forms include localized password guidance and a language-only same-origin action',async t=>{
  const f=await fixture(t);
  for(const language of ['he','en']) {
    const {html}=await f.authorize({ui_locales:language});
    assertPage(html,language);
    assert.match(html,/action="\/gsd-cloud\/oauth\/language"/);
    assert.match(html,/name="language" value="he"/);
    assert.match(html,/name="language" value="en"/);
    assert.match(html,/lang="he" dir="rtl"/);
    assert.match(html,/lang="en" dir="ltr"/);
    assert.match(html,/aria-describedby="password-hint"/);
    assert.match(html,language==='he'?/הסיסמה חייבת להכיל 10–128 תווים/:/Use 10–128 characters/);
    assert.match(html,/input\{direction:ltr/);
    assert.doesNotMatch(html,language==='he'?/יצירה, עריכה ומחיקה של משימות/:/Create, edit and delete your tasks/);
  }
});

test('OAuth validation keeps pending language and never reflects submitted or upstream markup',async t=>{
  const f=await fixture(t);
  const he=await f.authorize({ui_locales:'he'});
  const invalid=await f.post('/oauth/login',{request:he.request,email:'<script>unsafe-email</script>',password:'x'},
    {'accept-language':'en'});
  const invalidHTML=await invalid.text();
  assertPage(invalidHTML,'he');
  assert.match(invalidHTML,/role="alert"/);
  assert.match(invalidHTML,/כתובת דוא&quot;ל או סיסמה לא תקינה/);
  assert.doesNotMatch(invalidHTML,/<script>|unsafe-email/);
  const en=await f.authorize({ui_locales:'en'});
  const mismatch=await f.post('/oauth/create-account',{request:en.request,email:'fixture@example.invalid',
    password:'synthetic-password',confirm:'different-password'},{'accept-language':'he'});
  assert.match(await mismatch.text(),/The two passwords do not match/);
  f.rejectAccount();
  const rejected=await f.post('/oauth/login',{request:en.request,email:'fixture@example.invalid',
    password:'synthetic-password'});
  const rejectedHTML=await rejected.text();
  assertPage(rejectedHTML,'en');
  assert.match(rejectedHTML,/The email address or password is incorrect/);
  assert.doesNotMatch(rejectedHTML,/<script>|unsafe-account-error/);
});

test('OAuth terminal errors are localized documents and preserve the pending request language',async t=>{
  const f=await fixture(t);
  for(const language of ['he','en']) {
    const invalid=await f.authorize({ui_locales:language,code_challenge:'invalid'});
    assert.equal(invalid.response.status,400);
    assertPage(invalid.html,language);
    assert.match(invalid.html,/role="alert"/);
    const page=await f.authorize({ui_locales:language});
    const wrongOrigin=await f.post('/oauth/login',{request:page.request,email:'fixture@example.invalid',
      password:'synthetic-password'},{origin:'https://foreign.example','accept-language':language==='he'?'en':'he'});
    assert.equal(wrongOrigin.status,403);
    const originHTML=await wrongOrigin.text();
    assertPage(originHTML,language);
    assert.match(originHTML,language==='he'?/מקור הבקשה אינו תקין/:/Invalid request origin/);
    f.gateway.store.pending[page.request].failures=7;
    const limited=await f.post('/oauth/login',{request:page.request});
    assert.equal(limited.status,429);
    assertPage(await limited.text(),language);
    f.gateway.store.pending[page.request].expires=0;
    const expired=await f.post('/oauth/login',{request:page.request},
      {'accept-language':language==='he'?'en':'he'});
    assert.equal(expired.status,400);
    const expiredHTML=await expired.text();
    assertPage(expiredHTML,language);
    assert.match(expiredHTML,language==='he'?/החיבור פג תוקף/:/Authorization request expired/);
  }
  assert.equal(f.pbCalls(),0);
});

test('OAuth language switch changes only language and does not create or extend authorization',async t=>{
  const f=await fixture(t);
  const page=await f.authorize({ui_locales:'he'});
  const before=structuredClone(f.gateway.store.pending[page.request]);
  f.advance(120000);
  const switched=await f.post('/oauth/language',{request:page.request,language:'en',
    client_id:'attacker',redirect_uri:'https://foreign.example',scope:'gsd.write offline_access',
    state:'changed',code_challenge:'changed',expires:9999999999999,failures:0},{origin:browserOrigin});
  assert.equal(switched.status,200);
  assertPage(await switched.text(),'en');
  assert.deepEqual(f.gateway.store.pending[page.request],{...before,language:'en'});
  assert.deepEqual(f.gateway.store.codes,{});
  assert.deepEqual(f.gateway.store.access,{});
  assert.deepEqual(f.gateway.store.refresh,{});
  assert.equal(f.pbCalls(),0);
  f.advance(480000);
  const expired=await f.post('/oauth/language',{request:page.request,language:'he'},{origin:browserOrigin});
  assert.equal(expired.status,400);
  assertPage(await expired.text(),'en');
  assert.deepEqual(f.gateway.store.pending[page.request],{...before,language:'en'});
});

test('OAuth language switch rejects foreign or absent origin, invalid locales and inherited request names',async t=>{
  const f=await fixture(t);
  const page=await f.authorize({ui_locales:'he'});
  const before=structuredClone(f.gateway.store.pending[page.request]);
  for(const headers of [{origin:'https://foreign.example'},{}]) {
    const denied=await f.post('/oauth/language',{request:page.request,language:'en'},headers);
    assert.equal(denied.status,403);
    assertPage(await denied.text(),'he');
  }
  const invalid=await f.post('/oauth/language',{request:page.request,language:'"><script>unsafe-locale</script>'},
    {origin:browserOrigin});
  assert.equal(invalid.status,400);
  const invalidHTML=await invalid.text();
  assertPage(invalidHTML,'he');
  assert.doesNotMatch(invalidHTML,/<script>|unsafe-locale/);
  const inherited=await f.post('/oauth/language',{request:'__proto__',language:'en'},{origin:browserOrigin});
  assert.equal(inherited.status,400);
  assert.equal(Object.prototype.language,undefined);
  assert.deepEqual(f.gateway.store.pending[page.request],before);
  assert.equal(f.pbCalls(),0);
});

test('OAuth login after language switch retains original state, PKCE, client, redirect and scopes',async t=>{
  const f=await fixture(t);
  const page=await f.authorize({ui_locales:'he'});
  const switched=await f.post('/oauth/language',{request:page.request,language:'en',
    scope:'gsd.write',state:'changed',client_id:'changed',redirect_uri:'https://foreign.example'},
    {origin:browserOrigin});
  assert.equal(switched.status,200);
  await switched.text();
  const login=await f.post('/oauth/login',{request:page.request,email:'fixture@example.invalid',
    password:'synthetic-password'},{origin:browserOrigin});
  assert.equal(login.status,302);
  const callback=new URL(login.headers.get('location'));
  assert.equal(callback.origin+callback.pathname,f.query.redirect_uri);
  assert.equal(callback.searchParams.get('state'),f.query.state);
  const exchange=await f.post('/oauth/token',{grant_type:'authorization_code',client_id:f.query.client_id,
    redirect_uri:f.query.redirect_uri,code:callback.searchParams.get('code'),code_verifier:f.verifier,
    resource:publicOrigin+'/mcp'});
  assert.equal(exchange.status,200);
  const grant=await exchange.json();
  assert.equal(grant.scope,'gsd.read');
  assert.ok(grant.access_token);
  assert.equal(grant.refresh_token,undefined);
  assert.equal(f.pbCalls(),1);
});

test('Malformed browser requests get localized HTML while OAuth protocol errors remain JSON',async t=>{
  const f=await fixture(t);
  const malformed=await fetch(f.origin+'/oauth/login',{method:'POST',
    headers:{'content-type':'application/x-www-form-urlencoded','accept-language':'en'},
    body:'request='+('x'.repeat(9000))});
  assert.equal(malformed.status,400);
  assert.match(malformed.headers.get('content-type'),/text\/html/);
  assertPage(await malformed.text(),'en');
  const protocol=await f.post('/oauth/token',{grant_type:'not-a-grant'});
  assert.equal(protocol.status,400);
  assert.match(protocol.headers.get('content-type'),/application\/json/);
  assert.equal((await protocol.json()).error,'unsupported_grant_type');
});
