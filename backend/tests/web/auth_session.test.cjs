const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../server/static/app.js'), 'utf8');
// Run the actual request implementation without booting the browser UI.
const requestCode = source.slice(0, source.indexOf('// ── Auth'));
function harness(user, fetch) {
  const context = vm.createContext({ fetch });
  vm.runInContext(requestCode + '\nglobalThis.call = authedFetch; globalThis.setUser = u => { signedInUser = u; };', context);
  context.setUser(user);
  return context;
}
function response(status, data = {}) {
  return {status, ok: status >= 200 && status < 300,
    headers: {get: () => 'application/json'}, json: async () => data,
    text: async () => JSON.stringify(data)};
}
test('delete fetches the current SDK token on every action', async () => {
  let token = 'first'; const sent = [];
  const h = harness({getIdToken: async () => token}, async (url, opts) => {
    sent.push(opts.headers.Authorization); return response(200);
  });
  await h.call('/books/disposable', {method: 'DELETE'});
  token = 'refreshed';
  await h.call('/books/disposable', {method: 'DELETE'});
  assert.deepEqual(sent, ['Bearer first', 'Bearer refreshed']);
});
test('an expired upload retries once with a refreshed token and the same form body', async () => {
  const refresh = []; const requests = []; const body = {file: 'public sample'};
  const h = harness({getIdToken: async force => {refresh.push(force); return force ? 'fresh' : 'expired';}}, async (url, opts) => {
    requests.push(opts); return response(requests.length === 1 ? 401 : 200, {job_id: 'test'});
  });
  assert.equal((await h.call('/books/upload', {method: 'POST', body})).job_id, 'test');
  assert.deepEqual(refresh, [false, true]);
  assert.equal(requests[0].body, body); assert.equal(requests[1].body, body);
  assert.equal(requests[1].headers.Authorization, 'Bearer fresh');
});
test('forbidden or failed mutations are not retried', async () => {
  for (const status of [403, 500]) {
    let calls = 0;
    const h = harness({getIdToken: async () => 'token'}, async () => {calls++; return response(status);});
    await assert.rejects(h.call('/books/disposable', {method: 'DELETE'}));
    assert.equal(calls, 1);
  }
});
test('a repeated unauthorized response stops after one refresh', async () => {
  let calls = 0;
  const h = harness({getIdToken: async () => 'token'}, async () => {calls++; return response(401);});
  await assert.rejects(h.call('/books/upload', {method: 'POST'}));
  assert.equal(calls, 2);
});
test('anonymous reads stay unsigned and are not retried', async () => {
  const calls=[]; const h = harness(null, async (_, opts) => {calls.push(opts);return response(200, []);});
  await h.call('/books'); assert.equal(calls.length, 1);
  assert.equal(calls[0].headers.Authorization, undefined);
});
test('token refresh failure never falls through to an unsigned mutation', async () => {
  let calls=0;
  const h=harness({getIdToken: async () => {throw new Error('refresh failed');}}, async () => {calls++;return response(200);});
  await assert.rejects(h.call('/books/disposable',{method:'DELETE'}));assert.equal(calls,0);
});
