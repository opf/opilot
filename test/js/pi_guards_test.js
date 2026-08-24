// Plain-Node test for pi-guards.ts — the single gate every pi tool call passes
// through. No test framework (the repo has none for JS): run with
// `node test/js/pi_guards_test.js`.
//
// pi-guards.ts carries no type annotations on purpose, so Node imports the .ts
// file directly (verified on node 22 in the harness image and on the host).
//
// The guard fails OPEN if it ever stops loading — an unguarded write or bash,
// not a blocked one — so "the extension still registers a hook" is itself
// worth asserting, not just the predicates.
const assert = require('assert');

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

// Drives the real extension: registers the hook the way pi does, then feeds it
// tool calls. Testing through this rather than the predicates alone is what
// catches a guard that is correct but never wired up.
function loadGuard(mod) {
  let hook = null;
  mod.default({ on(event, fn) { if (event === 'tool_call') hook = fn; } });
  assert.ok(hook, 'the extension must register a tool_call hook');
  return (toolName, input) => hook({ toolName, input }) || { block: false };
}

import('../../pi-guards.ts').then(mod => {
  const { withinRepos, touchesGitDir, checkBash, checkClean, writesGranted } = mod;
  const call = loadGuard(mod);

  const IMPL = ['pi', '--tools', 'read,grep,find,ls,bash,write,edit'];
  const READ = ['pi', '--tools', 'read,grep,find,ls,bash'];

  // ── the .git denial ─────────────────────────────────────────────────────

  test('writing .git/config is refused — it is arbitrary code execution', () => {
    // [diff] external and [core] fsmonitor both run operator-configured
    // programs on `git diff` / `git status`, which the bash allowlist permits.
    assert.strictEqual(call('write', { path: '/repos/openproject/.git/config' }).block, true);
    assert.strictEqual(call('edit', { path: '/repos/openproject/.git/config' }).block, true);
  });

  test('writing a git hook is refused — that one executes in the RUNNER', () => {
    // The runner holds GITHUB_CONTRIBUTOR_TOKEN and has full egress, so this
    // is the more severe of the two paths.
    assert.strictEqual(call('write', { path: '/repos/openproject/.git/hooks/pre-commit' }).block, true);
  });

  test('traversal cannot walk into .git', () => {
    // The check runs on the resolved path, so ../ is normalised away first.
    assert.strictEqual(call('write', { path: '/repos/x/foo/../.git/config' }).block, true);
    assert.strictEqual(call('write', { path: '/repos/x/../x/.git/hooks/post-commit' }).block, true);
    assert.strictEqual(touchesGitDir('/repos/a/b/../../.git/config'), true);
  });

  test('a relative path resolves against /repos and is still caught', () => {
    assert.strictEqual(call('write', { path: 'openproject/.git/config' }).block, true);
  });

  // ── what must STILL be writable ─────────────────────────────────────────

  test('.gitignore, .gitattributes and .github survive — exact segment match, not a prefix', () => {
    // A startsWith(".git") test would block all three. Real fixes edit them,
    // and the failure would look like an implement run that mysteriously
    // cannot touch CI config.
    for (const p of [
      '/repos/openproject/.gitignore',
      '/repos/openproject/.gitattributes',
      '/repos/openproject/.github/workflows/ci.yml',
      '/repos/openproject/.github/CODEOWNERS',
    ]) {
      assert.strictEqual(call('write', { path: p }).block, false, `${p} must stay writable`);
    }
  });

  test('ordinary source files are unaffected', () => {
    assert.strictEqual(call('write', { path: '/repos/openproject/app/models/user.rb' }).block, false);
    assert.strictEqual(call('edit', { path: '/repos/other/lib/thing.rb' }).block, false);
  });

  // ── the pre-existing confinement still holds ────────────────────────────

  test('writes outside /repos are still refused', () => {
    assert.strictEqual(call('write', { path: '/state/work_packages/x/item.json' }).block, true);
    assert.strictEqual(call('write', { path: '/repos/../etc/passwd' }).block, true);
    assert.strictEqual(withinRepos('/repos/x'), true);
    assert.strictEqual(withinRepos('/etc/passwd'), false);
  });

  test('bash is still confined to read-only git', () => {
    assert.strictEqual(checkBash('git log --oneline'), null);
    assert.strictEqual(checkBash('git -C /repos/openproject status'), null);
    assert.ok(checkBash('git commit -m x'), 'commit must be refused');
    assert.ok(checkBash('git push'), 'push must be refused');
    assert.ok(checkBash('rm -rf /'), 'non-git must be refused');
    assert.ok(checkBash('git log; rm -rf /'), 'chaining must be refused');
    assert.ok(checkBash('git -c core.pager=sh log'), '-c must be refused');
  });

  // ── deleting a file: the WRITE_GIT pair ─────────────────────────────────

  test('git rm and git clean are allowed with the write grant', () => {
    assert.strictEqual(checkBash('git rm app/models/stray.rb', true), null);
    assert.strictEqual(checkBash('git -C /repos/openproject rm app/models/stray.rb', true), null);
    assert.strictEqual(checkBash('git clean -fd app/models', true), null);
    assert.strictEqual(checkBash('git clean -f -- app/models/stray.rb', true), null);
  });

  // Plan and chat read untrusted work-package text. Their read-only contract is
  // enforced here, not by the prompt claiming it.
  test('git rm and git clean are refused WITHOUT the write grant', () => {
    for (const cmd of ['git rm app/models/user.rb', 'git clean -fd']) {
      assert.ok(checkBash(cmd, false), `${cmd} must be refused read-only`);
    }
  });

  test('checkBash defaults to the read-only allowlist', () => {
    assert.ok(checkBash('git rm app/models/user.rb'), 'a caller that forgets canWrite gets the narrower rule');
  });

  test('the grant is read off pi\'s own --tools argument', () => {
    assert.strictEqual(writesGranted(IMPL), true);
    assert.strictEqual(writesGranted(READ), false);
    assert.strictEqual(writesGranted(['pi', '--tools', 'read,grep,find,ls,bash,op_query']), false);
    assert.strictEqual(writesGranted(['pi', '--tools', 'read,grep,find,ls,bash,write,edit,op_query']), true);
    // No --tools at all means pi enabled everything, write included.
    assert.strictEqual(writesGranted(['pi', '--mode', 'json']), true);
  });

  // PD::ChangeState keeps the spec tree in the clone git-excluded, so -x/-X
  // would discard real state, not this run's scratch.
  test('git clean cannot reach IGNORED files — that is the pd spec tree', () => {
    assert.ok(checkClean(['-x']), '-x must be refused');
    assert.ok(checkClean(['-X']), '-X must be refused');
    assert.ok(checkClean(['-fdx']), 'a combined cluster must be refused');
    assert.ok(checkBash('git clean -fdx', true), 'and through checkBash');
    assert.strictEqual(checkClean(['-fd']), null, '-fd stays allowed');
  });

  test('git clean cannot descend into nested git repositories', () => {
    assert.ok(checkClean(['-ff']), '-ff must be refused');
    assert.ok(checkClean(['-f', '-f']), 'two separate -f must be refused');
    assert.ok(checkClean(['--force', '--force']), 'two --force must be refused');
    assert.strictEqual(checkClean(['--force', '-d']), null, 'one --force stays allowed');
  });

  // WRITE_GIT is two names, not a mode.
  test('the write grant does not widen anything else', () => {
    for (const cmd of ['git commit -m x', 'git push', 'git reset --hard', 'rm -rf /repos']) {
      assert.ok(checkBash(cmd, true), `${cmd} must stay refused`);
    }
  });

  test('an unknown tool is refused and terminates the run', () => {
    const r = call('webfetch', { url: 'http://evil' });
    assert.strictEqual(r.block, true);
    assert.strictEqual(r.terminate, true);
  });

  console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
  process.exit(failures === 0 ? 0 : 1);
});
