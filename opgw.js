// OpenProject MCP gateway — the harness's only route to the OpenProject MCP
// server (`POST <OPENPROJECT_URL>/mcp`). Same containment shape as authgw.js
// (fixed upstream, pinned address, allowlisted reach, key swap), but the
// allowlist here is on the REQUEST BODY, not the path: every call is the same
// `POST /mcp`, so the gateway must parse the JSON-RPC envelope to decide.
//
// See MCP.md for the full design. Two things this file does that authgw.js
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
// sub-path still works, the same reasoning as authgw's CLIENT_PREFIX.
const MCP_PATH = '/mcp';

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
const READ_ONLY_OPS = new Set([
  'search_work_packages', 'list_work_package_comments', 'list_work_package_relations',
  'search_projects', 'search_versions', 'list_types', 'list_statuses', 'search_custom_fields',
]);

const ALLOWED_METHODS = new Set(['initialize', 'tools/list', 'tools/call']);

// A call this large has no legitimate read-only shape; refuse before it's
// even parsed.
const MAX_BODY_BYTES = 64 * 1024;

// Parses the environment into the frozen upstream description every request
// is served from. Mirrors authgw's parseConfig: throws on anything
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

  // Trailing slash normalised away for the same reason as authgw: the
  // re-applied prefix must never double a separator.
  const pathPrefix = url.pathname.replace(/\/+$/, '');

  const token = env.OPENPROJECT_TOKEN;
  if (!token) throw new Error('OPENPROJECT_TOKEN is not set');

  const gwToken = env.OPILOT_GW_TOKEN;
  if (!gwToken) throw new Error('OPILOT_GW_TOKEN is not set');

  return Object.freeze({
    https: url.protocol === 'https:',
    host: url.hostname,
    port: url.port ? Number(url.port) : (url.protocol === 'https:' ? 443 : 80),
    pathPrefix,
    // user_basic_auth, the same `apikey:<token>` form Clients::HTTP already
    // sends — verified live against the probed instance (MCP.md, Part 1).
    authValue: `Basic ${Buffer.from(`apikey:${token}`).toString('base64')}`,
    gwToken,
  });
}

// Maps an inbound client path onto the upstream, or reports why not. Only one
// client path exists (MCP_PATH), so this is simpler than authgw's mapPath,
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
  return { path: `${cfg.pathPrefix}${clientPath}` };
}

// Decides whether a parsed JSON-RPC request body may be forwarded. Returns
// `{ refuse: <reason> }` or `{}`.
function checkMcpCall(body) {
  if (Array.isArray(body) || typeof body !== 'object' || body === null) {
    return { refuse: 'body must be a single JSON-RPC object, not a batch/array' };
  }
  if (!ALLOWED_METHODS.has(body.method)) {
    return { refuse: `method not allowed: ${body.method}` };
  }
  if (body.method === 'tools/call') {
    const name = body.params && body.params.name;
    if (!READ_ONLY_OPS.has(name)) return { refuse: `tool not allowed: ${name}` };
  }
  return {};
}

// Reduces a `tools/list` JSON-RPC answer to READ_ONLY_OPS. Returns the
// original buffer unchanged when it isn't the shape expected (a non-200, an
// error page, a protocol version this gateway hasn't seen) — filtering must
// never turn an already-abnormal answer into a worse one.
function filterToolsList(raw) {
  let parsed;
  try {
    parsed = JSON.parse(raw.toString());
  } catch {
    return raw;
  }
  if (!parsed || !parsed.result || !Array.isArray(parsed.result.tools)) return raw;
  parsed.result.tools = parsed.result.tools.filter(t => READ_ONLY_OPS.has(t.name));
  return Buffer.from(JSON.stringify(parsed));
}

// The request handler, separated from createServer so tests can drive it
// directly. `deps.request` is the outbound call and `deps.address` yields the
// pinned address — same shape as authgw's createHandler.
function createHandler(cfg, deps) {
  const agent = new (cfg.https ? https : http).Agent({ keepAlive: true });

  // Sends one already-built JSON-RPC body upstream and answers `res`.
  // `filter` is applied to a 200 response body before it is sent back; every
  // other status pipes through unfiltered. The response is always buffered
  // here (never piped) because a filtered body needs its own content-length —
  // piping first and rewriting later isn't possible once headers are sent.
  function forwardUpstream(upstreamPath, body, res, filter) {
    const headers = {
      authorization: cfg.authValue,
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
      // Never ask the upstream to compress: a filtered answer needs to parse
      // the bytes it gets, and decompression is one more thing to get wrong.
      'accept-encoding': 'identity',
      host: cfg.host, // the NAME, not the pinned address
    };

    const upstream = deps.request({
      host: deps.address(),          // pinned address, not the name
      servername: cfg.https ? cfg.host : undefined,
      port: cfg.port,
      method: 'POST',
      path: upstreamPath,
      headers,
      agent,
    }, up => {
      const chunks = [];
      up.on('data', c => chunks.push(c));
      up.on('end', () => {
        const raw = Buffer.concat(chunks);
        const outBody = up.statusCode === 200 ? filter(raw) : raw;
        const outHeaders = { ...up.headers };
        delete outHeaders['content-length'];
        delete outHeaders['content-encoding'];
        delete outHeaders['transfer-encoding'];
        outHeaders['content-length'] = Buffer.byteLength(outBody);
        res.writeHead(up.statusCode, outHeaders);
        res.end(outBody);
      });
    });

    upstream.on('error', err => {
      // Same reasoning as authgw: a stale pinned address surfaces as a
      // connection error, so re-resolve for the NEXT request.
      deps.invalidate();
      process.stderr.write(`opgw: upstream error: ${err.message}\n`);
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
      const mapped = mapPath(cfg, MCP_PATH, MCP_PATH);
      const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
      forwardUpstream(mapped.path, body, res, identity);
      return;
    }

    if (req.method !== 'POST' || req.url !== MCP_PATH) {
      process.stderr.write(`opgw: refused ${req.method} ${req.url} — path not allowed\n`);
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('path not allowed\n');
      req.resume();
      return;
    }

    const mapped = mapPath(cfg, req.url, MCP_PATH);
    if (mapped.refuse) {
      process.stderr.write(`opgw: refused ${req.method} ${req.url} — ${mapped.refuse}\n`);
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
        process.stderr.write('opgw: refused — malformed JSON-RPC body\n');
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('malformed JSON-RPC body\n');
        return;
      }

      const check = checkMcpCall(parsed);
      if (check.refuse) {
        process.stderr.write(`opgw: refused — ${check.refuse}\n`);
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('call not allowed\n');
        return;
      }

      // The only record an MCP call leaves anywhere (see MCP.md, "The mirrors
      // stay independent") — log every allowed call.
      const label = parsed.params && parsed.params.name ? `${parsed.method} ${parsed.params.name}` : parsed.method;
      process.stderr.write(`opgw: allowed ${label}\n`);

      const filter = parsed.method === 'tools/list' ? filterToolsList : identity;
      forwardUpstream(mapped.path, raw, res, filter);
    });
  };
}

// Resolves the upstream host to an address once, re-resolving only when a
// connection actually fails. Identical shape to authgw's createResolver.
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
  const cfg = parseConfig();
  const resolver = createResolver(cfg);
  await resolver.refresh();

  const handler = createHandler(cfg, {
    request: (options, cb) => (cfg.https ? https : http).request(options, cb),
    address: () => resolver.address(),
    invalidate: () => resolver.invalidate(),
  });

  const server = http.createServer((req, res) => {
    resolver.ensure().then(() => handler(req, res)).catch(err => {
      process.stderr.write(`opgw: could not resolve ${cfg.host}: ${err.message}\n`);
      if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
      res.end('upstream unresolvable\n');
    });
  });

  server.listen(PORT, '0.0.0.0', () => {
    const scheme = cfg.https ? 'https' : 'http';
    process.stderr.write(
      `opgw listening on ${PORT} → ${scheme}://${cfg.host}:${cfg.port}${cfg.pathPrefix}/mcp ` +
      `(pinned ${resolver.address()}, ${READ_ONLY_OPS.size} read-only ops allowed)\n`
    );
  });
  return server;
}

if (require.main === module) {
  startServer().catch(err => {
    process.stderr.write(`opgw: ${err.message}\n`);
    process.exit(1);
  });
}

module.exports = {
  parseConfig, mapPath, checkMcpCall, filterToolsList, READ_ONLY_OPS,
  createHandler, createResolver, startServer,
};
