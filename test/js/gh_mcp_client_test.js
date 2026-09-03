// Plain-Node test for gh-mcp-client.js — the request building, response
// parsing and trimming behind the `gh_query` tool. pi-mcp.ts itself cannot be
// loaded outside the harness image (it imports typebox and pi-ai), so this is
// where the GitHub side's logic is actually asserted.
const assert = require('assert');
const {
  OPERATIONS, buildRequestBody, parseToolResult, trim, summarize, MAX_ANSWER_BYTES,
} = require('../../gh-mcp-client.js');
const { GH_READ_ONLY_OPS } = require('../../mcp-gw.js');

let failures = 0;
function test(name, fn) {
  try { fn(); console.log(`PASS ${name}`); }
  catch (e) { failures++; console.log(`FAIL ${name}\n  ${e.message}`); }
}

test('the operations the model is offered are the ones the gateway allows', () => {
  // Two copies in two containers; the gateway is the authority, and this is
  // what stops the schema drifting away from it.
  assert.deepStrictEqual([...OPERATIONS].sort(), [...GH_READ_ONLY_OPS].sort());
});

test('only the fields actually set are forwarded', () => {
  const body = buildRequestBody({ operation: 'list_commits', owner: 'opf', repo: 'openproject', path: '' });
  assert.deepStrictEqual(body.params, { name: 'list_commits', arguments: { owner: 'opf', repo: 'openproject' } });
  assert.strictEqual(body.method, 'tools/call');
});

test('a stringified number is coerced, because models stringify numbers', () => {
  const { params } = buildRequestBody({ operation: 'pull_request_read', owner: 'o', repo: 'r', pullNumber: '18734' });
  assert.strictEqual(params.arguments.pullNumber, 18734);
});

test('a non-numeric value is forwarded unchanged, to earn the upstream error', () => {
  const { params } = buildRequestBody({ operation: 'pull_request_read', owner: 'o', repo: 'r', pullNumber: 'HEAD' });
  assert.strictEqual(params.arguments.pullNumber, 'HEAD');
});

test('all three response shapes are read', () => {
  assert.deepStrictEqual(parseToolResult({ result: { structuredContent: { a: 1 } } }), { isError: false, payload: { a: 1 } });
  assert.deepStrictEqual(parseToolResult({ result: { content: [{ text: '{"a":1}' }] } }), { isError: false, payload: { a: 1 } });
  assert.deepStrictEqual(parseToolResult({ result: { content: [{ text: 'plain' }] } }), { isError: false, payload: 'plain' });
});

test('an error result and a JSON-RPC error both come back as errors', () => {
  assert.ok(parseToolResult({ error: { message: 'bad credentials' } }).isError);
  assert.ok(parseToolResult({ result: { isError: true, content: [{ text: 'not found' }] } }).isError);
  assert.ok(parseToolResult({}).isError);
});

test('a user object collapses to its login', () => {
  assert.strictEqual(trim({ login: 'thykel', avatar_url: 'https://…', id: 5 }), 'thykel');
});

test('noise is dropped and long bodies are cut', () => {
  const out = trim({ number: 7, title: 'Fix it', body: 'x'.repeat(2000), avatar_url: 'n', node_id: 'n' });
  assert.deepStrictEqual(Object.keys(out).sort(), ['body', 'number', 'title']);
  assert.ok(out.body.length < 700 && out.body.endsWith('…'));
});

test('a long list is cut and says how much it dropped', () => {
  const out = trim(Array.from({ length: 50 }, (_, i) => ({ number: i })));
  assert.strictEqual(out.length, 31);
  assert.strictEqual(out[30], '…[20 more]');
});

test('a shape the trimmer does not recognise is returned whole, not emptied', () => {
  // Trimming must never turn an answer the model could have used into {}.
  assert.strictEqual(summarize('get_commit', { unknown_field: 'value' }), '{"unknown_field":"value"}');
});

test('the answer is capped and says so', () => {
  const huge = { body: 'y'.repeat(80_000) };
  const out = summarize('issue_read', { items: [huge] });
  assert.ok(Buffer.byteLength(out) <= MAX_ANSWER_BYTES + 100);
});

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
