// PreToolUse hook: confine Bash to READ-ONLY git, so Claude can browse history
// for context but can never mutate a repo, reach a remote, or run an arbitrary
// command. Anything else exits 2 (blocks the call, feeds stderr back to Claude).
// Fails closed on unparseable input. The egress proxy already blocks all
// non-Anthropic traffic, so this is defence in depth against a prompt injection.

// Subcommands that only read. Deliberately excludes ref-mutating ones
// (branch/tag/checkout/reset/commit/...) and anything that touches a remote
// (fetch/pull/push/remote/clone) or config (config/-c).
const READONLY = new Set([
  'log', 'show', 'diff', 'blame', 'status', 'rev-parse', 'rev-list', 'describe',
  'shortlog', 'ls-files', 'ls-tree', 'cat-file', 'grep', 'whatchanged', 'reflog',
  'annotate', 'merge-base', 'name-rev', 'show-branch', 'count-objects',
]);

// Tokens that can turn a read into a write or a code-exec, regardless of
// subcommand: output redirection to a file, pager/exec hijacks, alt git-dir.
const DANGEROUS = /^(--output|-o$|--exec-path|--git-dir|--work-tree|-c$|--upload-pack|--receive-pack)/;

function deny(msg) {
  process.stderr.write(`guard-bash: ${msg}\n`);
  process.exit(2);
}

let raw = '';
process.stdin.on('data', c => raw += c);
process.stdin.on('end', () => {
  let command = null;
  try { command = (JSON.parse(raw).tool_input || {}).command; } catch (e) {}
  if (typeof command !== 'string' || command.trim() === '') {
    deny('no command in tool input — blocked');
  }

  // No shell chaining/redirection/substitution — keep it a single git invocation.
  if (/[;&|<>`\n]|\$\(/.test(command)) {
    deny(`shell metacharacters are not allowed (got: ${command})`);
  }

  const tokens = command.trim().split(/\s+/);
  if (tokens.shift() !== 'git') deny(`only git is allowed (got: ${command})`);

  // Walk leading options. Allow `-C <path>` and `--no-pager`; the first
  // non-option token is the subcommand.
  let sub = null;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (DANGEROUS.test(t)) deny(`disallowed option: ${t}`);
    if (t === '-C') { i++; continue; }        // skip its path argument
    if (t === '--no-pager') continue;
    if (t.startsWith('-')) continue;          // other flags are inspected below
    sub = t;
    break;
  }

  if (!sub || !READONLY.has(sub)) deny(`only read-only git is allowed (subcommand: ${sub})`);

  // Re-scan every token for dangerous options anywhere in the command.
  for (const t of tokens) {
    if (DANGEROUS.test(t)) deny(`disallowed option: ${t}`);
  }

  process.exit(0); // allow
});
