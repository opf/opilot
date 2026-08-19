// Plain-Node test for authgw.js — the harness's only route to a model. No test
// framework (the repo has none for JS): run with `node test/js/authgw_test.js`.
//
// authgw had no tests at all before the upstream became configurable. What is
// covered here is the part that is silent when it breaks: the path allowlist,
// the /v1 prefix rewrite, the auth-header template, and address pinning. A
// wrong header still returns 200 from the upstream, so only an assertion
// catches it.
const assert = require('assert');
const {
  parseConfig, mapPath, buildHeaders, createHandler, createResolver,
} = require('../../authgw.js');

const GW = 'opilot-internal-gateway';

function env(extra = {}) {
  return { OPILOT_GW_TOKEN: GW, ...extra };
}

// Minimal req/res doubles. `req.pipe` is a no-op: nothing here asserts on the
// body, and authgw never reads it.
function fakeReq(overrides = {}) {
  return {
    method: 'POST',
    url: '/v1/chat/completions',
    headers: { authorization: `Bearer ${GW}`, 'content-type': 'application/json' },
    resume() {},
    pipe() {},
    ...overrides,
  };
}

function fakeRes() {
  return {
    statusCode: null, headers: null, body: '', headersSent: false,
    writeHead(code, headers) { this.statusCode = code; this.headers = headers; this.headersSent = true; },
    end(chunk) { if (chunk) this.body += chunk; },
  };
}

// Drives one request through the handler and reports what would have gone
// upstream. The outbound call is captured rather than made.
function run(cfg, req, { address = '10.0.0.9' } = {}) {
  let sent = null;
  const handler = createHandler(cfg, {
    request(options) {
      sent = options;
      return { on() {}, end() {}, write() {} };
    },
    address: () => address,
    invalidate: () => {},
  });
  const res = fakeRes();
  handler(req, res);
  return { sent, res };
}

let failures = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`PASS ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL ${name}\n  ${e.message}`);
  }
}

// ── config ────────────────────────────────────────────────────────────────

test('the default upstream is OpenRouter, so an untouched .env is unchanged', () => {
  const cfg = parseConfig(env());
  assert.strictEqual(cfg.host, 'openrouter.ai');
  assert.strictEqual(cfg.port, 443);
  assert.strictEqual(cfg.https, true);
  assert.strictEqual(cfg.pathPrefix, '/api/v1');
  assert.strictEqual(cfg.authHeader, 'authorization');
});

test('a plain-http self-hosted upstream keeps its port and prefix', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://10.0.0.5:8000/v1' }));
  assert.strictEqual(cfg.https, false);
  assert.strictEqual(cfg.host, '10.0.0.5');
  assert.strictEqual(cfg.port, 8000);
  assert.strictEqual(cfg.pathPrefix, '/v1');
});

test('a trailing slash does not double the path separator', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://h:1/v1/' }));
  assert.strictEqual(cfg.pathPrefix, '/v1');
  assert.strictEqual(mapPath(cfg, '/v1/models').path, '/v1/models');
});

test('a blank key is "keyless", not "missing"', () => {
  // Plenty of self-hosted servers want no key. Normalised to null so the
  // header is omitted rather than sent empty.
  assert.strictEqual(parseConfig(env()).apiKey, null);
  assert.strictEqual(parseConfig(env({ OPILOT_INFERENCE_KEY: '' })).apiKey, null);
  assert.strictEqual(parseConfig(env({ OPILOT_INFERENCE_KEY: 'sk-x' })).apiKey, 'sk-x');
});

test('a malformed config refuses to start rather than half-working', () => {
  assert.throws(() => parseConfig(env({ OPILOT_INFERENCE_URL: 'not a url' })), /not a URL/);
  assert.throws(() => parseConfig(env({ OPILOT_INFERENCE_URL: 'ftp://h/v1' })), /http or https/);
  assert.throws(() => parseConfig(env({ OPILOT_INFERENCE_AUTH: 'no-colon' })), /Header-Name/);
  assert.throws(() => parseConfig(env({ OPILOT_INFERENCE_AUTH: 'X: no placeholder' })), /\{key\}/);
  assert.throws(() => parseConfig(env({ OPILOT_INFERENCE_AUTH: 'bad header: {key}' })), /valid HTTP token/);
  assert.throws(() => parseConfig({}), /OPILOT_GW_TOKEN/);
});

// ── path mapping and the allowlist ────────────────────────────────────────

test('the client prefix is stripped and the upstream prefix re-applied', () => {
  const or = parseConfig(env());
  assert.strictEqual(mapPath(or, '/v1/chat/completions').path, '/api/v1/chat/completions');

  const local = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://10.0.0.5:8000/v1' }));
  assert.strictEqual(mapPath(local, '/v1/chat/completions').path, '/v1/chat/completions');
});

test('the prefix is not applied twice', () => {
  const cfg = parseConfig(env());
  const { path } = mapPath(cfg, '/v1/chat/completions');
  assert.strictEqual(path.indexOf('/api/v1'), path.lastIndexOf('/api/v1'), `doubled prefix: ${path}`);
});

test('a query string survives the rewrite', () => {
  const cfg = parseConfig(env());
  assert.strictEqual(mapPath(cfg, '/v1/models?limit=5').path, '/api/v1/models?limit=5');
});

test('every protocol the api field can select has an allowed path', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://h:1/v1' }));
  for (const p of ['chat/completions', 'messages', 'responses', 'models', 'credits', 'key']) {
    assert.ok(mapPath(cfg, `/v1/${p}`).path, `${p} should be allowed`);
  }
  // google-generative-ai puts the model in the path.
  assert.ok(mapPath(cfg, '/v1/models/gemini-3-pro:generateContent').path);
});

test('anything outside the allowlist is refused — Ollama pull is the case that matters', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://model:11434/v1' }));
  assert.ok(mapPath(cfg, '/v1/../api/pull').refuse);
  assert.ok(mapPath(cfg, '/api/pull').refuse);
  assert.ok(mapPath(cfg, '/v1/embeddings').refuse);
  assert.ok(mapPath(cfg, '/key/generate').refuse);
});

test('traversal cannot ride the models prefix rule out of the allowlist', () => {
  // `models` is a PREFIX rule, so without an explicit traversal check
  // "models/../../api/pull" passes the allowlist and is then normalised back
  // to /api/pull by the upstream. The allowlist must decide on the same string
  // the upstream acts on.
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://model:11434/v1' }));
  assert.ok(mapPath(cfg, '/v1/models/../../api/pull').refuse, 'plain traversal');
  assert.ok(mapPath(cfg, '/v1/models/%2e%2e/%2e%2e/api/pull').refuse, 'percent-encoded traversal');
  assert.ok(mapPath(cfg, '/v1/models/..').refuse);
  // A dot inside a model id is ordinary and must still work.
  assert.ok(mapPath(cfg, '/v1/models/qwen2.5-coder:7b').path);
});

test('the allowlist runs AFTER the /v1 strip, not before', () => {
  // Checking the raw url would refuse this, since "/v1/models" is not itself
  // an allowlist entry. The order is the bug this pins.
  const cfg = parseConfig(env());
  assert.strictEqual(mapPath(cfg, '/v1/models').path, '/api/v1/models');
});

// ── auth headers ──────────────────────────────────────────────────────────

test('the default template produces Authorization: Bearer <key>', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_KEY: 'sk-real' }));
  const out = buildHeaders({ authorization: `Bearer ${GW}` }, cfg);
  assert.strictEqual(out['authorization'], 'Bearer sk-real');
});

test('a custom header name is set AND Authorization is gone — the leak case', () => {
  // Azure OpenAI takes api-key, not Bearer. A set-without-delete would leave
  // our gateway handshake token in Authorization and ship it to Azure on every
  // call. This assertion is the guard against that; it is not redundant with
  // the one above.
  const cfg = parseConfig(env({
    OPILOT_INFERENCE_KEY: 'azure-32-hex',
    OPILOT_INFERENCE_AUTH: 'api-key: {key}',
  }));
  const out = buildHeaders({ authorization: `Bearer ${GW}`, 'content-type': 'application/json' }, cfg);
  assert.strictEqual(out['api-key'], 'azure-32-hex');
  assert.strictEqual('authorization' in out, false, 'Authorization must be deleted, not merely overwritten');
  assert.strictEqual(JSON.stringify(out).includes(GW), false, 'the gateway token must never leave this container');
  assert.strictEqual(out['content-type'], 'application/json', 'other headers pass through');
});

test('no key configured means no auth header at all, never the gateway token', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://model:11434/v1' }));
  const out = buildHeaders({ authorization: `Bearer ${GW}` }, cfg);
  assert.strictEqual('authorization' in out, false);
  assert.strictEqual(JSON.stringify(out).includes(GW), false);
});

test('a client-supplied copy of the configured header cannot pass through', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_AUTH: 'api-key: {key}' })); // no key
  const out = buildHeaders({ authorization: `Bearer ${GW}`, 'api-key': 'smuggled' }, cfg);
  assert.strictEqual('api-key' in out, false);
});

test('Host carries the hostname, not the pinned address', () => {
  const cfg = parseConfig(env());
  assert.strictEqual(buildHeaders({}, cfg)['host'], 'openrouter.ai');
});

// ── the handler end to end ────────────────────────────────────────────────

test('a wrong gateway token is 401 before any key is attached', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_KEY: 'sk-real' }));
  const { sent, res } = run(cfg, fakeReq({ headers: { authorization: 'Bearer wrong' } }));
  assert.strictEqual(res.statusCode, 401);
  assert.strictEqual(sent, null, 'nothing may be forwarded');
});

test('a refused path is 403 and never reaches the upstream', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://model:11434/v1' }));
  const { sent, res } = run(cfg, fakeReq({ url: '/api/pull' }));
  assert.strictEqual(res.statusCode, 403);
  assert.strictEqual(sent, null);
});

test('the outbound request goes to the pinned address with SNI on the name', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_KEY: 'sk-real' }));
  const { sent } = run(cfg, fakeReq(), { address: '104.18.0.7' });
  assert.strictEqual(sent.host, '104.18.0.7', 'connect by address, not name');
  assert.strictEqual(sent.servername, 'openrouter.ai', 'TLS still validates against the name');
  assert.strictEqual(sent.headers['host'], 'openrouter.ai');
  assert.strictEqual(sent.path, '/api/v1/chat/completions');
  assert.strictEqual(sent.port, 443);
});

test('a plain-http upstream sets no servername', () => {
  const cfg = parseConfig(env({ OPILOT_INFERENCE_URL: 'http://10.0.0.5:8000/v1' }));
  const { sent } = run(cfg, fakeReq());
  assert.strictEqual(sent.servername, undefined);
});

test('/health needs no token', () => {
  const cfg = parseConfig(env());
  const { res } = run(cfg, fakeReq({ method: 'GET', url: '/health', headers: {} }));
  assert.strictEqual(res.statusCode, 200);
});

// ── the resolver ──────────────────────────────────────────────────────────

// Awaited before the summary below — an async test left floating would report
// a pass and then throw into nothing.
async function asyncTests() {
  await testAsync('the address is resolved once and reused, then re-resolved after a failure', async () => {
    let calls = 0;
    const cfg = parseConfig(env());
    const resolver = createResolver(cfg, async () => ({ address: `10.0.0.${++calls}` }));

    assert.strictEqual(await resolver.ensure(), '10.0.0.1');
    assert.strictEqual(await resolver.ensure(), '10.0.0.1');
    assert.strictEqual(calls, 1, 'pinned — not re-resolved per request');

    resolver.invalidate();
    assert.strictEqual(await resolver.ensure(), '10.0.0.2', 'a failed connection re-resolves for the next one');
  });
}

async function testAsync(name, fn) {
  try {
    await fn();
    console.log(`PASS ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL ${name}\n  ${e.message}`);
  }
}

asyncTests().then(() => {
  console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
  process.exit(failures === 0 ? 0 : 1);
});
