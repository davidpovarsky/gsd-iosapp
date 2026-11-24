import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createHash, randomBytes} from 'node:crypto';
import {createGateway} from './server.mjs';

const publicOrigin = 'https://cloud.example/gsd-cloud';
const password = 'Isolated acceptance password';
const email = 'fixture@example.invalid';

// Only the upstream account response is controlled. HTTP parsing, attempt
// accumulation, pending grants, expiry and token exchange use the actual gateway.
async function fixture(t) {
  const stateDir = await fs.mkdtemp(path.join(os.tmpdir(), 'gsd-rate-acceptance-'));
  let now = Date.UTC(2026, 10, 24, 12), calls = 0, reject = true, lastRequest;
  const upstream = http.createServer(async (req, res) => {
    const parts = [];
    for await (const part of req) parts.push(part);
    lastRequest = {bytes: Buffer.concat(parts), contentType: req.headers['content-type'], path: req.url};
    calls++;
    res.writeHead(reject ? 400 : 200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify(reject ? {message: 'Fixture authentication denied'} : {
      token: 'h.' + Buffer.from(JSON.stringify({id: 'fixtureuser0001', exp: 9999999999}))
        .toString('base64url') + '.s',
      record: {id: 'fixtureuser0001', email},
    }));
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const gateway = createGateway({publicOrigin, stateDir, clock: () => now,
    pbOrigin: 'http://127.0.0.1:' + upstream.address().port});
  await new Promise(resolve => gateway.server.listen(0, '127.0.0.1', resolve));
  const address = 'http://127.0.0.1:' + gateway.server.address().port;
  t.after(async () => {
    gateway.server.closeAllConnections();
    await gateway.close();
    upstream.closeAllConnections();
    await new Promise(resolve => upstream.close(resolve));
    await fs.rm(stateDir, {recursive: true, force: true});
  });
  const request = async (route, body = null, {form = false, ip, raw, contentType} = {}) => {
    const hasBody = body !== null || raw !== undefined;
    const response = await fetch(address + route, {
      method: hasBody ? 'POST' : 'GET', redirect: 'manual',
      signal: AbortSignal.timeout(5000),
      headers: {Origin: new URL(publicOrigin).origin,
        ...(ip ? {'X-Forwarded-For': ip} : {}),
        ...(!hasBody ? {} : {'Content-Type': contentType || (form
          ? 'application/x-www-form-urlencoded' : 'application/json')})},
      body: raw !== undefined ? raw : body === null ? undefined
        : form ? new URLSearchParams(body) : JSON.stringify(body),
    });
    const text = await response.text();
    let value;
    try { value = JSON.parse(text); } catch { value = text; }
    return {status: response.status, value, headers: response.headers};
  };
  const redirect = 'http://127.0.0.1:8765/callback';
  const registered = await request('/oauth/register', {redirect_uris: [redirect]});
  assert.equal(registered.status, 201);
  const client = registered.value.client_id;
  const begin = async () => {
    const verifier = randomBytes(48).toString('base64url');
    const page = await request('/oauth/authorize?' + new URLSearchParams({
      client_id: client, redirect_uri: redirect, response_type: 'code',
      code_challenge_method: 'S256',
      code_challenge: createHash('sha256').update(verifier).digest('base64url'),
      scope: 'gsd.read offline_access', state: 'isolated-rate-state',
      resource: publicOrigin + '/mcp', ui_locales: 'en',
    }));
    assert.equal(page.status, 200);
    const match = page.value.match(/name="request" value="([^"]+)"/);
    assert.ok(match);
    return {id: match[1], client, verifier, redirect};
  };
  const approve = (grant, route = '/oauth/login', account = email, ip) =>
    request(route, {request: grant.id, email: account, password, confirm: password},
      {form: true, ip});
  return {gateway, request, begin, approve, calls: () => calls, lastRequest: () => lastRequest,
    advance: value => { now += value; }, allow: () => { reject = false; }};
}

for (const route of ['/oauth/login', '/oauth/create-account']) {
  test(route + ' accumulates seven real upstream failures and blocks the grant without mutation',
    {timeout: 15000}, async t => {
      const f = await fixture(t);
      const grant = await f.begin();
      const original = structuredClone(f.gateway.store.pending[grant.id]);
      for (let attempt = 1; attempt <= 7; attempt++) {
        const response = await f.approve(grant, route,
          attempt % 2 ? email : email.toUpperCase());
        assert.equal(response.status, 200);
        assert.equal(f.gateway.store.pending[grant.id].failures, attempt);
        assert.equal(f.calls(), attempt);
      }
      const rejected = await f.approve(grant, route, 'different@example.invalid');
      assert.equal(rejected.status, 429);
      assert.equal(f.calls(), 7, 'The rejected attempt never reaches the account service');
      assert.equal(f.gateway.store.pending[grant.id].expires, original.expires);
      assert.deepEqual(f.gateway.store.codes, {});
      assert.deepEqual(f.gateway.store.access, {});
      assert.deepEqual(f.gateway.store.refresh, {});
      f.advance(600001);
      assert.equal((await f.approve(grant, route)).status, 400,
        'The expired grant is not silently unlocked');
      f.allow();
      assert.equal((await f.approve(await f.begin())).status, 302,
        'A fresh valid grant can authenticate after the old grant expires');
    });
}

test('OAuth IP limit accumulates actual failures across grants and recovers only after its window',
  {timeout: 15000}, async t => {
    const f = await fixture(t);
    for (let attempt = 0; attempt < 22; attempt++) {
      const route = attempt % 2 ? '/oauth/login' : '/oauth/create-account';
      assert.equal((await f.approve(await f.begin(), route,
        'attempt' + attempt + '@example.invalid')).status, 200);
    }
    assert.equal(f.calls(), 22);
    const blocked = await f.begin();
    assert.equal((await f.approve(blocked)).status, 429);
    assert.equal(f.calls(), 22);
    f.advance(900000);
    const fresh = await f.begin();
    assert.equal((await f.approve(fresh)).status, 429, 'The exact window boundary remains closed');
    assert.equal(f.calls(), 22);
    f.advance(1);
    f.allow();
    const approved = await f.approve(fresh);
    assert.equal(approved.status, 302);
    assert.equal(f.calls(), 23);
    const callback = new URL(approved.headers.get('location'));
    const exchange = await f.request('/oauth/token', {
      grant_type: 'authorization_code', client_id: fresh.client,
      redirect_uri: fresh.redirect, code: callback.searchParams.get('code'),
      code_verifier: fresh.verifier, resource: publicOrigin + '/mcp',
    }, {form: true});
    assert.equal(exchange.status, 200);
    assert.ok(exchange.value.access_token);
    assert.ok(exchange.value.refresh_token);
  });

test('REST signup accumulates seven rejected requests, isolates IPs and recovers after one hour',
  {timeout: 15000}, async t => {
    const f = await fixture(t);
    const signup = (number, ip) => f.request('/api/collections/users/records', {
      email: 'signup' + number + '@example.invalid', password, passwordConfirm: password,
    }, {ip});
    for (let attempt = 0; attempt < 7; attempt++) {
      assert.equal((await signup(attempt)).status, 400);
    }
    assert.equal(f.calls(), 7);
    const rejected = await signup(7);
    assert.equal(rejected.status, 429);
    assert.equal(rejected.value.error, 'signup_rate_limit');
    assert.equal(f.calls(), 7);
    // Documentation-only TEST-NET address, supplied solely inside the local fixture.
    assert.equal((await signup(8, '192.0.2.2')).status, 400);
    assert.equal(f.calls(), 8);
    f.advance(3600000);
    assert.equal((await signup(9)).status, 429);
    assert.equal(f.calls(), 8);
    f.advance(1);
    assert.equal((await signup(10)).status, 400);
    assert.equal(f.calls(), 9, 'The normal upstream validation response resumes');
    assert.deepEqual(f.gateway.store.codes, {});
    assert.deepEqual(f.gateway.store.access, {});
    assert.deepEqual(f.gateway.store.refresh, {});
  });


test('native password authentication shares one per-IP budget across body bindings and cooldown',
  {timeout: 15000}, async t => {
    const f = await fixture(t);
    const route = '/api/collections/users/auth-with-password';
    const multipart = '--fixture-boundary\r\nContent-Disposition: form-data; name="identity"\r\n\r\n'
      + email + '\r\n--fixture-boundary\r\nContent-Disposition: form-data; name="password"\r\n\r\n'
      + password + '\r\n--fixture-boundary--\r\n';
    const variants = [
      {raw: JSON.stringify({identity: email, password}), contentType: 'application/json'},
      {raw: new URLSearchParams({identity: email, password}).toString(),
        contentType: 'application/x-www-form-urlencoded'},
      {raw: multipart, contentType: 'multipart/form-data; boundary=fixture-boundary'},
      {raw: '{"Identity":' + JSON.stringify(email) + ',"identity":"other@example.invalid",'
        + '"password":' + JSON.stringify(password) + '} trailing',
        contentType: 'application/json'},
      {raw: '<auth><Identity>' + email + '</Identity><Password>' + password
        + '</Password></auth>', contentType: 'application/xml'},
      {raw: '{"identity":', contentType: 'application/json'},
      {raw: JSON.stringify({identity: 'Δοκιμή@example.invalid', password: 'סיסמה ' + password,
        ignored: 'x'.repeat(128 * 1024)}), contentType: 'application/json; charset=utf-8'},
    ];
    for (let attempt = 0; attempt < 22; attempt++) {
      const variant = variants[attempt % variants.length];
      const result = await f.request(route, null, variant);
      assert.equal(result.status, 400);
      assert.deepEqual(f.lastRequest().bytes, Buffer.from(variant.raw),
        'Every forwarded request preserves the exact original bytes');
      assert.equal(f.lastRequest().contentType, variant.contentType);
    }
    assert.equal(f.calls(), 22);
    const limited = await f.request(route, {identity: email, password});
    assert.equal(limited.status, 429);
    assert.deepEqual(limited.value, {status: 429,
      message: 'Too many authentication attempts. Please try again later.', data: {}});
    assert.equal(limited.headers.get('retry-after'), '900');
    assert.equal(f.calls(), 22, 'The limit is enforced before any upstream auth request');
    assert.equal((await f.request(route, {identity: email, password},
      {ip: '192.0.2.2'})).status, 400, 'A distinct fixture IP has its own budget');
    assert.equal(f.calls(), 23);
    f.advance(900000);
    assert.equal((await f.request(route, null, variants[1])).status, 429);
    assert.equal(f.calls(), 23);
    f.advance(1);
    f.allow();
    const accepted = await f.request(route, {identity: email, password});
    assert.equal(accepted.status, 200);
    assert.ok(accepted.value.token);
    assert.equal(f.calls(), 24);
  });

test('native password limit leaves refresh, signup, CRUD and OAuth budgets unchanged',
  {timeout: 15000}, async t => {
    const f = await fixture(t);
    for (let attempt = 0; attempt < 22; attempt++) {
      assert.equal((await f.request('/api/collections/users/auth-with-password',
        {identity: email, password: 'incorrect'})).status, 400);
    }
    assert.equal((await f.request('/api/collections/users/auth-with-password',
      {identity: email, password})).status, 429);
    f.allow();
    assert.equal((await f.request('/api/collections/users/auth-refresh', {})).status, 200);
    assert.equal((await f.request('/api/collections/users/records',
      {email: 'signup-independent@example.invalid', password, passwordConfirm: password})).status, 200);
    assert.equal((await f.request('/api/collections/tasks/records')).status, 200);
    assert.equal((await f.approve(await f.begin())).status, 302);
    assert.equal((await f.request('/api/collections/users/auth-with-password',
      {identity: email, password})).status, 429, 'Other routes do not clear the native budget');
  });
