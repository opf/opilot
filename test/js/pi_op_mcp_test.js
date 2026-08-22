// Plain-Node test for op-mcp-client.js — the pure logic behind the `op_query`
// pi tool (request building, response parsing, the trimmer, error mapping).
// Run with `node test/js/pi_op_mcp_test.js`.
//
// pi-op-mcp.ts itself (the actual tool registration) is NOT tested here: it
// imports typebox and @earendil-works/pi-ai, which only jiti's module
// resolution inside pi can find — see its own header comment. Everything
// that logic delegates to lives in op-mcp-client.js, which is plain
// CommonJS and loads fine under plain Node, same reasoning as authgw_test.js.
const assert = require('assert');
const {
  OPERATIONS, buildRequestBody, parseToolResult, summarize, unavailableMessage, MAX_ANSWER_BYTES,
} = require('../../op-mcp-client.js');

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

// ── request building ─────────────────────────────────────────────────────

test('only the flat fields actually set are forwarded as arguments', () => {
  const body = buildRequestBody({ operation: 'list_work_package_comments', work_package_id: '42' });
  assert.strictEqual(body.method, 'tools/call');
  assert.strictEqual(body.params.name, 'list_work_package_comments');
  assert.deepStrictEqual(body.params.arguments, { work_package_id: '42' });
});

test('an unset optional field never becomes a literal null/empty', () => {
  const body = buildRequestBody({ operation: 'search_work_packages', subject: '', project_id: undefined, status_id: null });
  assert.deepStrictEqual(body.params.arguments, {});
});

test('every op_query operation is one of the eight read-only ops', () => {
  assert.strictEqual(OPERATIONS.length, 8);
  assert.ok(OPERATIONS.includes('search_work_packages'));
  assert.ok(!OPERATIONS.includes('create_work_package'));
});

// ── response parsing — the three format an administrator can pick ────────

test('prefers structuredContent when present', () => {
  const rpc = { jsonrpc: '2.0', id: 1, result: { structuredContent: { total: 1, items: [{ id: 1 }] } } };
  const { isError, payload } = parseToolResult(rpc);
  assert.strictEqual(isError, false);
  assert.deepStrictEqual(payload, { total: 1, items: [{ id: 1 }] });
});

test('falls back to parsing the JSON string in content[0].text', () => {
  const rpc = { jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: '{"total":2,"items":[]}' }] } };
  const { payload } = parseToolResult(rpc);
  assert.deepStrictEqual(payload, { total: 2, items: [] });
});

test('falls back to the plain text when content is not JSON', () => {
  const rpc = { jsonrpc: '2.0', id: 1, result: { content: [{ type: 'text', text: 'plain answer' }] } };
  const { payload } = parseToolResult(rpc);
  assert.strictEqual(payload, 'plain answer');
});

test('a JSON-RPC-level error is reported, not thrown', () => {
  const rpc = { jsonrpc: '2.0', id: 1, error: { code: -32601, message: 'method not found' } };
  const { isError, errorText } = parseToolResult(rpc);
  assert.strictEqual(isError, true);
  assert.strictEqual(errorText, 'method not found');
});

test('an MCP-level isError is reported too', () => {
  const rpc = { jsonrpc: '2.0', id: 1, result: { isError: true, content: [{ type: 'text', text: 'bad filter' }] } };
  const { isError, errorText } = parseToolResult(rpc);
  assert.strictEqual(isError, true);
  assert.strictEqual(errorText, 'bad filter');
});

test('no result at all is reported as an error, not a crash', () => {
  const { isError } = parseToolResult({ jsonrpc: '2.0', id: 1 });
  assert.strictEqual(isError, true);
});

// ── the trimmer ────────────────────────────────────────────────────────

test('search_work_packages items are trimmed to a fixed subset', () => {
  const payload = {
    total: 54,
    items: [{
      id: 123, subject: 'Broken export', type: { name: 'Bug' }, status: { name: 'New' },
      project: { name: 'Core' }, updatedAt: '2026-08-20T00:00:00Z',
      description: { raw: 'x'.repeat(500) },
      _links: { self: { href: '/api/v3/work_packages/123' } },
    }],
  };
  const out = JSON.parse(summarize('search_work_packages', payload));
  assert.strictEqual(out.total, 54);
  assert.strictEqual(out.returned, 1);
  const item = out.items[0];
  assert.deepStrictEqual(Object.keys(item).sort(),
    ['description', 'displayId', 'id', 'project', 'status', 'subject', 'type', 'updatedAt'].sort());
  assert.strictEqual(item.type, 'Bug');
  assert.strictEqual(item.status, 'New');
  assert.strictEqual(item.project, 'Core');
  assert.ok(item.description.length <= 301, 'description is excerpted, not carried whole');
  assert.strictEqual('_links' in item, false, 'the _links section must not survive the trim');
});

test('a link field given as a HAL {href,title} object is read by title', () => {
  const payload = { total: 1, items: [{ id: 1, subject: 's', _links: { type: { title: 'Feature' } } }] };
  const out = JSON.parse(summarize('search_work_packages', payload));
  assert.strictEqual(out.items[0].type, 'Feature');
});

test('every other operation passes its payload through untrimmed (just capped)', () => {
  const payload = { statuses: [{ id: 1, name: 'New' }] };
  const out = JSON.parse(summarize('list_statuses', payload));
  assert.deepStrictEqual(out, payload);
});

test('an oversized answer is capped and the truncation is stated, not silent', () => {
  // Only search_work_packages trims individual items; every other operation's
  // answer passes through whole, so it's the one whose OWN size can exceed
  // the cap — e.g. a work package with an unusually long comment thread.
  const payload = { comments: [{ id: 1, text: 'y'.repeat(MAX_ANSWER_BYTES) }] };
  const out = summarize('list_work_package_comments', payload);
  assert.ok(Buffer.byteLength(out, 'utf8') <= MAX_ANSWER_BYTES + 100);
  assert.ok(out.includes('truncated'));
});

// ── the 404 case ──────────────────────────────────────────────────────────

test('the unavailable message tells the model to fall back, not to retry', () => {
  assert.ok(/mirrors/.test(unavailableMessage()));
});

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
