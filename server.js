// HTTP wrapper around `claude -p` — runs inside the chomper-claude container.
const http = require('http');
const { spawn } = require('child_process');

const PORT = 47291;
const PROC_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes

// Serialise requests so sessions are never interleaved.
const queue = [];
let busy = false;

function drain() {
  if (queue.length === 0) { busy = false; return; }
  busy = true;
  const { body, tools, sessionId, res } = queue.shift();
  runClaude(body, tools, sessionId, res, drain);
}

function enqueue(body, tools, sessionId, res) {
  queue.push({ body, tools, sessionId, res });
  if (!busy) drain();
}

function runClaude(body, tools, sessionId, res, done) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose'];
  if (tools) args.push('--allowedTools', tools);
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
  const sessionId = req.headers['x-claude-session'] || null;

  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', () => enqueue(Buffer.concat(chunks), tools, sessionId, res));
});

server.listen(PORT, '0.0.0.0', () => {
  process.stderr.write(`Claude HTTP server listening on port ${PORT}\n`);
});
