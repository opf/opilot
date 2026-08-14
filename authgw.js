// Auth gateway — runs in its own container, holds the real OPENROUTER_API_KEY.
//
// pi's models.json override (pi-models.json) points the openrouter provider's
// baseUrl here and resolves its apiKey to CHOMPER_GW_TOKEN (a fixed handshake
// value, not a secret — just a sanity gate), so the real key never lives
// alongside the untrusted work-package content the harness container reads.
// This forwarder always targets a hardcoded openrouter.ai regardless of the
// request, so it is not an open proxy: a prompt-injected pi can cause
// OpenRouter API calls but can neither read the key nor reach any other host
// through it.
const http  = require('http');
const https = require('https');

const PORT     = 47292;
const UPSTREAM = 'openrouter.ai';

const API_KEY   = process.env.OPENROUTER_API_KEY;
const GW_TOKEN  = process.env.CHOMPER_GW_TOKEN;

if (!API_KEY) { process.stderr.write('authgw: OPENROUTER_API_KEY is not set to a real key\n'); process.exit(1); }
if (!GW_TOKEN) { process.stderr.write('authgw: CHOMPER_GW_TOKEN is not set\n');  process.exit(1); }

// Reuse upstream TLS connections so inference calls don't pay a fresh handshake
// each time. Pinned explicitly rather than relying on the global agent default.
const upstreamAgent = new https.Agent({ keepAlive: true });

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200); res.end('ok'); return;
  }

  // The client must present the gateway token; reject anything else before we
  // attach the real key. (pi sends the resolved apiKey — CHOMPER_GW_TOKEN —
  // as a standard Bearer token, confirmed against pi 0.84.2.)
  if (req.headers['authorization'] !== `Bearer ${GW_TOKEN}`) {
    res.writeHead(401, { 'Content-Type': 'text/plain' });
    res.end('unauthorized\n');
    req.resume(); // drain the body so the socket can close cleanly
    return;
  }

  // Forward unchanged except: replace the gateway token with the real key in
  // the same Authorization header (OpenRouter, like OpenAI, takes a Bearer
  // token — not a separate x-api-key header) and retarget the host. Everything
  // else (content-type, etc.) and the request body stream straight through.
  const headers = { ...req.headers };
  headers['authorization'] = `Bearer ${API_KEY}`;
  headers['host']          = UPSTREAM; // assignment overwrites any incoming value

  const upstream = https.request(
    { hostname: UPSTREAM, port: 443, method: req.method, path: req.url, headers, agent: upstreamAgent },
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
