// PreToolUse hook: confine file mutations to the product worktree (/repo).
// The container also mounts /state (plans, item metadata, the audit log) and
// the Claude credentials dir writable — the implementation phase must never
// touch those, so anything outside /repo is denied (exit 2 blocks the call
// and feeds stderr back to Claude). Fails closed on unparseable input.
const path = require('path');

let raw = '';
process.stdin.on('data', chunk => raw += chunk);
process.stdin.on('end', () => {
  let filePath = null;
  try {
    const input = JSON.parse(raw).tool_input || {};
    filePath = input.file_path || input.notebook_path || null;
  } catch (e) {}

  if (!filePath) {
    process.stderr.write('guard-writes: no file path in tool input — blocked\n');
    process.exit(2);
  }

  const resolved = path.resolve(filePath);
  if (resolved === '/repo' || resolved.startsWith('/repo/')) process.exit(0);

  process.stderr.write(`guard-writes: writes are only allowed inside /repo (got ${filePath})\n`);
  process.exit(2);
});
