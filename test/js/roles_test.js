// Plain-Node test for server.js's role check. Run with `node test/js/roles_test.js`.
//
// It loads the real roles/ directory, the same files the runner loads, so a
// role file the server cannot read fails here rather than at container boot.
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseRole, loadRoles, grantsFor, checkRole, ALLOWED_TOOL_GRANTS } = require('../../server.js');

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

const READ = 'read,grep,find,ls,bash';
const WRITE = 'read,grep,find,ls,bash,write,edit';
const roles = loadRoles();
const good = '---\ntools: read\nmcp: false\nmodel: heavy\nmemory: none\n---\nDoes x.\n';

test('the real role files load', () => {
  assert.ok(roles.size >= 11, `only ${roles.size} roles`);
  assert.deepStrictEqual(roles.get('planner'), { base: READ, mcp: true });
  assert.deepStrictEqual(roles.get('implementer'), { base: WRITE, mcp: false });
});

test('every grant a role allows is one the allowlist holds', () => {
  for (const [name, role] of roles) {
    for (const grant of grantsFor(role)) assert.ok(ALLOWED_TOOL_GRANTS.has(grant), `${name}: ${grant}`);
  }
});

test('a role without mcp allows only its base grant', () => {
  assert.deepStrictEqual(grantsFor({ base: READ, mcp: false }), [READ]);
  assert.strictEqual(grantsFor({ base: READ, mcp: true }).length, 4);
});

test('a matching role and grant pass', () => {
  assert.strictEqual(checkRole(roles, 'planner', `${READ},op_query`), null);
  assert.strictEqual(checkRole(roles, 'implementer', WRITE), null);
});

test('a write grant under a read role is refused', () => {
  assert.deepStrictEqual(checkRole(roles, 'advisor', WRITE), [403, 'tool grant not allowed for role advisor']);
});

test('an MCP tool under a role without mcp is refused', () => {
  assert.strictEqual(checkRole(roles, 'wp_writer', `${READ},op_query`)[0], 403);
});

test('a missing role, an unknown role and a missing grant are refused', () => {
  assert.deepStrictEqual(checkRole(roles, null, READ), [400, 'missing role']);
  assert.deepStrictEqual(checkRole(roles, 'root', READ), [403, 'unknown role']);
  assert.deepStrictEqual(checkRole(roles, '../x', READ), [403, 'unknown role']);
  assert.deepStrictEqual(checkRole(roles, 'planner', undefined), [403, 'missing tool grant']);
});

test('a malformed role file fails to parse', () => {
  assert.deepStrictEqual(parseRole(good, 'x'), { base: READ, mcp: false });
  for (const bad of [
    good.replace('read', 'admin'),
    good.replace('mcp: false\n', ''),
    good.replace('memory: none', 'memory: none\nextra: 1'),
    'no frontmatter\n',
  ]) {
    assert.throws(() => parseRole(bad, 'x'), undefined, JSON.stringify(bad));
  }
});

test('an empty roles directory fails to load', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'roles-'));
  assert.throws(() => loadRoles(dir), /no role files/);
});

if (failures) {
  console.log(`\n${failures} failure(s)`);
  process.exit(1);
}
