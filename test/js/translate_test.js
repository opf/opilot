// Plain-Node test for server.js's pi -> chomper NDJSON translation. No test
// framework (the repo has none for JS — see docs/pi-harness-plan.md's
// Verification section): run with `node test/js/translate_test.js`.
//
// Fixtures under test/fixtures/pi/ are real pi 0.84.2 --mode json transcripts
// (captured against a stub upstream during the Claude Code -> pi migration
// spike), except tool_use_and_success.ndjson, which is hand-authored from the
// same verified event shapes (docs/json.md plus the AssistantMessage/
// TextContent/ToolCall types in pi-mono's packages/ai/src/types.ts) because no
// live OpenRouter credential was available to capture a real successful run.
const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { translate, settleResult } = require('../../server.js');

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

test('tool_execution_start becomes a tool_use assistant frame; text flushes once, on text_end, not per delta', () => {
  const { frames } = runTranscript('tool_use_and_success.ndjson');
  const assistantFrames = frames.filter(f => f.type === 'assistant');
  const toolUse = assistantFrames.find(f => f.message.content[0].type === 'tool_use');
  assert.ok(toolUse, 'expected a tool_use frame');
  assert.strictEqual(toolUse.message.content[0].name, 'bash');
  assert.deepStrictEqual(toolUse.message.content[0].input, { command: 'git -C /repos/openproject log --oneline -1' });

  // The fixture has text_start + two text_delta + one text_end for this
  // block. Forwarding each delta as its own frame is exactly the bug this
  // guards against: claude.rb runs every "text" part through a full Markdown
  // parser (render_markdown), which reflows a lone word-fragment into its own
  // paragraph — the stray-newline bug. Only text_end (the complete block)
  // may become a frame.
  const textFrames = assistantFrames.filter(f => f.message.content[0].type === 'text');
  assert.strictEqual(textFrames.length, 1, 'exactly one text frame — flushed on text_end, not one per delta');
  assert.strictEqual(textFrames[0].message.content[0].text, 'The repo is at abc1234.');

  const result = frames.find(f => f.type === 'result');
  assert.strictEqual(result.is_error, false);
  assert.strictEqual(result.result, 'The repo is at abc1234.');
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

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
