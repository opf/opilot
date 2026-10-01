// Plain-Node test for harness/mcp-shape.js — how pi-mcp.ts trims an MCP answer
// before the model sees it. Run with `node test/js/mcp_shape_test.js`.
const assert = require('assert');
const { shapeCallResult, PI_LIMIT_BYTES } = require('../../harness/mcp-shape.js');

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

const textOf = content => content[0].text;

test('a work-package search is trimmed to what a plan reads', () => {
  const item = { id: 7, displayId: 'TTP2-7', subject: 'Login fails', description: { raw: 'x'.repeat(400) },
                 _links: { status: { title: 'New' }, type: { title: 'Bug' }, project: { title: 'TTP2' } },
                 startDate: '2026-01-01', costs: { spent: 1 } };
  const content = shapeCallResult('openproject', 'search_work_packages', {
    content: [{ type: 'text', text: JSON.stringify({ total: 1, items: [item] }) }] });
  const [w] = JSON.parse(textOf(content)).items;
  assert.deepStrictEqual(Object.keys(w).sort(),
    ['description', 'displayId', 'id', 'project', 'status', 'subject', 'type', 'updatedAt']);
  assert.strictEqual(w.status, 'New');
  assert.strictEqual(w.description.length, 301);
});

test('structuredContent is preferred over the text, whichever format the instance uses', () => {
  const content = shapeCallResult('openproject', 'list_types', {
    content: [{ type: 'text', text: 'ignored' }], structuredContent: { items: [{ id: 1 }] } });
  assert.deepStrictEqual(JSON.parse(textOf(content)), { items: [{ id: 1 }] });
});

test('a GitHub answer keeps the fields a question reads, and a user is its login', () => {
  const pr = { number: 5, title: 'Fix', node_id: 'N', user: { login: 'octo', avatar_url: 'a' }, url: 'u' };
  const content = shapeCallResult('github', 'pull_request_read', {
    content: [{ type: 'text', text: JSON.stringify(pr) }] });
  assert.deepStrictEqual(JSON.parse(textOf(content)), { number: 5, title: 'Fix', user: 'octo' });
});

test('a GitHub shape the trimmer does not know is passed whole, not emptied', () => {
  const content = shapeCallResult('github', 'list_tags', { content: [{ type: 'text', text: '{"odd":1}' }] });
  assert.deepStrictEqual(JSON.parse(textOf(content)), { odd: 1 });
});

test('an answer still over pi\'s limit keeps pi\'s own content', () => {
  // pi has already cut it and saved the full text; ours would be uncut.
  const big = 'y'.repeat(PI_LIMIT_BYTES + 10);
  assert.strictEqual(shapeCallResult('github', 'get_file_contents', { content: [{ type: 'text', text: big }] }), null);
});

test('a result with no content is left to pi', () => {
  assert.strictEqual(shapeCallResult('openproject', 'list_types', {}), null);
  assert.strictEqual(shapeCallResult('openproject', 'list_types', undefined), null);
});

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
