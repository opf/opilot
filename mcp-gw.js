// OpenProject MCP gateway — the harness's only route to the OpenProject MCP
// server (`POST <OPENPROJECT_URL>/mcp`). Same containment shape as inference-gw.js
// (fixed upstream, pinned address, allowlisted reach, key swap), but the
// allowlist here is on the REQUEST BODY, not the path: every call is the same
// `POST /mcp`, so the gateway must parse the JSON-RPC envelope to decide.
//
// See MCP.md for the full design. Two things this file does that inference-gw.js
// does not, both because a JSON-RPC body — not a URL — is what decides:
//
//   1. The request is buffered and parsed before it is forwarded, never
//      piped. `tools/call` is refused unless `params.name` is a read-only
//      operation; `create_work_package` and friends never reach the upstream.
//   2. A `tools/list` ANSWER is buffered and reduced to those same read-only
//      operations before it goes back — not a security control (the
//      tools/call check above is), but a tool that is listed and then always
//      403s wastes turns and invites retries.
//
// `GET /tools` is a second, DELIBERATELY UNFILTERED route for the runner: it
// runs its own tools/list upstream and returns the full answer, so a startup
// check can report which write tools the instance still exposes — the filter
// above would otherwise hide the very thing that check exists to surface.
// Same handshake token, same internal-only network. Keep the two plainly
// separate: /mcp is the model's door and is filtered, /tools is the
// operator's and is not.
const http  = require('http');
const https = require('https');
const dns   = require('dns');

const PORT = 47293;

// The only path the model may reach. The upstream path is the instance's own
// prefix (from OPENPROJECT_URL) plus this — so an instance served under a
// sub-path still works, the same reasoning as inference-gw's CLIENT_PREFIX.
const MCP_PATH = '/mcp';

// The GitHub route. A SECOND upstream behind the same gateway, not a second
// gateway: everything this file already does — pin an address at boot, buffer
// and parse the JSON-RPC body, allowlist the call, trim the tools/list answer,
// swap a handshake token for a real credential — is upstream-agnostic. A twin
// container would have copied ~300 lines and then drifted from them.
const GH_PATH = '/gh/mcp';

// GitHub hosts the MCP server itself, so there is no sidecar to run. `readonly`
// is IN THE PINNED PATH on purpose, not a header: a probe against the live
// endpoint showed the path wins over a hostile `X-MCP-Readonly: false`, and the
// same call without `/readonly` exposes 38 tools of which 16 write (
// create_pull_request, create_or_update_file, delete_file). Overridable per
// deployment only so a locally run `github-mcp-server http` stays a config
// choice rather than a redesign.
const GH_DEFAULT_URL = 'https://api.githubcopilot.com/mcp/readonly';

// Narrows what the upstream offers at all, before the allowlist below narrows
// it again. Set by this gateway, after every inbound X-MCP-* header is deleted:
// a header opilot does not set is a header someone else can.
const GH_TOOLSETS = 'repos,pull_requests,issues';

// The eight read-only MCP tools this gateway will place a call to. Six other
// tools on the instance write to OpenProject (create_work_package,
// update_work_package, create_work_package_comment,
// create_work_package_relation, update_work_package_relation,
// delete_work_package_relation) and are never in this set — see MCP.md's
// "Risks" section for why they must not reach a model.
//
// The extension (pi-op-mcp.ts) carries its own copy for the tool schema it
// shows the model; the two run in different containers, so the duplication is
// unavoidable. This file is the authority — the extension's copy only shapes
// what the model sees, never what actually executes.
const OP_READ_ONLY_OPS = new Set([
  'search_work_packages', 'list_work_package_comments', 'list_work_package_relations',
  'search_projects', 'search_versions', 'list_types', 'list_statuses', 'search_custom_fields',
]);

// Kept as the old name because Clients::OpMcp mirrors it and the /tools route
// below is still OpenProject's alone.
const READ_ONLY_OPS = OP_READ_ONLY_OPS;

// The GitHub operations the model may call: every one the /readonly endpoint
// offers. The rule is deliberately "whatever GitHub serves read-only" rather
// than a hand-picked subset — a subset needs a judgement per operation and
// drifts, and the read-only guarantee is already carried by the pinned path
// (probed: 22 tools here, 0 write-capable; without /readonly it is 38 of which
// 16 write). This list only shapes what the model is offered.
//
// There is NO repository confinement. Questions about an external library are
// a normal use — you cannot grep a repository you have not cloned — and the
// runner already reads public GitHub without restriction through Octokit, so
// confining only the harness would not have been a coherent boundary.
const GH_READ_ONLY_OPS = new Set([
  'get_commit', 'get_file_contents', 'get_label', 'get_latest_release',
  'get_release_by_tag', 'get_tag', 'issue_read', 'list_branches',
  'list_commits', 'list_issue_fields', 'list_issue_types', 'list_issues',
  'list_pull_requests', 'list_releases', 'list_repository_collaborators',
  'list_tags', 'pull_request_read', 'search_code', 'search_commits',
  'search_issues', 'search_pull_requests', 'search_repositories',
]);

const ALLOWED_METHODS = new Set(['initialize', 'tools/list', 'tools/call']);

// A call this large has no legitimate read-only shape; refuse before it's
// even parsed.
const MAX_BODY_BYTES = 64 * 1024;

// Parses the environment into the frozen upstream description every request
// is served from. Mirrors inference-gw's parseConfig: throws on anything
// malformed, because a gateway that starts half-understood is worse than one
// that refuses to start.
function parseConfig(env = process.env) {
  const raw = env.OPENPROJECT_URL;
  if (!raw) throw new Error('OPENPROJECT_URL is not set');

  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`OPENPROJECT_URL is not a URL: ${raw}`);
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`OPENPROJECT_URL must be http or https (got ${url.protocol})`);
  }

  // Trailing slash normalised away for the same reason as inference-gw: the
  // re-applied prefix must never double a separator.
  const pathPrefix = url.pathname.replace(/\/+$/, '');

  const token = env.OPENPROJECT_TOKEN;
  if (!token) throw new Error('OPENPROJECT_TOKEN is not set');

  const gwToken = env.OPILOT_GW_TOKEN;
  if (!gwToken) throw new Error('OPILOT_GW_TOKEN is not set');

  return Object.freeze({
    name: 'openproject',
    https: url.protocol === 'https:',
    host: url.hostname,
    port: url.port ? Number(url.port) : (url.protocol === 'https:' ? 443 : 80),
    pathPrefix,
    upstreamPath: `${pathPrefix}${MCP_PATH}`,
    allowedOps: OP_READ_ONLY_OPS,
    extraHeaders: {},
    // OpenProject answers JSON; only GitHub's endpoint frames its answers as
    // text/event-stream.
    sse: false,
    // user_basic_auth, the same `apikey:<token>` form Clients::HTTP already
    // sends — verified live against the probed instance (MCP.md, Part 1).
    authValue: `Basic ${Buffer.from(`apikey:${token}`).toString('base64')}`,
    gwToken,
  });
}

// Reads a flag the way Context#gh_mcp? does: unset means OFF.
function flagOn(value) {
  return !!value && !['0', 'false', 'no', 'off'].includes(String(value).trim().toLowerCase());
}

// The GitHub route, or null when it is switched off. OPILOT_GH_MCP is the
// switch, and it is off by default — GitHub is a THIRD PARTY, so reaching it
// is an explicit opt-in, the same reasoning that keeps
// OPILOT_TRACK_UPSTREAM_PRS off while OPILOT_OP_MCP (the operator's own
// instance) is on.
//
// The credential is opilot's ONE GitHub identity, the contributor token. There
// is deliberately no second read-only token: that token can write —
// `public_repo` reaches issue and pull request comments on any public
// repository — but no write is REACHABLE here, because the upstream path is
// pinned to /readonly and the allowlist above holds six read operations. Those
// two controls are what prevent a write, not the token's scopes, and this
// container already holds a write-capable OPENPROJECT_TOKEN on the same
// footing. A second credential to create, document and rotate bought nothing.
//
// The flag with no token THROWS rather than degrading quietly: the operator
// asked for this route, so a missing credential is a configuration error they
// should see at boot, not a tool that 403s later.
function parseGhConfig(env = process.env) {
  if (!flagOn(env.OPILOT_GH_MCP)) return null;

  const token = env.GITHUB_CONTRIBUTOR_TOKEN;
  if (!token) throw new Error('OPILOT_GH_MCP is set but GITHUB_CONTRIBUTOR_TOKEN is not');

  const raw = env.OPILOT_GH_MCP_URL || GH_DEFAULT_URL;
  let url;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`OPILOT_GH_MCP_URL is not a URL: ${raw}`);
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error(`OPILOT_GH_MCP_URL must be http or https (got ${url.protocol})`);
  }

  const upstreamPath = url.pathname.replace(/\/+$/, '') || '/';

  return Object.freeze({
    name: 'github',
    https: url.protocol === 'https:',
    host: url.hostname,
    port: url.port ? Number(url.port) : (url.protocol === 'https:' ? 443 : 80),
    pathPrefix: upstreamPath,
    upstreamPath,
    // A personal access token, presented the way GitHub's own docs show. Held
    // here and nowhere else — never in the harness, never in the runner.
    authValue: `Bearer ${token}`,
    // Set AFTER every inbound x-mcp-* header is deleted. Defence in depth: the
    // pinned `/readonly` path already beats a hostile header, and this is the
    // same unconditional delete-then-set inference-gw applies to authorization.
    extraHeaders: { 'x-mcp-toolsets': GH_TOOLSETS, 'x-mcp-readonly': 'true' },
    allowedOps: GH_READ_ONLY_OPS,
    sse: true,
  });
}

// Every upstream this gateway serves, keyed by the client path that reaches it.
function parseRoutes(env = process.env) {
  const op = parseConfig(env);
  const routes = { [MCP_PATH]: op };
  const gh = parseGhConfig(env);
  if (gh) routes[GH_PATH] = gh;
  return Object.freeze({ gwToken: op.gwToken, routes: Object.freeze(routes) });
}

// Maps an inbound client path onto the upstream, or reports why not. Only one
// client path exists (MCP_PATH), so this is simpler than inference-gw's mapPath,
// but it keeps the same traversal check on the string actually used to build
// the upstream path — belt-and-braces even though an exact-match comparison
// already rules traversal out.
function mapPath(cfg, reqUrl, clientPath) {
  const q    = reqUrl.indexOf('?');
  const path = q === -1 ? reqUrl : reqUrl.slice(0, q);
  if (path !== clientPath) return { refuse: `path not allowed: ${path}` };
  if (/(^|\/)\.\.(\/|$)/.test(path) || /%2e/i.test(path)) {
    return { refuse: `path traversal is not allowed: ${path}` };
  }
  return { path: cfg.upstreamPath };
}

// Decides whether a parsed JSON-RPC request body may be forwarded. Returns
// `{ refuse: <reason> }` or `{}`.
function checkMcpCall(body, allowedOps = OP_READ_ONLY_OPS) {
  if (Array.isArray(body) || typeof body !== 'object' || body === null) {
    return { refuse: 'body must be a single JSON-RPC object, not a batch/array' };
  }
  if (!ALLOWED_METHODS.has(body.method)) {
    return { refuse: `method not allowed: ${body.method}` };
  }
  if (body.method === 'tools/call') {
    const name = body.params && body.params.name;
    if (!allowedOps.has(name)) return { refuse: `tool not allowed: ${name}` };
  }
  return {};
}

// Recovers the JSON-RPC object from a text/event-stream answer. GitHub's
// endpoint ALWAYS frames its answer this way — it rejects a bare
// `Accept: application/json` with a 400 — so this is required, not defensive.
//
// Returns null for anything it does not recognise (no data line, several of
// them, or one that is not JSON), and the caller then passes the bytes through
// untouched. Same rule as #filterToolsList: unwrapping must never turn an
// already-abnormal answer into a worse one.
function unwrapSse(raw) {
  const lines = raw.toString().split(/\r?\n/).filter(l => l.startsWith('data:'));
  if (lines.length !== 1) return null;
  const payload = lines[0].slice('data:'.length).trim();
  try {
    JSON.parse(payload);
  } catch {
    return null;
  }
  return Buffer.from(payload);
}

// Reduces a `tools/list` JSON-RPC answer to READ_ONLY_OPS. Returns the
// original buffer unchanged when it isn't the shape expected (a non-200, an
// error page, a protocol version this gateway hasn't seen) — filtering must
// never turn an already-abnormal answer into a worse one.
function filterToolsList(raw, allowedOps = OP_READ_ONLY_OPS) {
  let parsed;
  try {
    parsed = JSON.parse(raw.toString());
  } catch {
    return raw;
  }
  if (!parsed || !parsed.result || !Array.isArray(parsed.result.tools)) return raw;
  parsed.result.tools = parsed.result.tools.filter(t => allowedOps.has(t.name));
  return Buffer.from(JSON.stringify(parsed));
}

// The request handler, separated from createServer so tests can drive it
// directly. `deps.request` is the outbound call and `deps.address` yields the
// pinned address — same shape as inference-gw's createHandler.
function createHandler(cfg, deps) {
  const agents = { http: new http.Agent({ keepAlive: true }), https: new https.Agent({ keepAlive: true }) };

  // Sends one already-built JSON-RPC body upstream and answers `res`.
  // `filter` is applied to a 200 response body before it is sent back; every
  // other status pipes through unfiltered. The response is always buffered
  // here (never piped) because a filtered body needs its own content-length —
  // piping first and rewriting later isn't possible once headers are sent.
  function forwardUpstream(route, body, res, filter) {
    const headers = {
      authorization: route.authValue,
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
      // Both types, always: GitHub's endpoint refuses `application/json` on its
      // own with a 400, and an upstream that answers JSON just answers JSON.
      accept: 'application/json, text/event-stream',
      // Never ask the upstream to compress: a filtered answer needs to parse
      // the bytes it gets, and decompression is one more thing to get wrong.
      'accept-encoding': 'identity',
      host: route.host, // the NAME, not the pinned address
      // Last, so a route's own headers cannot be shadowed by the defaults —
      // and note nothing from the inbound request is copied here at all.
      ...route.extraHeaders,
    };

    const upstream = deps.request(route, {
      host: deps.address(route),     // pinned address, not the name
      servername: route.https ? route.host : undefined,
      port: route.port,
      method: 'POST',
      path: route.upstreamPath,
      headers,
      agent: agents[route.https ? 'https' : 'http'],
    }, up => {
      const chunks = [];
      up.on('data', c => chunks.push(c));
      up.on('end', () => {
        let raw = Buffer.concat(chunks);
        const outHeaders = { ...up.headers };
        if (route.sse && up.statusCode === 200) {
          const json = unwrapSse(raw);
          if (json) {
            raw = json;
            // The client is handed JSON, so it must not be told the answer is
            // still an event stream.
            outHeaders['content-type'] = 'application/json';
          }
        }
        const outBody = up.statusCode === 200 ? filter(raw) : raw;
        delete outHeaders['content-length'];
        delete outHeaders['content-encoding'];
        delete outHeaders['transfer-encoding'];
        outHeaders['content-length'] = Buffer.byteLength(outBody);
        res.writeHead(up.statusCode, outHeaders);
        res.end(outBody);
      });
    });

    upstream.on('error', err => {
      // Same reasoning as inference-gw: a stale pinned address surfaces as a
      // connection error, so re-resolve for the NEXT request.
      deps.invalidate();
      process.stderr.write(`mcp-gw: ${route.name} upstream error: ${err.message}\n`);
      if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end('upstream error\n');
    });

    upstream.end(body);
  }

  const identity = raw => raw;

  return function handle(req, res) {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200); res.end('ok'); return;
    }

    // Our own handshake token, checked before anything else — unrelated to
    // how the upstream wants its own credential.
    if (req.headers['authorization'] !== `Bearer ${cfg.gwToken}`) {
      res.writeHead(401, { 'Content-Type': 'text/plain' });
      res.end('unauthorized\n');
      req.resume();
      return;
    }

    // The runner's route: an unfiltered tools/list, so a startup check can
    // report which write tools the instance still has enabled. Deliberately
    // not reachable from the model — pi never sends a bare GET.
    if (req.method === 'GET' && req.url === '/tools') {
      const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
      forwardUpstream(cfg.routes[MCP_PATH], body, res, identity);
      return;
    }

    // Which upstream this call is for. An unknown path has no route and is
    // refused before anything else looks at it.
    const clientPath = (req.url || '').split('?')[0];
    const route = cfg.routes[clientPath];
    if (req.method !== 'POST' || !route) {
      process.stderr.write(`mcp-gw: refused ${req.method} ${req.url} — path not allowed\n`);
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('path not allowed\n');
      req.resume();
      return;
    }

    const mapped = mapPath(route, req.url, clientPath);
    if (mapped.refuse) {
      process.stderr.write(`mcp-gw: refused ${req.method} ${req.url} — ${mapped.refuse}\n`);
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('path not allowed\n');
      req.resume();
      return;
    }

    // Buffered, never piped: the allowlist decision needs the whole body.
    const chunks = [];
    let size = 0;
    let refused = false;
    req.on('data', chunk => {
      if (refused) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        refused = true;
        res.writeHead(413, { 'Content-Type': 'text/plain' });
        res.end('body too large\n');
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (refused) return;
      const raw = Buffer.concat(chunks);

      let parsed;
      try {
        parsed = JSON.parse(raw.toString());
      } catch {
        process.stderr.write('mcp-gw: refused — malformed JSON-RPC body\n');
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('malformed JSON-RPC body\n');
        return;
      }

      const check = checkMcpCall(parsed, route.allowedOps);
      if (check.refuse) {
        process.stderr.write(`mcp-gw: ${route.name} refused — ${check.refuse}\n`);
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('call not allowed\n');
        return;
      }

      // The only record an MCP call leaves anywhere (see MCP.md, "The mirrors
      // stay independent") — log every allowed call.
      const label = parsed.params && parsed.params.name ? `${parsed.method} ${parsed.params.name}` : parsed.method;
      process.stderr.write(`mcp-gw: ${route.name} allowed ${label}\n`);

      const filter = parsed.method === 'tools/list'
        ? buf => filterToolsList(buf, route.allowedOps)
        : identity;
      forwardUpstream(route, raw, res, filter);
    });
  };
}

// Resolves ONE route's upstream host to an address once, re-resolving only when
// a connection actually fails. Identical shape to inference-gw's createResolver;
// with two upstreams there is simply one of these per route.
function createResolver(cfg, lookup = dns.promises.lookup) {
  let current = null;
  const refresh = async () => {
    const { address } = await lookup(cfg.host);
    current = address;
    return address;
  };
  return {
    refresh,
    address: () => current,
    invalidate: () => { current = null; },
    ensure: async () => (current ? current : refresh()),
  };
}

async function startServer() {
  const cfg = parseRoutes();

  // One resolver per upstream, each pinned at boot exactly as before. A route
  // whose host will not resolve stops the gateway starting, which is the same
  // fail-closed rule parseConfig follows for a malformed upstream.
  const resolvers = {};
  for (const route of Object.values(cfg.routes)) {
    resolvers[route.name] = createResolver(route);
    await resolvers[route.name].refresh();
  }

  const handler = createHandler(cfg, {
    request: (route, options, cb) => (route.https ? https : http).request(options, cb),
    address: route => resolvers[route.name].address(),
    invalidate: route => resolvers[route.name].invalidate(),
  });

  const server = http.createServer((req, res) => {
    Promise.all(Object.values(resolvers).map(r => r.ensure()))
      .then(() => handler(req, res))
      .catch(err => {
        process.stderr.write(`mcp-gw: could not resolve an upstream: ${err.message}\n`);
        if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
        res.end('upstream unresolvable\n');
      });
  });

  server.listen(PORT, '0.0.0.0', () => {
    process.stderr.write(`mcp-gw listening on ${PORT}\n`);
    for (const [clientPath, route] of Object.entries(cfg.routes)) {
      const scheme = route.https ? 'https' : 'http';
      process.stderr.write(
        `  ${clientPath} → ${scheme}://${route.host}:${route.port}${route.upstreamPath} ` +
        `(pinned ${resolvers[route.name].address()}, ${route.allowedOps.size} read-only ops)\n`
      );
    }
  });
  return server;
}

if (require.main === module) {
  startServer().catch(err => {
    process.stderr.write(`mcp-gw: ${err.message}\n`);
    process.exit(1);
  });
}

module.exports = {
  parseConfig, parseGhConfig, parseRoutes,
  mapPath, checkMcpCall, filterToolsList, unwrapSse,
  READ_ONLY_OPS, OP_READ_ONLY_OPS, GH_READ_ONLY_OPS, MCP_PATH, GH_PATH,
  createHandler, createResolver, startServer,
};
