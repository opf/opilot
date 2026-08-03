// PreToolUse hook: confine file mutations to the product worktrees (/repos).
// The container also mounts /state (plans, item metadata, the audit log) and the
// Claude credentials dir; /state is read-only at the mount, and this hook is the
// belt to that brace — anything outside /repos is denied (exit 2 blocks the call
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
  if (resolved === '/repos' || resolved.startsWith('/repos/')) process.exit(0);

  process.stderr.write(`guard-writes: writes are only allowed inside /repos (got ${filePath})\n`);
  process.exit(2);
});
