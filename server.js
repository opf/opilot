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

// Two independent bounds on one pi run, because "too long" and "stuck" are not
// the same failure. A real implementation run streams tool calls and text the
// whole way through, so *silence* is the signal that a run has wedged — a total
// wall-clock cap instead kills a productive run purely for being big, which is
// exactly what a multi-repo fix on a large product repo is. So the tight bound
// is on idle time, rearmed on every byte pi writes.
//
// The absolute ceiling is the backstop under it, and it exists because this
// server is serialized (the queue below): one run that never falls silent but
// never finishes would block every other tick's LLM call — the op-agent poll,
// the CI fixer, every other PR — for as long as it ran.
//
// Both bounds sit INSIDE harness.rb's READ_TIMEOUT, which derives itself from
// these same two env vars for exactly that reason — the runner must not give up
// on a run this server is still about to report an `exit` frame for, and a
// queued request sees a silent socket for the whole of the run ahead of it.
//
// Both knobs are in MINUTES — the unit an operator actually reasons in for
// "how long may one fix take". Fractions are accepted (0.5 = 30s), and any
// non-numeric or non-positive value falls back to the default.
const minutes = (name, fallback) => {
  const value = Number(process.env[name]);
  return (Number.isFinite(value) && value > 0 ? value : fallback) * 60 * 1000;
};
const PROC_IDLE_TIMEOUT_MS = minutes('OPILOT_PI_IDLE_TIMEOUT_MIN', 5);
const PROC_MAX_MS = minutes('OPILOT_PI_MAX_RUN_MIN', 45);
// SIGTERM is a request. A pi that ignores it would never fire 'close', so
// `done()` never runs and `busy` stays set for the life of the container —
// every later request queues behind a process that is already gone.
const PROC_KILL_GRACE_MS = 10 * 1000;

// Server-side allowlist of tool grants. The header is client-controlled, so
// only the exact grants the runner uses are accepted. pi's tool names are
// lowercase and there's no glob tool — `find` covers that job.
// Must stay in sync with TOOLS_READ / TOOLS_IMPL in lib/opilot/harness.rb.
const ALLOWED_TOOL_GRANTS = new Set([
  'read,grep,find,ls,bash',
  'read,grep,find,ls,bash,write,edit',
]);

const SESSION_ID_RE = /^[A-Za-z0-9_-]{1,128}$/;
// A model id carries a vendor slug behind a provider prefix, e.g.
// "openrouter/anthropic/claude-opus-4.8" or "local/qwen2.5-coder:7b"
// (harness.rb supplies the full string; server.js does no prefixing of its
// own). Validated by shape, not an allowlist: it grants no privilege (unlike
// the tool grants above), so the only risk is a malformed value reaching
// --model. Forbids spaces and a leading dash so it can't smuggle extra CLI
// args. The colon is required for self-hosted ids — every Ollama tag has one
// (qwen2.5-coder:7b), and pi also reads a trailing ":<thinking>" suffix.
const MODEL_RE = /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/;

const PI_AGENT_DIR   = process.env.PI_CODING_AGENT_DIR || '/pi-agent';
const PI_SESSION_DIR = process.env.PI_CODING_AGENT_SESSION_DIR || '/sessions';

// The wire protocols pi can speak. OPILOT_MODEL_API selects one; it is the
// axis the auth header does NOT cover, and the reason an Anthropic-native or
// Google-native upstream needs both settings rather than just a header swap.
const PI_APIS = new Set([
  'openai-completions', 'openai-responses', 'anthropic-messages', 'google-generative-ai',
]);

// The provider prefix on the configured model slug decides which provider
// config pi gets: "openrouter/..." uses the file in git, anything else is
// generated below. One signal, stated once — no separate mode variable that
// could disagree with the slug.
function providerPrefix(slug) {
  const i = (slug || '').indexOf('/');
  return i === -1 ? '' : slug.slice(0, i);
}

// Builds a models.json for a self-hosted upstream, from the two slugs already
// in the environment. The ids are the slugs minus their provider prefix,
// deduped — a self-hosted server usually serves one model, so heavy and light
// normally collapse to a single entry.
//
// baseUrl is authgw, not the model server: the harness has no other route out,
// and authgw re-applies the upstream's own path prefix. That is why this is
// always /v1 regardless of what the upstream serves.
function buildModelsJson(env = process.env) {
  const heavy = env.OPILOT_MODEL_HEAVY || '';
  const light = env.OPILOT_MODEL_LIGHT || '';
  const provider = providerPrefix(heavy);
  if (!provider) throw new Error(`OPILOT_MODEL_HEAVY needs a provider prefix (got: ${heavy || '<empty>'})`);

  const api = env.OPILOT_MODEL_API || 'openai-completions';
  if (!PI_APIS.has(api)) {
    throw new Error(`OPILOT_MODEL_API must be one of ${[...PI_APIS].join(', ')} (got: ${api})`);
  }

  const ids = [...new Set([heavy, light]
    .filter(slug => providerPrefix(slug) === provider)
    .map(slug => slug.slice(provider.length + 1))
    .filter(Boolean))];
  if (ids.length === 0) throw new Error(`no model id in OPILOT_MODEL_HEAVY (got: ${heavy})`);

  const contextWindow = Number(env.OPILOT_MODEL_CONTEXT_WINDOW);
  const model = id => (Number.isFinite(contextWindow) && contextWindow > 0
    ? { id, contextWindow }
    : { id });

  const config = {
    baseUrl: 'http://authgw:47292/v1',
    api,
    // A dummy value, and the convention rather than a workaround: pi hides
    // models that have no auth configured, and keyless servers ignore it.
    // This is the same non-secret handshake authgw already expects.
    apiKey: '$OPILOT_GW_TOKEN',
    models: ids.map(model),
  };

  // Only meaningful for openai-completions: Ollama, vLLM and SGLang understand
  // neither the `developer` role nor `reasoning_effort` (pi's docs/models.md).
  // The other protocols have their own compat keys, so emitting these there
  // would be noise at best.
  if (api === 'openai-completions') {
    config.compat = { supportsDeveloperRole: false, supportsReasoningEffort: false };
  }

  return { providers: { [provider]: config } };
}

// Copies the image's baked-in config into the writable agent dir on every
// boot, so pi-settings.json/pi-models.json stay in version control and the
// first-run wizard needs no change. Unconditional, not "if missing": these
// files are meant to be exactly what's in git — an edit to pi-models.json (e.g.
// adding a compat flag) must take effect on the next container start, not be
// masked forever by a copy seeded before the edit existed. Neither file is
// meant to be hand-edited in the running container (unlike pi's own
// auth.json, untouched here), so this can't discard anything meant to persist.
//
// models.json is GENERATED instead of copied when the configured model is not
// an openrouter/… slug, and generated with exactly the same unconditional
// rule — a file written before a config change must never mask it either.
function seedAgentDir(env = process.env) {
  fs.mkdirSync(PI_AGENT_DIR, { recursive: true });
  fs.copyFileSync(path.join('/app', 'pi-settings.json'), path.join(PI_AGENT_DIR, 'settings.json'));

  const modelsPath = path.join(PI_AGENT_DIR, 'models.json');
  if (providerPrefix(env.OPILOT_MODEL_HEAVY || 'openrouter/') === 'openrouter') {
    fs.copyFileSync(path.join('/app', 'pi-models.json'), modelsPath);
  } else {
    fs.writeFileSync(modelsPath, JSON.stringify(buildModelsJson(env), null, 2) + '\n');
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
//   {"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":...}}
//   {"type":"message_update","assistantMessageEvent":{"type":"text_end","content":...}}
//   {"type":"agent_end","messages":[...],"willRetry":bool}
//   {"type":"agent_settled"}
//
// text_delta/thinking_delta are forwarded raw, printed as they arrive with no
// Markdown parsing — pi's deltas are token/word fragments, and running each
// one alone through a full Markdown parser (TTY::Markdown, in
// render_markdown) reflows it into its own paragraph (stray blank lines) and
// can split an inline code span whose backticks land in different deltas.
// The previous design waited for text_end (the FULL text for one content
// block) to get correctly-rendered Markdown, but that means a block that
// never reaches text_end — e.g. a reasoning model's "thinking" block long
// enough to hit the model's output-length cap — prints nothing at all for as
// long as it runs, then surfaces only as an `error_length` with no context.
// Silence-then-failure is worse than slightly-reflowed Markdown while typing,
// so raw deltas are shown live and text_end/thinking_end now only supply the
// authoritative final text (for the return value, the log, and capture's
// outfile) — see harness.rb's http_stream.
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
      } else if (evt && (evt.type === 'text_delta' || evt.type === 'thinking_delta') && evt.delta) {
        frames.push({ type: 'assistant', message: { content: [{ type: evt.type, text: evt.delta }] } });
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

  // Non-null once a bound has fired, and which one ("idle"/"max") — one
  // variable, because "did it time out" is just "is this set".
  let timeoutKind = null;
  let idleTimer = null;
  let killTimer = null;

  const killPi = kind => {
    timeoutKind = kind;
    process.stderr.write(`pi process ${kind} timeout — killing\n`);
    proc.kill('SIGTERM');
    killTimer = setTimeout(() => proc.kill('SIGKILL'), PROC_KILL_GRACE_MS);
  };

  const maxTimer = setTimeout(() => killPi('max'), PROC_MAX_MS);
  // Rearm the idle bound on every byte pi writes (see the constants above).
  // Once a kill is under way the timers are done — do not rearm on the output
  // pi flushes while it shuts down.
  const bumpIdle = () => {
    if (timeoutKind) return;
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => killPi('idle'), PROC_IDLE_TIMEOUT_MS);
  };
  const clearTimers = () => {
    clearTimeout(idleTimer);
    clearTimeout(maxTimer);
    clearTimeout(killTimer);
  };
  bumpIdle();

  proc.stdin.end(body);

  res.writeHead(200, { 'Content-Type': 'application/x-ndjson' });

  const state = {};
  let lineBuffer = '';
  // One line of pi's stdout → zero or more frames on the wire. A blank or
  // unparseable line is skipped rather than fatal: pi's stdout is a stream we
  // translate, not a contract we validate. Used for both the complete lines
  // below and the trailing partial one at 'close'.
  const emit = line => {
    if (!line.trim()) return;
    let parsed;
    try { parsed = JSON.parse(line); } catch (e) { return; }
    for (const frame of translate(parsed, state)) {
      res.write(JSON.stringify(frame) + '\n');
    }
  };

  proc.stdout.on('data', chunk => {
    bumpIdle();
    lineBuffer += chunk.toString();
    const lines = lineBuffer.split('\n');
    lineBuffer = lines.pop();
    lines.forEach(emit);
  });

  // Mirror stderr to the container log AND keep a bounded tail to forward to
  // the runner. A pre-flight CLI failure (e.g. --session pointing at a
  // session pi can't find) prints a plain-text line to stderr, exits 1, and
  // emits NO JSON at all — the stderr tail is the only place that reason
  // exists, forwarded via the exit event below.
  const STDERR_TAIL_MAX = 8000;
  let stderrTail = '';
  proc.stderr.on('data', chunk => {
    // Counts as progress too: a run whose only output is a warning or a
    // provider retry on stderr is working, not wedged.
    bumpIdle();
    process.stderr.write(chunk);
    stderrTail = (stderrTail + chunk.toString()).slice(-STDERR_TAIL_MAX);
  });

  proc.on('close', (code, signal) => {
    clearTimers();
    emit(lineBuffer);
    if (state.sessionId) {
      res.write(JSON.stringify({ type: 'session_id', session_id: state.sessionId }) + '\n');
    }
    // Final diagnostic event: exit code/signal + stderr tail, so harness.rb can
    // fold the real cause into the error it raises.
    res.write(JSON.stringify({
      type: 'exit',
      code,
      signal,
      timed_out: timeoutKind !== null,
      // Which bound fired ("idle" or "max"), so the runner's error names the
      // real cause: a stalled run and an over-long one need different answers.
      timeout_kind: timeoutKind,
      stderr: stderrTail.trim(),
    }) + '\n');
    res.end();
    done();
  });

  proc.on('error', err => {
    clearTimers();
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

module.exports = {
  translate, settleResult, extractText, lastAssistantOf,
  buildModelsJson, providerPrefix, MODEL_RE, ALLOWED_TOOL_GRANTS,
};
