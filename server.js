// HTTP wrapper around `claude -p` — runs inside the chomper-claude container.
const http = require('http');
const { spawn } = require('child_process');

const PORT = 3000;
const PROC_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes

// Serialise requests so --continue sessions are never interleaved.
const queue = [];
let busy = false;

function drain() {
  if (queue.length === 0) { busy = false; return; }
  busy = true;
  const { body, tools, fresh, res } = queue.shift();
  runClaude(body, tools, fresh, res, drain);
}

function enqueue(body, tools, fresh, res) {
  queue.push({ body, tools, fresh, res });
  if (!busy) drain();
}

function runClaude(body, tools, fresh, res, done) {
  const args = ['-p', '--output-format', 'stream-json', '--verbose'];
  if (tools) args.push('--allowedTools', tools);
  if (!fresh) args.push('--continue');

  const proc = spawn('claude', args, { env: process.env });

  const timer = setTimeout(() => {
    process.stderr.write('claude process timed out — killing\n');
    proc.kill('SIGTERM');
  }, PROC_TIMEOUT_MS);

  proc.stdin.end(body);

  res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });
  proc.stdout.on('data', chunk => res.write(chunk));
  proc.stderr.on('data', chunk => process.stderr.write(chunk));

  proc.on('close', () => {
    clearTimeout(timer);
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

  const tools = req.headers['x-claude-tools'];
  const fresh = req.headers['x-claude-fresh'] === 'true';

  const chunks = [];
  req.on('data', chunk => chunks.push(chunk));
  req.on('end', () => enqueue(Buffer.concat(chunks), tools, fresh, res));
});

server.listen(PORT, '0.0.0.0', () => {
  process.stderr.write(`Claude HTTP server listening on port ${PORT}\n`);
});
