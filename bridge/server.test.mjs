import { test } from 'node:test';
import http from 'node:http';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomBytes } from 'node:crypto';
import { createBridge } from './server.mjs';

test('OAuth pairing, MCP auth and real device tool round trip without storing task data', async () => {
  const folder=mkdtempSync(path.join(tmpdir(),'gsd-bridge-'));
  const bridge=createBridge({statePath:path.join(folder,'state.json')});
  await new Promise(resolve=>bridge.server.listen(0,'127.0.0.1',resolve));
  const base=bridge.getPublicBase();
  const client=async(uri,opts={})=>{
    const r=await fetch(base+uri,opts);
    const text=await r.text();
    let j;try{j=JSON.parse(text)}catch{j=text}
    return {status:r.status,json:j,headers:r.headers};
  };
  const jsonPost=(obj,auth)=>({
    method:'POST',headers:{
      'Content-Type':'application/json',
      ...(auth?{Authorization:'Bearer '+auth}:{})},
    body:JSON.stringify(obj)
  });
  try {
    const hello=await client('/mcp',jsonPost({jsonrpc:'2.0',id:1,method:'initialize'}));
    assert.equal(hello.status,200);
    assert.equal(hello.json.result.serverInfo.name,'GSD Remote MCP Bridge');

    const unauth=await client('/mcp',jsonPost({jsonrpc:'2.0',id:2,method:'tools/list'}));
    assert.equal(unauth.status,401);
    assert.match(unauth.headers.get('www-authenticate'),/resource_metadata/);

    const secret=randomBytes(32).toString('base64url');
    const deviceId='device-test-12345';
    const catalog=[{
      name:'get_dashboard',description:'Read task dashboard',
      writes:false,inputSchema:{type:'object',additionalProperties:false,properties:{}}
    },{
      name:'create_task',description:'Create a task requiring host consent',
      writes:true,inputSchema:{type:'object',additionalProperties:false,
        properties:{title:{type:'string',minLength:1,maxLength:500}},required:['title']}
    }];
    const enrolled=await client('/v1/device/register',jsonPost({deviceId,catalog},secret));
    assert.equal(enrolled.status,200);
    assert.equal(enrolled.json.pairingCode.length,8);
    const repeatWrong=await client('/v1/device/register',jsonPost({deviceId,catalog},'wrong'));
    assert.equal(repeatWrong.status,403);
    const verifier=randomBytes(40).toString('base64url');
    const challenge=createHash('sha256').update(verifier).digest('base64url');
    const registered=await client('/oauth/register',jsonPost({
      client_name:'ChatGPT',redirect_uris:['https://chatgpt.com/connector_platform_oauth_redirect']
    }));
    assert.equal(registered.status,201);
    const clientId=registered.json.client_id;
    const callback=registered.json.redirect_uris[0];
    const args=new URLSearchParams({
      client_id:clientId,response_type:'code',redirect_uri:callback,
      code_challenge:challenge,code_challenge_method:'S256',state:'opaque-state'
    });
    const auth=await client('/oauth/authorize?'+args.toString());
    assert.equal(auth.status,200);
    const policy=auth.headers.get('content-security-policy');
    assert.match(policy,/default-src 'none'/);
    assert.match(policy,/frame-ancestors 'none'/);
    assert.doesNotMatch(policy,/form-action/i,
      'The consent form must permit Chromium to follow OAuth callback redirects');
    const request=auth.json.match(/name="request" value="([^"]+)"/)[1];
    const approve=await fetch(base+'/oauth/approve',{
      method:'POST',redirect:'manual',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({request,pair:enrolled.json.pairingCode})
    });
    assert.equal(approve.status,302);
    const location=new URL(approve.headers.get('location'));
    assert.equal(location.searchParams.get('state'),'opaque-state');
    const code=location.searchParams.get('code');
    const allowedSameFormRetry=await client('/oauth/approve',{
      method:'POST',redirect:'manual',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({request,pair:enrolled.json.pairingCode})});
    assert.equal(allowedSameFormRetry.status,302);
    const replayCode=new URL(allowedSameFormRetry.headers.get('location'))
      .searchParams.get('code');
    assert.ok(replayCode && replayCode!==code);
    const invalidPair=await client('/oauth/approve',{
      method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({request,pair:'ABCDEFGH'})});
    assert.equal(invalidPair.status,200);
    assert.match(invalidPair.json,/Invalid or expired code/);
    const form=new URLSearchParams({
      grant_type:'authorization_code',code:replayCode,client_id:clientId,
      redirect_uri:callback,code_verifier:verifier
    });
    const token=await client('/oauth/token',{
      method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:form.toString()
    });
    assert.equal(token.status,200);
    assert.equal(token.json.token_type,'Bearer');
    const bearer=token.json.access_token;
    const discovered=await client('/mcp',jsonPost({jsonrpc:'2.0',id:3,method:'tools/list'},bearer));
    assert.equal(discovered.status,200);
    assert.equal(discovered.json.result.tools.length,2);
    assert.deepEqual(discovered.json.result.tools.map(t=>t.name),['get_dashboard','create_task']);

    const inFlight=client('/mcp',jsonPost({
      jsonrpc:'2.0',id:4,method:'tools/call',
      params:{name:'get_dashboard',arguments:{}}
    },bearer));
    const polled=await client('/v1/device/poll?device_id='+deviceId,{
      headers:{Authorization:'Bearer '+secret}
    });
    // A tick lets the async MCP request enter the command queue.
    let cmd=polled.json.commands[0];
    if(!cmd){
      await new Promise(r=>setTimeout(r,40));
      const retry=await client('/v1/device/poll?device_id='+deviceId,{headers:{Authorization:'Bearer '+secret}});
      cmd=retry.json.commands[0];
    }
    assert.equal(cmd.name,'get_dashboard');
    const finish=await client('/v1/device/result',jsonPost({
      deviceId,id:cmd.id,text:'{"tasks":[{"title":"Plan week"}]}',error:false
    },secret));
    assert.equal(finish.status,200);
    const done=await inFlight;
    assert.equal(done.status,200);
    assert.equal(done.json.result.content[0].text,'{"tasks":[{"title":"Plan week"}]}');
    assert.equal(bridge.commands.size,0);
    assert.equal(bridge.outstanding.size,0);

    // Wrong bearer cannot push task changes into the same device.
    const invalid=await client('/v1/device/result',jsonPost({
      deviceId,id:'not-real',text:'{"ok":true}',error:false},'wrong'));
    assert.equal(invalid.status,401);
    const unsupported=await client('/mcp',jsonPost({
      jsonrpc:'2.0',id:5,method:'tools/call',params:{name:'delete_everything',arguments:{}}
    },bearer));
    assert.equal(unsupported.json.result.isError,true);
    assert.equal(Object.values(bridge.store.devices).length,1);
  } finally {
    await bridge.close();
    rmSync(folder,{recursive:true,force:true});
  }
});

test('subpath proxy preserves discovery, browser consent and MCP device round trip', async () => {
  const folder=mkdtempSync(path.join(tmpdir(),'gsd-subpath-'));
  const requested=[];
  let upstream;
  const metadataRoutes=new Map([
    ['/.well-known/oauth-authorization-server/gsd','/.well-known/oauth-authorization-server'],
    ['/.well-known/oauth-protected-resource/gsd/mcp','/.well-known/oauth-protected-resource']
  ]);
  const proxy=http.createServer((req,res)=>{
    const url=new URL(req.url,'http://localhost');
    requested.push(url.pathname);
    // The root belongs to another service, as with the shared Funnel host.
    const route=metadataRoutes.get(url.pathname) ||
      (url.pathname.startsWith('/gsd/')?url.pathname.slice(4):null);
    if(!route){res.writeHead(418);return res.end('Wrong service');}
    const target=new URL(route+url.search,upstream);
    const forward=http.request(target,{method:req.method,headers:req.headers},reply=>{
      res.writeHead(reply.statusCode,reply.headers);
      reply.pipe(res);
    });
    forward.on('error',()=>{res.writeHead(502);res.end();});
    req.pipe(forward);
  });
  await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
  const origin='http://127.0.0.1:'+proxy.address().port;
  const base=origin+'/gsd';
  const bridge=createBridge({statePath:path.join(folder,'state.json'),publicOrigin:base});
  await new Promise(resolve=>bridge.server.listen(0,'127.0.0.1',resolve));
  upstream='http://127.0.0.1:'+bridge.server.address().port;
  const jsonPost=(body,token)=>({method:'POST',headers:{
    'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})
  },body:JSON.stringify(body)});
  try {
    const challenge=await fetch(base+'/mcp',
      jsonPost({jsonrpc:'2.0',id:1,method:'tools/list'}));
    assert.equal(challenge.status,401);
    const resourceURL=challenge.headers.get('www-authenticate')
      .match(/resource_metadata="([^"]+)"/)[1];
    const resource=await (await fetch(resourceURL)).json();
    assert.equal(resource.resource,base+'/mcp');
    const canonicalResource=await (await fetch(
      origin+'/.well-known/oauth-protected-resource/gsd/mcp')).json();
    assert.deepEqual(canonicalResource,resource);
    const issuer=new URL(resource.authorization_servers[0]);
    const discovery=new URL('/.well-known/oauth-authorization-server'+issuer.pathname,issuer);
    const metadata=await (await fetch(discovery)).json();
    assert.equal(metadata.issuer,base);
    assert.equal(metadata.authorization_endpoint,base+'/oauth/authorize');

    const secret=randomBytes(32).toString('base64url');
    const deviceId='subpath-test-device';
    const catalog=[{name:'get_dashboard',description:'Read dashboard',writes:false,
      inputSchema:{type:'object',additionalProperties:false,properties:{}}}];
    const pairing=await (await fetch(base+'/v1/device/register',
      jsonPost({deviceId,catalog},secret))).json();
    const registered=await (await fetch(metadata.registration_endpoint,jsonPost({
      client_name:'Subpath acceptance',redirect_uris:['https://chatgpt.com/connector_platform_oauth_redirect']
    }))).json();
    const verifier=randomBytes(40).toString('base64url');
    const authURL=new URL(metadata.authorization_endpoint);
    authURL.search=new URLSearchParams({
      client_id:registered.client_id,response_type:'code',
      redirect_uri:registered.redirect_uris[0],
      code_challenge:createHash('sha256').update(verifier).digest('base64url'),
      code_challenge_method:'S256',state:'subpath-state'
    }).toString();
    const page=await (await fetch(authURL)).text();
    const request=page.match(/name="request" value="([^"]+)"/)[1];
    // Follow the action rendered to the browser, never a hardcoded test URL.
    const action=new URL(page.match(/<form[^>]+action="([^"]+)"/)[1],authURL);
    const approved=await fetch(action,{method:'POST',redirect:'manual',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({request,pair:pairing.pairingCode})});
    assert.equal(approved.status,302,'The consent form must post to the GSD service');
    assert.equal(action.pathname,'/gsd/oauth/approve');
    const callback=new URL(approved.headers.get('location'));
    assert.equal(callback.searchParams.get('state'),'subpath-state');
    const tokenResponse=await fetch(metadata.token_endpoint,{method:'POST',
      headers:{'Content-Type':'application/x-www-form-urlencoded'},
      body:new URLSearchParams({grant_type:'authorization_code',
        code:callback.searchParams.get('code'),client_id:registered.client_id,
        redirect_uri:registered.redirect_uris[0],code_verifier:verifier})});
    assert.equal(tokenResponse.status,200);
    const token=(await tokenResponse.json()).access_token;
    const listed=await (await fetch(base+'/mcp',jsonPost({
      jsonrpc:'2.0',id:2,method:'tools/list'},token))).json();
    assert.deepEqual(listed.result.tools.map(t=>t.name),['get_dashboard']);

    const inFlight=fetch(base+'/mcp',jsonPost({
      jsonrpc:'2.0',id:3,method:'tools/call',
      params:{name:'get_dashboard',arguments:{}}},token));
    let command;
    for(let retry=0;retry<10&&!command;retry++){
      const poll=await (await fetch(base+'/v1/device/poll?device_id='+deviceId,
        {headers:{Authorization:'Bearer '+secret}})).json();
      command=poll.commands[0];
      if(!command)await new Promise(resolve=>setTimeout(resolve,20));
    }
    assert.equal(command?.name,'get_dashboard');
    const result=await fetch(base+'/v1/device/result',jsonPost({
      deviceId,id:command.id,text:'{"total":0}',error:false},secret));
    assert.equal(result.status,200);
    const completed=await (await inFlight).json();
    assert.equal(completed.result.content[0].text,'{"total":0}');
    assert.ok(requested.every(route=>route.startsWith('/gsd/') || metadataRoutes.has(route)),
      'No GSD request may escape to the unrelated root service');
  } finally {
    for(const pending of bridge.outstanding.values()){
      clearTimeout(pending.timer);
      pending.resolve({isError:true,content:[]});
    }
    await new Promise(resolve=>proxy.close(resolve));
    await bridge.close();
    rmSync(folder,{recursive:true,force:true});
  }
});

test('native-size UTF-8 results cross the relay while other request limits stay bounded', async () => {
  const folder=mkdtempSync(path.join(tmpdir(),'gsd-result-budget-'));
  const bridge=createBridge({statePath:path.join(folder,'state.json')});
  await new Promise(resolve=>bridge.server.listen(0,'127.0.0.1',resolve));
  const base=bridge.getPublicBase();
  const deviceId='result-budget-device';
  const secret=randomBytes(32).toString('base64url');
  const bearer=randomBytes(32).toString('base64url');
  const hash=value=>createHash('sha256').update(value).digest('hex');
  const catalog=[{name:'get_dashboard',description:'Synthetic result transport',
    writes:false,inputSchema:{type:'object',properties:{},additionalProperties:false}}];
  // OAuth is covered above; this fixture isolates the result transport budget.
  bridge.store.devices[deviceId]={
    secretHash:hash(secret),catalog,linked:true,lastSeen:Date.now()
  };
  bridge.store.tokens[hash(bearer)]={
    deviceId,clientId:'result-budget-client',expires:Date.now()+60000
  };
  const jsonPost=(body,token)=>({
    method:'POST',headers:{'Content-Type':'application/json',
      Authorization:'Bearer '+token},body:JSON.stringify(body)
  });
  try {
    const oversizedRegistration=await fetch(base+'/v1/device/register',jsonPost({
      deviceId:'result-budget-other',catalog,padding:'x'.repeat(128*1024)
    },secret));
    assert.equal(oversizedRegistration.status,400,
      'Ordinary device requests must retain the 128 KiB body limit');
    assert.equal((await oversizedRegistration.json()).error,'invalid_request');
    assert.equal(Object.keys(bridge.store.devices).length,1,
      'Rejected oversized enrollment must not mutate device state');

    const inFlight=fetch(base+'/mcp',jsonPost({
      jsonrpc:'2.0',id:1,method:'tools/call',
      params:{name:'get_dashboard',arguments:{}}
    },bearer)).then(response=>response.json())
      .then(value=>({value}),error=>({error}));
    let command;
    for(let retry=0;retry<10&&!command;retry++){
      const polled=await (await fetch(base+'/v1/device/poll?device_id='+deviceId,
        {headers:{Authorization:'Bearer '+secret}})).json();
      command=polled.commands[0];
      if(!command)await new Promise(resolve=>setTimeout(resolve,20));
    }
    assert.equal(command?.name,'get_dashboard');

    const nativeLimit=1024*1024;
    const tooLarge='\u05d0'.repeat(nativeLimit/2)+'a';
    assert.equal(Buffer.byteLength(tooLarge,'utf8'),nativeLimit+1);
    assert.ok(tooLarge.length<nativeLimit,
      'This regression must distinguish UTF-8 bytes from JS character count');
    const rejected=await fetch(base+'/v1/device/result',jsonPost({
      deviceId,id:command.id,text:tooLarge,error:false
    },secret));
    assert.equal(rejected.status,400);
    assert.equal((await rejected.json()).error,'result_invalid');
    assert.ok(bridge.outstanding.has(command.id),
      'An invalid result must not consume an outstanding command');

    // Exercise multibyte data and JSON escaping at the exact native byte limit.
    const escapedNotes='"\\\n'.repeat(20000);
    const remaining=nativeLimit-Buffer.byteLength(
      JSON.stringify({fixture:true,notes:escapedNotes}),'utf8');
    const notes=escapedNotes+'\u05d0'.repeat(Math.floor(remaining/2))+
      'a'.repeat(remaining%2);
    const text=JSON.stringify({fixture:true,notes});
    assert.equal(Buffer.byteLength(text,'utf8'),nativeLimit);
    const packet=jsonPost({deviceId,id:command.id,text,error:false},secret);
    assert.ok(Buffer.byteLength(packet.body,'utf8')>128*1024);
    const accepted=await fetch(base+'/v1/device/result',packet);
    assert.equal(accepted.status,200);
    assert.equal((await accepted.json()).accepted,true);
    const completed=await inFlight;
    if(completed.error)throw completed.error;
    assert.equal(completed.value.result.isError,false);
    assert.ok(completed.value.result.content[0].text===text,
      'The exact native result must survive JSON encoding and MCP delivery');
    assert.equal(bridge.commands.size,0);
    assert.equal(bridge.outstanding.size,0);
  } finally {
    for(const pending of bridge.outstanding.values()){
      clearTimeout(pending.timer);
      pending.resolve({isError:true,content:[]});
    }
    await bridge.close();
    rmSync(folder,{recursive:true,force:true});
  }
});
