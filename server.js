// HTTP wrapper around `claude -p` — runs inside the chomper-claude container.
const http = require('http');
const { spawn } = require('child_process');

const PORT = 47291;
const PROC_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes

// Server-side allowlist of tool grants. The header is client-controlled, so
// only the exact grants the runner uses are accepted — anything else (e.g. an
// unexpected Bash(*)) is refused rather than passed to --allowedTools.
// Must stay in sync with TOOLS_READ / TOOLS_IMPL in lib/chomper/claude.rb.
const ALLOWED_TOOL_GRANTS = new Set([
  'Read,Grep,Glob',
  'Read,Grep,Glob,Write,Edit',
]);

const SESSION_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
// Model is validated by shape, not against an allowlist: it grants no
// privilege (unlike the tool grants above), so the only risk is a malformed
// value reaching --model. The pattern forbids spaces and a leading dash, so it
// can't smuggle extra CLI args; it stays permissive on the ID itself so model
// strings don't need syncing here on every release. The runner picks the model
// (claude.rb MODEL_WORK / MODEL_FAST).
const MODEL_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

// Serialise requests so sessions are never interleaved.
const queue = [];
let busy = false;

function drain() {
  if (queue.length === 0) { busy = false; return; }
  busy = true;
  const { body, tools, model, sessionId, res } = queue.shift();
  runClaude(body, tools, model, sessionId, res, drain);
}

function enqueue(body, tools, model, sessionId, res) {
  queue.push({ body, tools, model, sessionId, res });
  if (!busy) drain();
}

function runClaude(body, tools, model, sessionId, res, done) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose',
                '--settings', '/app/claude-settings.json'];
  if (tools) args.push('--allowedTools', tools);
  if (model) args.push('--model', model);
  if (sessionId) {
    args.push('--resume', sessionId);
  }

  const proc = spawn('claude', args, { env: process.env });

  const timer = setTimeout(() => {
    process.stderr.write('claude process timed out — killing\n');
    proc.kill('SIGTERM');
  }, PROC_TIMEOUT_MS);

  proc.stdin.end(body);

  res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });

  // Stream stdout to client while scanning for the session ID.
  let capturedSessionId = null;
  let lineBuffer = '';
  proc.stdout.on('data', chunk => {
    res.write(chunk);
    lineBuffer += chunk.toString();
    const lines = lineBuffer.split('\n');
    lineBuffer = lines.pop();
    for (const line of lines) {
      if (capturedSessionId) continue;
      try {
        const parsed = JSON.parse(line);
        if (parsed.session_id) capturedSessionId = parsed.session_id;
      } catch (e) {}
    }
  });

  proc.stderr.on('data', chunk => process.stderr.write(chunk));

  proc.on('close', () => {
    clearTimeout(timer);
    if (!capturedSessionId && lineBuffer.trim()) {
      try {
        const parsed = JSON.parse(lineBuffer);
        if (parsed.session_id) capturedSessionId = parsed.session_id;
      } catch (e) {}
    }
    if (capturedSessionId) {
      res.write(JSON.stringify({ type: 'session_id', session_id: capturedSessionId }) + '\n');
    }
    res.end();
    done();
  });

  proc.on('error', err => {
    clearTimeout(timer);
    process.stderr.write(`spawn error: ${err.message}\n`);
    if (!res.headersSent) res.writeHead(500);
    res.end();
    done();
  });
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200);
    res.end('ok');
    return;
  }

  if (req.method !== 'POST') {
    res.writeHead(405);
    res.end();
    return;
  }

  const tools     = req.headers['x-claude-tools'];
  const model     = req.headers['x-claude-model'] || null;
  const sessionId = req.headers['x-claude-session'] || null;

  if (tools && !ALLOWED_TOOL_GRANTS.has(tools)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' });
    res.end('unknown tool grant\n');
    return;
  }
  if (model && !MODEL_RE.test(model)) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('malformed model\n');
    return;
  }
  if (sessionId && !SESSION_ID_RE.test(sessionId)) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('malformed session id\n');
    return;
  }

  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', () => enqueue(Buffer.concat(chunks), tools, model, sessionId, res));
});

server.listen(PORT, '0.0.0.0', () => {
  process.stderr.write(`Claude HTTP server listening on port ${PORT}\n`);
});
