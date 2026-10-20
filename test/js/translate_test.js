// Plain-Node test for server.js's pi -> opilot NDJSON translation. No test
// framework (the repo has none for JS): run with `node test/js/translate_test.js`.
//
// Fixtures under test/fixtures/pi/ are real pi 0.84.2 --mode json transcripts
// (captured against a stub upstream), except tool_use_and_success.ndjson,
// which is hand-authored from the same verified event shapes (docs/json.md
// plus the AssistantMessage/TextContent/ToolCall types in pi-mono's
// packages/ai/src/types.ts) because no live OpenRouter credential was
// available to capture a real successful run.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { translate, settleResult, buildSettings, piHttpIdleTimeoutMs } = require('../../harness/server.js');

const FIXTURES_DIR = path.join(__dirname, '..', 'fixtures', 'pi');

function runTranscript(filename) {
  const lines = fs.readFileSync(path.join(FIXTURES_DIR, filename), 'utf8')
    .split('\n').filter(l => l.trim());
  const state = {};
  const frames = [];
  for (const line of lines) {
    frames.push(...translate(JSON.parse(line), state));
  }
  return { frames, state };
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

test('auth failure settles as a single error result, session id captured', () => {
  const { frames, state } = runTranscript('error_auth_failure.ndjson');
  assert.strictEqual(state.sessionId, '01a00169-5911-73af-b92c-bace89272aa1');
  const results = frames.filter(f => f.type === 'result');
  assert.strictEqual(results.length, 1, 'exactly one result frame — agent_settled fires once here');
  assert.strictEqual(results[0].is_error, true);
  assert.strictEqual(results[0].subtype, 'error_during_execution');
  assert.match(results[0].result, /Missing Authentication header/);
});

test('a retry storm before an eventual success reports only the final outcome', () => {
  const { frames } = runTranscript('retry_then_settle.ndjson');
  const results = frames.filter(f => f.type === 'result');
  // Three agent_end events fire (two transient errors, one final success) but
  // only agent_settled (once) may emit a result frame — this is the exact
  // failure mode an agent_end-triggered design would get wrong.
  assert.strictEqual(results.length, 1, 'only agent_settled emits a result, not every agent_end');
  assert.strictEqual(results[0].is_error, false);
  assert.strictEqual(results[0].subtype, 'success');
  assert.strictEqual(results[0].result, 'Here are the files.');
});

test('tool_execution_start becomes a tool_use assistant frame; each text_delta streams live, text_end carries the one authoritative copy', () => {
  const { frames } = runTranscript('tool_use_and_success.ndjson');
  const assistantFrames = frames.filter(f => f.type === 'assistant');
  const toolUse = assistantFrames.find(f => f.message.content[0].type === 'tool_use');
  assert.ok(toolUse, 'expected a tool_use frame');
  assert.strictEqual(toolUse.message.content[0].name, 'bash');
  assert.deepStrictEqual(toolUse.message.content[0].input, { command: 'git -C /repos/openproject log --oneline -1' });

  // The fixture has text_start + two text_delta + one text_end for this
  // block. Each delta is forwarded raw (harness.rb prints it unrendered, live,
  // as it arrives — no Markdown parser sees a lone word-fragment) so a
  // long-running block is visible instead of leaving the terminal silent.
  // text_end still carries the complete block exactly once: the one
  // authoritative copy used for the return value, the log, and capture's
  // outfile.
  const deltaFrames = assistantFrames.filter(f => f.message.content[0].type === 'text_delta');
  assert.deepStrictEqual(deltaFrames.map(f => f.message.content[0].text), ['The ', 'repo is at abc1234.']);

  const textFrames = assistantFrames.filter(f => f.message.content[0].type === 'text');
  assert.strictEqual(textFrames.length, 1, 'exactly one text frame — the authoritative copy, flushed on text_end');
  assert.strictEqual(textFrames[0].message.content[0].text, 'The repo is at abc1234.');

  const result = frames.find(f => f.type === 'result');
  assert.strictEqual(result.is_error, false);
  assert.strictEqual(result.result, 'The repo is at abc1234.');
});

test('thinking_delta is forwarded raw too, so a truncated reasoning block is not silent', () => {
  // This is exactly the TTP2-22 failure mode: a reasoning model's "thinking"
  // block ran long enough to hit the model's output-length cap before ever
  // reaching thinking_end, so the old text_end-only forwarding produced zero
  // frames for the whole run — total terminal silence, then a bare
  // error_length with no context.
  const state = {};
  const frames = [
    ...translate({ type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', contentIndex: 0, delta: 'Let me check ' } }, state),
    ...translate({ type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', contentIndex: 0, delta: 'the issue first.' } }, state),
  ];
  assert.deepStrictEqual(
    frames.map(f => f.message.content[0]),
    [{ type: 'thinking_delta', text: 'Let me check ' }, { type: 'thinking_delta', text: 'the issue first.' }],
  );
});

test('settleResult: no assistant message at all is an error, not a silent empty success', () => {
  const r = settleResult(null);
  assert.strictEqual(r.is_error, true);
  assert.strictEqual(r.subtype, 'error_no_response');
});

test('settleResult: a non-error, non-stop reason (e.g. length) is still an error', () => {
  const r = settleResult({ stopReason: 'length', content: [{ type: 'text', text: 'partial...' }] });
  assert.strictEqual(r.is_error, true);
  assert.strictEqual(r.subtype, 'error_length');
  assert.strictEqual(r.result, 'partial...');
});

test('an agent_end with no assistant message does not clobber a prior good one', () => {
  // A compaction/overflow retry cycle's agent_end can carry messages with no
  // assistant entry at all. If translate() ever assigns unconditionally, this
  // null overwrites the earlier success and agent_settled wrongly reports
  // error_no_response on a run that actually succeeded.
  const state = {};
  translate({ type: 'agent_end', messages: [
    { role: 'assistant', content: [{ type: 'text', text: 'done.' }], stopReason: 'stop' },
  ] }, state);
  translate({ type: 'agent_end', messages: [
    { role: 'user', content: [{ type: 'text', text: 'compacting...' }] },
  ] }, state);
  const [frame] = translate({ type: 'agent_settled' }, state);
  assert.strictEqual(frame.is_error, false);
  assert.strictEqual(frame.result, 'done.');
});

test('usage adds up over every assistant message, a failed attempt included', () => {
  const state = {};
  const usage = (input, output, total) => ({ input, output, cacheRead: 10, cacheWrite: 0, cost: { total } });
  translate({ type: 'message_end', message: { role: 'user', usage: usage(999, 999, 9) } }, state);
  translate({ type: 'message_end', message: { role: 'assistant', stopReason: 'error', usage: usage(100, 0, 0.01) } }, state);
  translate({ type: 'message_end', message: { role: 'assistant', stopReason: 'stop', usage: usage(200, 50, 0.02) } }, state);
  translate({ type: 'agent_end', messages: [{ role: 'assistant', content: [{ type: 'text', text: 'ok' }], stopReason: 'stop' }] }, state);
  const [frame] = translate({ type: 'agent_settled' }, state);
  assert.deepStrictEqual({ ...frame.usage, cost: Math.round(frame.usage.cost * 100) / 100 },
    { input: 300, output: 50, cache_read: 20, cache_write: 0, cost: 0.03 });
});

test('a run with no usage reported has no usage field', () => {
  const state = { lastAssistantMessage: { stopReason: 'stop', content: [] } };
  assert.strictEqual(translate({ type: 'agent_settled' }, state)[0].usage, undefined);
});

test('retries and compaction become notice frames', () => {
  const state = {};
  const texts = [
    { type: 'auto_retry_start', attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: '529 overloaded' },
    { type: 'auto_retry_end', success: true, attempt: 2 },
    { type: 'auto_retry_end', success: false, finalError: 'gave up' },
    { type: 'compaction_start', reason: 'overflow' },
    { type: 'compaction_end', reason: 'overflow', aborted: false, errorMessage: 'too big' },
  ].flatMap(e => translate(e, state)).map(f => { assert.strictEqual(f.type, 'notice'); return f.text; });
  assert.deepStrictEqual(texts, [
    'provider error, retry 1/3 in 2s: 529 overloaded',
    'retries failed: gave up',
    'compacting the context (overflow)',
    'compaction failed: too big',
  ]);
});

test("pi's HTTP idle timeout sits below the server's idle bound, with a floor", () => {
  assert.strictEqual(piHttpIdleTimeoutMs(5 * 60 * 1000), 2 * 60 * 1000);
  assert.strictEqual(piHttpIdleTimeoutMs(60 * 1000), 60 * 1000);
  assert.strictEqual(buildSettings(10 * 60 * 1000).httpIdleTimeoutMs, 4 * 60 * 1000);
  assert.strictEqual(buildSettings().defaultProjectTrust, 'never', 'pi-settings.json is kept');
});

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
