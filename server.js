// HTTP wrapper around `pi --mode json` — runs inside the harness container.
// Translates pi's JSON event stream into the NDJSON frame shapes harness.rb
// already parses (assistant/result/session_id/exit). `server.js` holds the
// controls the container needs regardless of which CLI/SDK runs underneath —
// the server-side tool-grant allowlist, model-string validation, and the
// one-request-at-a-time queue — so the shim stays even though pi itself has
// no HTTP interface; see translate()'s comment below for the event-shape
// ground truth.
const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const PORT = 47291;
const PROC_TIMEOUT_MS = 10 * 60 * 1000; // 10 minutes

// Server-side allowlist of tool grants. The header is client-controlled, so
// only the exact grants the runner uses are accepted. pi's tool names are
// lowercase and there's no glob tool — `find` covers that job.
// Must stay in sync with TOOLS_READ / TOOLS_IMPL in lib/opilot/harness.rb.
const ALLOWED_TOOL_GRANTS = new Set([
  'read,grep,find,ls,bash',
  'read,grep,find,ls,bash,write,edit',
]);

const SESSION_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
// A model id now carries an OpenRouter vendor slug behind a provider prefix,
// e.g. "openrouter/anthropic/claude-opus-4.8" (harness.rb supplies the full
// string; server.js does no prefixing of its own). Validated by shape, not an
// allowlist: it grants no privilege (unlike the tool grants above), so the
// only risk is a malformed value reaching --model. Forbids spaces and a
// leading dash so it can't smuggle extra CLI args.
const MODEL_RE = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$/;

const PI_AGENT_DIR   = process.env.PI_CODING_AGENT_DIR || '/pi-agent';
const PI_SESSION_DIR = process.env.PI_CODING_AGENT_SESSION_DIR || '/sessions';

// Copies the image's baked-in config into the writable agent dir on every
// boot, so pi-settings.json/pi-models.json stay in version control and the
// first-run wizard needs no change. Unconditional, not "if missing": these two
// files are meant to be exactly what's in git — an edit to pi-models.json (e.g.
// adding a compat flag) must take effect on the next container start, not be
// masked forever by a copy seeded before the edit existed. Neither file is
// meant to be hand-edited in the running container (unlike pi's own
// auth.json, untouched here), so this can't discard anything meant to persist.
function seedAgentDir() {
  fs.mkdirSync(PI_AGENT_DIR, { recursive: true });
  const seeds = [['pi-settings.json', 'settings.json'], ['pi-models.json', 'models.json']];
  for (const [src, destName] of seeds) {
    fs.copyFileSync(path.join('/app', src), path.join(PI_AGENT_DIR, destName));
  }
}

// Serialise requests so sessions are never interleaved.
const queue = [];
let busy = false;

function drain() {
  if (queue.length === 0) { busy = false; return; }
  busy = true;
  const { body, tools, model, sessionId, res } = queue.shift();
  runPi(body, tools, model, sessionId, res, drain);
}

function enqueue(body, tools, model, sessionId, res) {
  queue.push({ body, tools, model, sessionId, res });
  if (!busy) drain();
}

function extractText(message) {
  if (!message || !Array.isArray(message.content)) return '';
  return message.content.filter(p => p.type === 'text').map(p => p.text).join('');
}

function lastAssistantOf(messages) {
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === 'assistant') return messages[i];
  }
  return null;
}

// The final assistant message's stopReason decides the outcome. "stop" is a
// clean finish; everything else (error, aborted, deferred, length, a
// leftover toolUse) is surfaced as an error rather than passed off as a
// finished answer — a run that died mid-way must not be mistaken for one that
// finished (see the matching rule in harness.rb).
function settleResult(msg) {
  if (!msg) {
    return { type: 'result', subtype: 'error_no_response', is_error: true,
              result: 'pi produced no assistant response' };
  }
  if (msg.stopReason === 'stop') {
    return { type: 'result', subtype: 'success', is_error: false, result: extractText(msg) };
  }
  const subtype = msg.stopReason === 'error' ? 'error_during_execution' : `error_${msg.stopReason}`;
  const result = msg.errorMessage || extractText(msg) || subtype;
  return { type: 'result', subtype, is_error: true, result };
}

// Translates one parsed pi `--mode json` event into zero or more opilot
// NDJSON frames. Ground truth for the event shapes below is pi 0.84.2 itself
// (its shipped docs/json.md plus packages/ai/src/types.ts), not guesswork:
//
//   {"type":"session","id":...}                                    — first line
//   {"type":"tool_execution_start","toolName":...,"args":{...}}
//   {"type":"message_update","assistantMessageEvent":{"type":"text_end","content":...}}
//   {"type":"agent_end","messages":[...],"willRetry":bool}
//   {"type":"agent_settled"}
//
// Flushed on text_end (the FULL text for one content block, per pi's
// AssistantMessageEvent union — packages/ai/src/types.ts), not on every
// text_delta: harness.rb passes each forwarded "text" part through a full
// Markdown parser (TTY::Markdown, in render_markdown). pi's deltas are raw
// token/word fragments — parsing each one alone as its own tiny markdown
// document reflows it into its own paragraph (stray blank lines) and can
// split an inline code span whose backticks land in different deltas. A
// complete block per text_end parses correctly; only the mid-paragraph
// "live typing" look is traded away, not correctness.
//
// pi can run several internal agent_start/agent_end cycles for ONE prompt —
// auto-retry on a transient provider error, or overflow compaction — each
// with its own agent_end (willRetry: true on all but the last). Only
// agent_settled means "no automatic retry, compaction retry, or queued
// continuation remains" (pi's docs/extensions.md), so `state.lastAssistantMessage`
// is only updated (not acted on) at agent_end, and the result frame is
// synthesized once, at agent_settled — acting on the first agent_end would
// report a transient retry as the final outcome.
//
// `mutable state` carries {sessionId, lastAssistantMessage} across calls for
// one process's stream.
function translate(parsed, state) {
  const frames = [];
  switch (parsed.type) {
    case 'session':
      state.sessionId = parsed.id;
      break;
    case 'tool_execution_start':
      frames.push({
        type: 'assistant',
        message: { content: [{ type: 'tool_use', name: parsed.toolName, input: parsed.args }] },
      });
      break;
    case 'message_update': {
      const evt = parsed.assistantMessageEvent;
      if (evt && evt.type === 'text_end' && evt.content) {
        frames.push({ type: 'assistant', message: { content: [{ type: 'text', text: evt.content }] } });
      }
      break;
    }
    case 'agent_end': {
      // Only overwrite when this cycle actually has an assistant message — an
      // aborted/compaction cycle's agent_end can carry messages with none, and
      // clobbering a good prior result with null would report a run that
      // succeeded as "no assistant response" once agent_settled fires.
      const msg = lastAssistantOf(parsed.messages || []);
      if (msg) state.lastAssistantMessage = msg;
      break;
    }
    case 'agent_settled':
      frames.push(settleResult(state.lastAssistantMessage));
      break;
    default:
      break;
  }
  return frames;
}

function runPi(body, tools, model, sessionId, res, done) {
  const args = [
    '--mode', 'json',
    '--no-extensions', '-e', '/app/pi-guards.ts',
    '--no-skills', '--no-prompt-templates',
    // pi loads a project's CLAUDE.md/AGENTS.md at startup even when it does
    // not trust the project (untrusted, prompt-injectable work-package text
    // is exactly the case here) — --no-context-files stops that. The plan
    // and implement prompts instead tell it to read each target repo's
    // CLAUDE.md/AGENTS.md directly, so there's still one path for this data
    // and the runner controls it.
    '--no-context-files',
    '--no-approve',
    '--offline',
    '--session-dir', PI_SESSION_DIR,
  ];
  if (tools) args.push('--tools', tools);
  if (model) args.push('--model', model);
  if (sessionId) args.push('--session', sessionId);

  const proc = spawn('pi', args, { env: process.env });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    process.stderr.write('pi process timed out — killing\n');
    proc.kill('SIGTERM');
  }, PROC_TIMEOUT_MS);

  proc.stdin.end(body);

  res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });

  const state = {};
  let lineBuffer = '';
  proc.stdout.on('data', chunk => {
    lineBuffer += chunk.toString();
    const lines = lineBuffer.split('\n');
    lineBuffer = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      let parsed;
      try { parsed = JSON.parse(line); } catch (e) { continue; }
      for (const frame of translate(parsed, state)) {
        res.write(JSON.stringify(frame) + '\n');
      }
    }
  });

  // Mirror stderr to the container log AND keep a bounded tail to forward to
  // the runner. A pre-flight CLI failure (e.g. --session pointing at a
  // session pi can't find) prints a plain-text line to stderr, exits 1, and
  // emits NO JSON at all — the stderr tail is the only place that reason
  // exists, forwarded via the exit event below.
  const STDERR_TAIL_MAX = 8000;
  let stderrTail = '';
  proc.stderr.on('data', chunk => {
    process.stderr.write(chunk);
    stderrTail = (stderrTail + chunk.toString()).slice(-STDERR_TAIL_MAX);
  });

  proc.on('close', (code, signal) => {
    clearTimeout(timer);
    if (lineBuffer.trim()) {
      try {
        for (const frame of translate(JSON.parse(lineBuffer), state)) {
          res.write(JSON.stringify(frame) + '\n');
        }
      } catch (e) {}
    }
    if (state.sessionId) {
      res.write(JSON.stringify({ type: 'session_id', session_id: state.sessionId }) + '\n');
    }
    // Final diagnostic event: exit code/signal + stderr tail, so harness.rb can
    // fold the real cause into the error it raises.
    res.write(JSON.stringify({
      type: 'exit',
      code,
      signal,
      timed_out: timedOut,
      stderr: stderrTail.trim(),
    }) + '\n');
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

// Starts the HTTP listener. Split out from module load so requiring this file
// (e.g. from test/js/translate_test.js) only defines the pure translation
// functions — it doesn't seed the agent dir or bind a port as a side effect.
function startServer() {
  seedAgentDir();

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

    const tools     = req.headers['x-harness-tools'];
    const model     = req.headers['x-harness-model'] || null;
    const sessionId = req.headers['x-harness-session'] || null;

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
    process.stderr.write(`pi HTTP server listening on port ${PORT}\n`);
  });
}

if (require.main === module) startServer();

module.exports = { translate, settleResult, extractText, lastAssistantOf };
