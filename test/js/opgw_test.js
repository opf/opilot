// Plain-Node test for opgw.js — the harness's only route to the OpenProject
// MCP server. Run with `node test/js/opgw_test.js`.
//
// Unlike authgw, the allowlist here is on the JSON-RPC BODY, not the path —
// every call is the same POST /mcp — so what matters most is: a write tool
// (create_work_package) is refused, a batch/array body is refused, and a
// `tools/list` answer is trimmed to the read-only set before it reaches pi.
const assert = require('assert');
const {
  parseConfig, mapPath, checkMcpCall, filterToolsList, READ_ONLY_OPS, createHandler,
} = require('../../opgw.js');

const GW = 'opilot-internal-gateway';

function env(extra = {}) {
  return { OPENPROJECT_URL: 'https://qa.openproject-edge.com', OPENPROJECT_TOKEN: 'tok-abc',
           OPILOT_GW_TOKEN: GW, ...extra };
}

function fakeReq(overrides = {}) {
  return {
    method: 'POST',
    url: '/mcp',
    headers: { authorization: `Bearer ${GW}` },
    resume() {},
    on() {},
    destroy() {},
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

// Drives a body-carrying POST /mcp (or GET /tools) through the handler,
// feeding `body` as the request stream and capturing what would have gone
// upstream. The outbound call is captured rather than made; `upstreamStatus`/
// `upstreamBody` fake the upstream's answer for response-filtering tests.
function run(cfg, req, body, { address = '10.0.0.9', upstreamStatus = 200, upstreamBody = '{}' } = {}) {
  let sent = null;
  const handler = createHandler(cfg, {
    request(options, cb) {
      sent = options;
      const chunks = [];
      const up = {
        statusCode: upstreamStatus,
        headers: { 'content-type': 'application/json' },
        on(event, fn) {
          if (event === 'data') fn(Buffer.from(upstreamBody));
          if (event === 'end') fn();
        },
      };
      cb(up);
      return { on() {}, end(b) { if (b) chunks.push(b); } };
    },
    address: () => address,
    invalidate: () => {},
  });
  const res = fakeRes();
  const listeners = {};
  req.on = (event, fn) => { listeners[event] = fn; };
  handler(req, res);
  if (body !== undefined) {
    listeners.data && listeners.data(Buffer.from(body));
    listeners.end && listeners.end();
  }
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

test('config resolves from OPENPROJECT_URL, basic-auth credential built from the token', () => {
  const cfg = parseConfig(env());
  assert.strictEqual(cfg.host, 'qa.openproject-edge.com');
  assert.strictEqual(cfg.https, true);
  assert.strictEqual(cfg.port, 443);
  assert.strictEqual(cfg.pathPrefix, '');
  assert.strictEqual(cfg.authValue, `Basic ${Buffer.from('apikey:tok-abc').toString('base64')}`);
});

test('a sub-path instance keeps its prefix', () => {
  const cfg = parseConfig(env({ OPENPROJECT_URL: 'https://example.com/op/' }));
  assert.strictEqual(cfg.pathPrefix, '/op');
});

test('refuses to boot without OPENPROJECT_URL, OPENPROJECT_TOKEN or OPILOT_GW_TOKEN', () => {
  assert.throws(() => parseConfig({ OPENPROJECT_TOKEN: 't', OPILOT_GW_TOKEN: GW }), /OPENPROJECT_URL/);
  assert.throws(() => parseConfig({ OPENPROJECT_URL: 'https://h', OPILOT_GW_TOKEN: GW }), /OPENPROJECT_TOKEN/);
  assert.throws(() => parseConfig({ OPENPROJECT_URL: 'https://h', OPENPROJECT_TOKEN: 't' }), /OPILOT_GW_TOKEN/);
  assert.throws(() => parseConfig(env({ OPENPROJECT_URL: 'not a url' })), /not a URL/);
  assert.throws(() => parseConfig(env({ OPENPROJECT_URL: 'ftp://h' })), /http or https/);
});

// ── path mapping ─────────────────────────────────────────────────────────

test('only the exact client path is mapped', () => {
  const cfg = parseConfig(env());
  assert.strictEqual(mapPath(cfg, '/mcp', '/mcp').path, '/mcp');
  assert.ok(mapPath(cfg, '/other', '/mcp').refuse);
});

test('traversal is refused on the string actually used', () => {
  const cfg = parseConfig(env());
  assert.ok(mapPath(cfg, '/mcp/../api/pull', '/mcp').refuse);
  assert.ok(mapPath(cfg, '/mcp/%2e%2e/api/pull', '/mcp').refuse);
});

// ── the body allowlist ───────────────────────────────────────────────────

test('initialize and tools/list are allowed with no further check', () => {
  assert.deepStrictEqual(checkMcpCall({ jsonrpc: '2.0', id: 1, method: 'initialize' }), {});
  assert.deepStrictEqual(checkMcpCall({ jsonrpc: '2.0', id: 1, method: 'tools/list' }), {});
});

test('every read-only op is an allowed tools/call', () => {
  for (const name of READ_ONLY_OPS) {
    const result = checkMcpCall({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name } });
    assert.deepStrictEqual(result, {}, `${name} should be allowed`);
  }
});

test('a write tool is refused — this is the control, not a refinement', () => {
  for (const name of ['create_work_package', 'update_work_package', 'create_work_package_comment',
                       'create_work_package_relation', 'update_work_package_relation',
                       'delete_work_package_relation']) {
    const result = checkMcpCall({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name } });
    assert.ok(result.refuse, `${name} should be refused`);
  }
});

test('a method outside the three allowed is refused', () => {
  assert.ok(checkMcpCall({ jsonrpc: '2.0', id: 1, method: 'resources/list' }).refuse);
  assert.ok(checkMcpCall({ jsonrpc: '2.0', id: 1, method: 'notifications/initialized' }).refuse);
});

test('a batch (array) body is refused outright', () => {
  assert.ok(checkMcpCall([{ jsonrpc: '2.0', id: 1, method: 'tools/list' }]).refuse);
});

test('a malformed body (not an object) is refused', () => {
  assert.ok(checkMcpCall(null).refuse);
  assert.ok(checkMcpCall('tools/list').refuse);
});

// ── the tools/list response filter ──────────────────────────────────────

test('tools/list is trimmed to the read-only set', () => {
  const upstream = JSON.stringify({
    jsonrpc: '2.0', id: 1,
    result: { tools: [{ name: 'search_work_packages' }, { name: 'create_work_package' }] },
  });
  const out = JSON.parse(filterToolsList(Buffer.from(upstream)).toString());
  assert.deepStrictEqual(out.result.tools.map(t => t.name), ['search_work_packages']);
});

test('a non-tools/list shape (e.g. an error page) passes through untouched', () => {
  const raw = Buffer.from('<html>404 not found</html>');
  assert.strictEqual(filterToolsList(raw).toString(), raw.toString());
});

// ── the handler end to end ──────────────────────────────────────────────

test('no bearer token is 401 before anything is parsed', () => {
  const cfg = parseConfig(env());
  const { sent, res } = run(cfg, fakeReq({ headers: {} }));
  assert.strictEqual(res.statusCode, 401);
  assert.strictEqual(sent, null);
});

test('/health needs no token', () => {
  const cfg = parseConfig(env());
  const { res } = run(cfg, fakeReq({ method: 'GET', url: '/health', headers: {} }));
  assert.strictEqual(res.statusCode, 200);
});

test('a GET to anywhere but /tools is refused', () => {
  const cfg = parseConfig(env());
  const { sent, res } = run(cfg, fakeReq({ method: 'GET', url: '/mcp' }));
  assert.strictEqual(res.statusCode, 403);
  assert.strictEqual(sent, null);
});

test('a batch body never reaches the upstream', () => {
  const cfg = parseConfig(env());
  const { sent, res } = run(cfg, fakeReq(), JSON.stringify([{ jsonrpc: '2.0', id: 1, method: 'tools/list' }]));
  assert.strictEqual(res.statusCode, 403);
  assert.strictEqual(sent, null);
});

test('create_work_package never reaches the upstream', () => {
  const cfg = parseConfig(env());
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'create_work_package' } });
  const { sent, res } = run(cfg, fakeReq(), body);
  assert.strictEqual(res.statusCode, 403);
  assert.strictEqual(sent, null);
});

test('search_work_packages is forwarded to the pinned address with basic auth', () => {
  const cfg = parseConfig(env());
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'search_work_packages' } });
  const { sent, res } = run(cfg, fakeReq(), body, { address: '104.18.0.7' });
  assert.strictEqual(sent.host, '104.18.0.7');
  assert.strictEqual(sent.servername, 'qa.openproject-edge.com');
  assert.strictEqual(sent.path, '/mcp');
  assert.strictEqual(sent.headers.authorization, cfg.authValue);
  assert.strictEqual(sent.headers['accept-encoding'], 'identity');
  assert.strictEqual(res.statusCode, 200);
});

test('a tools/list request comes back trimmed to the read-only set', () => {
  const cfg = parseConfig(env());
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
  const upstreamBody = JSON.stringify({
    jsonrpc: '2.0', id: 1,
    result: { tools: [{ name: 'search_work_packages' }, { name: 'create_work_package' }] },
  });
  const { res } = run(cfg, fakeReq(), body, { upstreamBody });
  const out = JSON.parse(res.body);
  assert.deepStrictEqual(out.result.tools.map(t => t.name), ['search_work_packages']);
});

test('GET /tools returns the UNFILTERED list', () => {
  const cfg = parseConfig(env());
  const upstreamBody = JSON.stringify({
    jsonrpc: '2.0', id: 1,
    result: { tools: [{ name: 'search_work_packages' }, { name: 'create_work_package' }] },
  });
  const { sent, res } = run(cfg, fakeReq({ method: 'GET', url: '/tools' }), undefined, { upstreamBody });
  assert.strictEqual(sent.path, '/mcp');
  const out = JSON.parse(res.body);
  assert.deepStrictEqual(out.result.tools.map(t => t.name), ['search_work_packages', 'create_work_package']);
});

test('a 404 (no MCP server on this instance) passes through untouched, not JSON-parsed', () => {
  const cfg = parseConfig(env());
  const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
  const { res } = run(cfg, fakeReq(), body, { upstreamStatus: 404, upstreamBody: 'MCP server is not available.' });
  assert.strictEqual(res.statusCode, 404);
  assert.strictEqual(res.body, 'MCP server is not available.');
});

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
