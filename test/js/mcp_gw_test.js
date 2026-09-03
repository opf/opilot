// Plain-Node test for mcp-gw.js — the harness's only route to the OpenProject
// MCP server. Run with `node test/js/mcp_gw_test.js`.
//
// Unlike inference-gw, the allowlist here is on the JSON-RPC BODY, not the path —
// every call is the same POST /mcp — so what matters most is: a write tool
// (create_work_package) is refused, a batch/array body is refused, and a
// `tools/list` answer is trimmed to the read-only set before it reaches pi.
const assert = require('assert');
const {
  parseConfig, parseGhConfig, parseRoutes, loadRepos, mapPath, checkMcpCall, checkRepoPin,
  filterToolsList, unwrapSse, READ_ONLY_OPS, GH_READ_ONLY_OPS, createHandler,
} = require('../../mcp-gw.js');

// The registry the GitHub route pins against, injected instead of read from a
// mounted repos.json.
const REPOS = () => new Set(['opf/openproject', 'opf/openproject-octicons']);
const ghEnv = (extra = {}) => env({ OPILOT_GITHUB_READ_TOKEN: 'ghp_readonly', ...extra });
const ghRoute = (extra = {}) => parseGhConfig(ghEnv(extra), REPOS);

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
  const table = cfg.routes ? cfg : { gwToken: GW, routes: { '/mcp': cfg } };
  const handler = createHandler(table, {
    request(_route, options, cb) {
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

// ── the GitHub route ────────────────────────────────────────────────────

test('with no read token there is no GitHub route at all', () => {
  assert.strictEqual(parseGhConfig(env(), REPOS), null);
  assert.deepStrictEqual(Object.keys(parseRoutes(env(), REPOS).routes), ['/mcp']);
});

test('the GitHub route pins readonly IN THE PATH, not in a header', () => {
  const gh = ghRoute();
  assert.strictEqual(gh.host, 'api.githubcopilot.com');
  assert.strictEqual(gh.upstreamPath, '/mcp/readonly');
  assert.strictEqual(gh.authValue, 'Bearer ghp_readonly');
  assert.strictEqual(gh.sse, true, 'GitHub always answers text/event-stream');
  assert.strictEqual(gh.extraHeaders['x-mcp-toolsets'], 'repos,pull_requests,issues');
});

test('a local github-mcp-server is a config choice, not a redesign', () => {
  const gh = ghRoute({ OPILOT_GH_MCP_URL: 'http://ghmcp:8082/' });
  assert.strictEqual(gh.https, false);
  assert.strictEqual(gh.port, 8082);
  assert.strictEqual(gh.upstreamPath, '/');
});

test('a broken GitHub config refuses that route, and never OpenProject', () => {
  assert.throws(() => parseGhConfig(ghEnv({ OPILOT_GH_MCP_URL: 'not a url' }), REPOS), /not a URL/);
  assert.throws(() => parseGhConfig(ghEnv(), () => new Set()), /no upstreams/);
  // OpenProject still parses on its own, whatever GitHub does.
  assert.strictEqual(parseConfig(ghEnv()).name, 'openproject');
});

test('loadRepos lowercases, because GitHub owner/repo are case-insensitive', () => {
  const repos = loadRepos('x', () => JSON.stringify({ repos: [{ upstream: 'OPF/OpenProject' }] }));
  assert.ok(repos.has('opf/openproject'));
});

test('an unreadable registry refuses the route rather than pinning nothing', () => {
  assert.throws(() => loadRepos('/nope', () => { throw new Error('ENOENT'); }), /repository pin/);
});

// ── the repository pin ──────────────────────────────────────────────────

const ghCall = (name, args) => ({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name, arguments: args } });

test('the pin allows a registry repo and refuses everything else', () => {
  const gh = ghRoute();
  assert.deepStrictEqual(checkRepoPin(gh, ghCall('list_commits', { owner: 'opf', repo: 'openproject' })), {});
  assert.ok(checkRepoPin(gh, ghCall('list_commits', { owner: 'evil', repo: 'exfil' })).refuse);
});

test('the pin cannot be walked past with capitalisation', () => {
  // GitHub resolves OPF/OpenProject to the same repository, so a
  // case-sensitive comparison would be a bypass, not a nicety.
  assert.deepStrictEqual(checkRepoPin(ghRoute(), ghCall('list_commits', { owner: 'OPF', repo: 'OpenProject' })), {});
});

test('the pin refuses a call that names no repository', () => {
  assert.ok(checkRepoPin(ghRoute(), ghCall('list_commits', {})).refuse);
  assert.ok(checkRepoPin(ghRoute(), ghCall('list_commits', { owner: 'opf' })).refuse);
});

test('the OpenProject route is not pinned — its token scope is the boundary', () => {
  assert.deepStrictEqual(checkRepoPin(parseConfig(env()), ghCall('search_work_packages', {})), {});
});

// ── per-route allowlists ────────────────────────────────────────────────

test('each route allows only its own operations', () => {
  for (const name of GH_READ_ONLY_OPS) {
    assert.deepStrictEqual(checkMcpCall(ghCall(name, {}), GH_READ_ONLY_OPS), {});
    assert.ok(checkMcpCall(ghCall(name, {})).refuse, `${name} is not an OpenProject tool`);
  }
  assert.ok(checkMcpCall(ghCall('search_work_packages', {}), GH_READ_ONLY_OPS).refuse);
});

test('a GitHub write tool is refused even though the path already says readonly', () => {
  for (const name of ['create_pull_request', 'create_or_update_file', 'delete_file', 'add_issue_comment']) {
    assert.ok(checkMcpCall(ghCall(name, {}), GH_READ_ONLY_OPS).refuse, `${name} should be refused`);
  }
});

test('the free-text search operations are deliberately not allowed yet', () => {
  // They cannot be repo-pinned by an exact check: a substring test for
  // `repo:opf/openproject` passes on `NOT repo:opf/openproject`.
  for (const name of ['search_commits', 'search_pull_requests', 'search_issues', 'search_code']) {
    assert.ok(checkMcpCall(ghCall(name, {}), GH_READ_ONLY_OPS).refuse, `${name} should be refused`);
  }
});

// ── SSE unwrapping ──────────────────────────────────────────────────────

test('a single SSE frame is unwrapped to its JSON-RPC object', () => {
  const raw = Buffer.from('event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{}}\n\n');
  assert.deepStrictEqual(JSON.parse(unwrapSse(raw).toString()).id, 1);
});

test('anything else passes through untouched rather than being guessed at', () => {
  assert.strictEqual(unwrapSse(Buffer.from('{"jsonrpc":"2.0"}')), null, 'no data: line');
  assert.strictEqual(unwrapSse(Buffer.from('data: {"a":1}\n\ndata: {"b":2}\n')), null, 'several frames');
  assert.strictEqual(unwrapSse(Buffer.from('data: not json\n')), null);
});

// ── the GitHub route end to end ─────────────────────────────────────────

test('a GitHub call is forwarded with its own credential, headers and path', () => {
  const cfg = parseRoutes(ghEnv(), REPOS);
  const body = JSON.stringify(ghCall('list_commits', { owner: 'opf', repo: 'openproject' }));
  const upstreamBody = 'event: message\ndata: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}\n\n';
  const { sent, res } = run(cfg, fakeReq({ url: '/gh/mcp' }), body, { upstreamBody });

  assert.strictEqual(sent.path, '/mcp/readonly');
  assert.strictEqual(sent.headers.authorization, 'Bearer ghp_readonly');
  assert.strictEqual(sent.headers['x-mcp-toolsets'], 'repos,pull_requests,issues');
  assert.strictEqual(sent.headers.accept, 'application/json, text/event-stream');
  // Unwrapped, and told the truth about what it now is.
  assert.deepStrictEqual(JSON.parse(res.body).result, { ok: true });
  assert.strictEqual(res.headers['content-type'], 'application/json');
});

test('a repo outside the registry never reaches GitHub', () => {
  const cfg = parseRoutes(ghEnv(), REPOS);
  const body = JSON.stringify(ghCall('list_commits', { owner: 'evil', repo: 'exfil' }));
  const { sent, res } = run(cfg, fakeReq({ url: '/gh/mcp' }), body);
  assert.strictEqual(res.statusCode, 403);
  assert.strictEqual(sent, null);
});

test('the GitHub path 403s when the route is not configured', () => {
  const { sent, res } = run(parseRoutes(env(), REPOS), fakeReq({ url: '/gh/mcp' }), '{}');
  assert.strictEqual(res.statusCode, 403);
  assert.strictEqual(sent, null);
});

test('an OpenProject call still goes to OpenProject with both routes live', () => {
  const cfg = parseRoutes(ghEnv(), REPOS);
  const body = JSON.stringify(ghCall('search_work_packages', {}));
  const { sent } = run(cfg, fakeReq(), body);
  assert.strictEqual(sent.path, '/mcp');
  assert.strictEqual(sent.headers.authorization, parseConfig(env()).authValue);
});

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
