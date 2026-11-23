import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomBytes, createHash } from 'node:crypto';

const expectedBase='https://torah-social.tail0a6c7d.ts.net:10000/gsd';
const configuredBase=process.env.GSD_BRIDGE_PUBLIC_BASE || process.argv[2] || expectedBase;
const receiptPath=path.resolve(process.env.GSD_ACCEPTANCE_RECEIPT ||
  'gsd-acceptance/receipt.json');
const runId=process.env.GITHUB_RUN_ID;
const deviceId='gsd-ci-'+(runId || randomBytes(8).toString('hex'));
const deviceSecret=randomBytes(32).toString('base64url');
const receipt={
  version:1,startedAt:new Date().toISOString(),finishedAt:null,result:'running',
  expectedBase,commit:process.env.GITHUB_SHA || null,runId:runId || null,
  runAttempt:process.env.GITHUB_RUN_ATTEMPT || null,
  fixture:{deviceId,clientId:null,synthetic:true},
  cleanup:{disconnectAttempted:false,disconnected:false,
    residualStateRemovalRequired:false,
    instruction:'Release owner must remove only this fixture device, client, and related auth records from GSD state after the run. Do not remove user records.'},
  checks:[],http:[]
};
let registrationAttempted=false;
let firstToken,accessToken,refreshToken;
let failed=false;

function saveReceipt(){
  fs.mkdirSync(path.dirname(receiptPath),{recursive:true});
  fs.writeFileSync(receiptPath,JSON.stringify(receipt,null,2)+'\n',{mode:0o600});
}
function safeError(error){
  return error?.name==='AssertionError' ? error.message :
    (error?.name || 'Error')+': network or protocol operation failed';
}
async function check(name,action){
  const entry={name,status:'running'};
  receipt.checks.push(entry);saveReceipt();
  try{
    await action();entry.status='passed';console.log('PASS '+name);
  }catch(error){
    entry.status='failed';entry.error=safeError(error);
    console.error('FAIL '+name+': '+entry.error);
    throw error;
  }finally{saveReceipt();}
}
async function request(label,url,options={},expected=200){
  const response=await fetch(url,{
    redirect:'error',signal:AbortSignal.timeout(20000),...options
  });
  receipt.http.push({check:label,status:response.status});saveReceipt();
  assert.ok(response.status===expected,
    label+': expected HTTP '+expected+', received '+response.status);
  return response;
}
async function jsonRequest(label,url,options={},expected=200){
  return (await request(label,url,options,expected)).json();
}
const jsonPost=(body,token)=>({
  method:'POST',headers:{'Content-Type':'application/json',
    ...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body)
});
const formPost=(body)=>({
  method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},
  body:new URLSearchParams(body)
});
const rpc=(id,method,params)=>({jsonrpc:'2.0',id,method,...(params?{params}:{})});

saveReceipt();
try{
  await check('fixed_public_https_target',async()=>{
    assert.ok(configuredBase.replace(/\/$/,'')===expectedBase,
      'Public acceptance target must be the expected isolated GSD HTTPS base');
    assert.ok(/^[0-9a-zA-Z_-]{8,80}$/.test(deviceId),'Invalid fixture identifier');
  });
  const base=expectedBase;
  const parsedBase=new URL(base);
  const origin=parsedBase.origin;
  await check('both_application_health_before',async()=>{
    const gsd=await jsonRequest('gsd_health_before',base+'/health');
    assert.ok(gsd.ok===true && gsd.name==='GSD Remote MCP Bridge','GSD health mismatch');
    const other=await jsonRequest('lorvex_health_before',origin+'/health');
    assert.ok(other.ok===true && other.name==='Lorvex Remote MCP Bridge',
      'Existing root application health mismatch');
  });
  let metadata;
  await check('canonical_resource_and_issuer_discovery',async()=>{
    const resource=await jsonRequest('canonical_resource_metadata',
      origin+'/.well-known/oauth-protected-resource'+parsedBase.pathname+'/mcp');
    assert.ok(resource.resource===base+'/mcp','Protected resource identifier mismatch');
    assert.ok(resource.authorization_servers?.includes(base),'GSD authorization server missing');
    metadata=await jsonRequest('canonical_authorization_metadata',
      origin+'/.well-known/oauth-authorization-server'+parsedBase.pathname);
    assert.ok(metadata.issuer===base,'Issuer must exactly match GSD public base');
    for(const [key,suffix] of Object.entries({
      authorization_endpoint:'/oauth/authorize',token_endpoint:'/oauth/token',
      registration_endpoint:'/oauth/register'
    }))assert.ok(metadata[key]===base+suffix,'Unexpected GSD '+key);
    assert.ok(metadata.code_challenge_methods_supported?.includes('S256'),'PKCE S256 missing');
    assert.ok(metadata.grant_types_supported?.includes('refresh_token'),'Refresh grant missing');
  });
  await check('unauthenticated_mcp_challenge',async()=>{
    const response=await request('unauthenticated_tools_list',base+'/mcp',
      jsonPost(rpc(1,'tools/list')),401);
    const challenge=response.headers.get('www-authenticate') || '';
    const advertised=challenge.match(/resource_metadata="([^"]+)"/)?.[1];
    assert.ok(advertised===base+'/.well-known/oauth-protected-resource',
      'MCP challenge must advertise the isolated GSD resource metadata');
    const resource=await jsonRequest('challenge_resource_metadata',advertised);
    assert.ok(resource.resource===base+'/mcp','Challenge resource metadata mismatch');
  });
  let pairing;
  await check('register_synthetic_device',async()=>{
    registrationAttempted=true;receipt.cleanup.residualStateRemovalRequired=true;saveReceipt();
    pairing=await jsonRequest('fixture_register',base+'/v1/device/register',
      jsonPost({deviceId,catalog:[{
        name:'get_dashboard',description:'Synthetic CI dashboard; no user tasks',
        writes:false,inputSchema:{type:'object',properties:{},additionalProperties:false}
      }]},deviceSecret));
    assert.ok(typeof pairing.pairingCode==='string' && pairing.pairingCode.length===8,
      'Fixture did not receive a pairing code');
  });
  let client;
  await check('dynamic_client_registration',async()=>{
    client=await jsonRequest('client_register',metadata.registration_endpoint,jsonPost({
      client_name:'GSD HTTPS acceptance '+deviceId,
      redirect_uris:['https://chatgpt.com/connector_platform_oauth_redirect']
    }),201);
    assert.ok(typeof client.client_id==='string','DCR client identifier missing');
    receipt.fixture.clientId=client.client_id;saveReceipt();
  });
  const verifier=randomBytes(40).toString('base64url');
  const callback='https://chatgpt.com/connector_platform_oauth_redirect';
  const state=randomBytes(16).toString('base64url');
  let authorizationCode;
  await check('actual_browser_form_action_and_pkce_consent',async()=>{
    const authorization=new URL(metadata.authorization_endpoint);
    authorization.search=new URLSearchParams({
      client_id:client.client_id,response_type:'code',redirect_uri:callback,
      code_challenge:createHash('sha256').update(verifier).digest('base64url'),
      code_challenge_method:'S256',state
    }).toString();
    const html=await (await request('authorization_page',authorization)).text();
    const requestId=html.match(/name="request" value="([^"]+)"/)?.[1];
    const renderedAction=html.match(/<form[^>]+action="([^"]+)"/)?.[1];
    assert.ok(requestId && renderedAction,'Consent form fields missing');
    const action=new URL(renderedAction,authorization);
    assert.ok(action.href===base+'/oauth/approve','Consent form escaped GSD path');
    const approval=await request('consent_post',action,{
      ...formPost({request:requestId,pair:pairing.pairingCode}),redirect:'manual'
    },302);
    const redirect=new URL(approval.headers.get('location'));
    assert.ok(redirect.origin+redirect.pathname===callback,'OAuth callback mismatch');
    assert.ok(redirect.searchParams.get('state')===state,'OAuth state mismatch');
    authorizationCode=redirect.searchParams.get('code');
    assert.ok(authorizationCode,'Authorization code missing');
  });
  await check('pkce_code_exchange_and_refresh_rotation',async()=>{
    const initial=await jsonRequest('authorization_code_exchange',metadata.token_endpoint,
      formPost({grant_type:'authorization_code',code:authorizationCode,
        client_id:client.client_id,redirect_uri:callback,code_verifier:verifier}));
    assert.ok(initial.token_type==='Bearer' && initial.access_token && initial.refresh_token,
      'OAuth token response incomplete');
    firstToken=initial.access_token;accessToken=firstToken;refreshToken=initial.refresh_token;
    const refreshed=await jsonRequest('refresh_exchange',metadata.token_endpoint,
      formPost({grant_type:'refresh_token',refresh_token:refreshToken,client_id:client.client_id}));
    assert.ok(refreshed.access_token && refreshed.refresh_token,
      'Refresh response incomplete');
    const oldRefresh=refreshToken;
    accessToken=refreshed.access_token;refreshToken=refreshed.refresh_token;
    await request('used_refresh_rejected',metadata.token_endpoint,
      formPost({grant_type:'refresh_token',refresh_token:oldRefresh,client_id:client.client_id}),400);
  });
  await check('authenticated_synthetic_tool_catalog',async()=>{
    const initialized=await jsonRequest('mcp_initialize',base+'/mcp',
      jsonPost(rpc(5,'initialize',{protocolVersion:'2025-06-18',capabilities:{},
        clientInfo:{name:'GSD synthetic HTTPS acceptance',version:'1.0.0'}}),accessToken));
    assert.ok(initialized.result?.serverInfo?.name==='GSD Remote MCP Bridge',
      'MCP initialization returned the wrong server');
    await request('mcp_initialized_notification',base+'/mcp',
      jsonPost({jsonrpc:'2.0',method:'notifications/initialized'},accessToken),202);
    const listed=await jsonRequest('authenticated_tools_list',base+'/mcp',
      jsonPost(rpc(2,'tools/list'),accessToken));
    assert.ok(listed.result?.tools?.length===1 &&
      listed.result.tools[0].name==='get_dashboard',
      'Fixture must expose only its synthetic dashboard tool');
  });
  await check('public_mcp_device_poll_result_roundtrip',async()=>{
    const inflight=jsonRequest('dashboard_call',base+'/mcp',{
      ...jsonPost(rpc(3,'tools/call',{name:'get_dashboard',arguments:{}}),accessToken),
      signal:AbortSignal.timeout(60000)
    }).then(value=>({value}),error=>({error}));
    let command;
    for(let attempt=0;attempt<30&&!command;attempt++){
      const poll=await jsonRequest('fixture_poll',base+'/v1/device/poll?device_id='+deviceId,
        {headers:{Authorization:'Bearer '+deviceSecret}});
      assert.ok(poll.linked===true,'Synthetic device is not linked');
      command=poll.commands?.[0];
      if(!command)await new Promise(resolve=>setTimeout(resolve,200));
    }
    assert.ok(command?.name==='get_dashboard','Dashboard command not delivered to fixture');
    assert.ok(command.argumentsJSON==='{}','Unexpected synthetic dashboard arguments');
    const synthetic='{"total":0,"open":0,"completed":0,"fixture":true}';
    await jsonRequest('fixture_result',base+'/v1/device/result',
      jsonPost({deviceId,id:command.id,text:synthetic,error:false},deviceSecret));
    const completed=await inflight;
    if(completed.error)throw completed.error;
    assert.ok(completed.value.result?.isError===false &&
      completed.value.result.content?.[0]?.text===synthetic,
      'Synthetic dashboard result did not complete the public MCP request');
  });
}catch(error){
  failed=true;receipt.error=safeError(error);
}finally{
  if(registrationAttempted){
    try{
      await check('disconnect_fixture_and_revoke_oauth',async()=>{
        receipt.cleanup.disconnectAttempted=true;saveReceipt();
        const reply=await jsonRequest('fixture_disconnect',
          expectedBase+'/v1/device/disconnect',jsonPost({deviceId},deviceSecret));
        assert.ok(reply.disconnected===true,'Fixture disconnect was not acknowledged');
        receipt.cleanup.disconnected=true;saveReceipt();
        for(const token of new Set([firstToken,accessToken].filter(Boolean))){
          await request('disconnected_access_rejected',expectedBase+'/mcp',
            jsonPost(rpc(4,'tools/list'),token),401);
        }
        if(refreshToken && receipt.fixture.clientId){
          await request('disconnected_refresh_rejected',expectedBase+'/oauth/token',
            formPost({grant_type:'refresh_token',refresh_token:refreshToken,
              client_id:receipt.fixture.clientId}),400);
        }
      });
    }catch(error){failed=true;receipt.cleanup.error=safeError(error);}
  }
  if(registrationAttempted){
    try{
      await check('both_application_health_after',async()=>{
        const gsd=await jsonRequest('gsd_health_after',expectedBase+'/health');
        assert.ok(gsd.ok===true && gsd.name==='GSD Remote MCP Bridge','GSD health mismatch');
        const other=await jsonRequest('lorvex_health_after',new URL(expectedBase).origin+'/health');
        assert.ok(other.ok===true && other.name==='Lorvex Remote MCP Bridge',
          'Existing root application health mismatch');
      });
    }catch(error){failed=true;}
  }
  receipt.result=failed?'failed':'passed';
  receipt.finishedAt=new Date().toISOString();saveReceipt();
  console.log('Receipt: '+receiptPath);
  console.log('Fixture cleanup required: '+(receipt.cleanup.residualStateRemovalRequired?'yes':'no'));
  process.exitCode=failed?1:0;
}
