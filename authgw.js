// Auth gateway — runs in its own container, holds the real ANTHROPIC_API_KEY.
//
// The claude container points ANTHROPIC_BASE_URL here and authenticates with a
// fixed handshake token (ANTHROPIC_AUTH_TOKEN == CHOMPER_GW_TOKEN — not a
// secret, just a sanity gate), so the real key never lives alongside the
// untrusted work-package content. This forwarder
// always targets a hardcoded api.anthropic.com regardless of the request, so it
// is not an open proxy: a prompt-injected claude can cause Anthropic API calls
// but can neither read the key nor reach any other host through it.
const http  = require('http');
const https = require('https');

const PORT     = 47292;
const UPSTREAM = 'api.anthropic.com';

const API_KEY   = process.env.ANTHROPIC_API_KEY;
const GW_TOKEN  = process.env.CHOMPER_GW_TOKEN;

if (!API_KEY)  { process.stderr.write('authgw: ANTHROPIC_API_KEY is not set\n'); process.exit(1); }
if (!GW_TOKEN) { process.stderr.write('authgw: CHOMPER_GW_TOKEN is not set\n');  process.exit(1); }

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200); res.end('ok'); return;
  }

  // The client must present the gateway token; reject anything else before we
  // attach the real key. (Claude Code sends ANTHROPIC_AUTH_TOKEN as Bearer.)
  if (req.headers['authorization'] !== `Bearer ${GW_TOKEN}`) {
    res.writeHead(401, { 'Content-Type': 'text/plain' });
    res.end('unauthorized\n');
    req.resume(); // drain the body so the socket can close cleanly
    return;
  }

  // Forward unchanged except: swap the auth for the real x-api-key and retarget
  // the host. Everything else (anthropic-version/-beta, content-type, etc.) and
  // the request body stream straight through.
  const headers = { ...req.headers };
  delete headers['authorization'];
  delete headers['x-api-key'];
  delete headers['host'];
  headers['host']      = UPSTREAM;
  headers['x-api-key'] = API_KEY;

  const upstream = https.request(
    { hostname: UPSTREAM, port: 443, method: req.method, path: req.url, headers },
    up => {
      res.writeHead(up.statusCode, up.headers);
      up.pipe(res);
    }
  );

  upstream.on('error', err => {
    process.stderr.write(`authgw: upstream error: ${err.message}\n`);
    if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
    res.end('upstream error\n');
  });

  req.pipe(upstream);
});

server.listen(PORT, '0.0.0.0', () => {
  process.stderr.write(`authgw listening on port ${PORT} → https://${UPSTREAM}\n`);
});
