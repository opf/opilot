// pi extension, loaded via `--no-extensions -e /app/pi-guards.ts` — the single
// gate every tool call passes through: confine writes to /repos, confine bash
// to read-only git plus the two deleting subcommands a WRITE grant unlocks
// (WRITE_GIT — pi has no delete tool, so bash is the only place one can live).
// No type annotations — this file is loaded straight off
// disk, so an annotation pi's loader can't strip would kill the extension at
// startup, and a dead guard fails OPEN (an unguarded write/bash), not closed.
//
// KNOWN_TOOLS is an allowlist, not just a set of special cases: a tool name pi
// adds in a later release and that TOOLS_READ/TOOLS_IMPL (harness.rb) never
// grants should still be refused here rather than silently passed through.

const READONLY_GIT = new Set([
  "log", "show", "diff", "blame", "status", "rev-parse", "rev-list", "describe",
  "shortlog", "ls-files", "ls-tree", "cat-file", "grep", "whatchanged", "reflog",
  "annotate", "merge-base", "name-rev", "show-branch", "count-objects",
]);

// The two git subcommands that WRITE, allowed only when the run also holds the
// write tools (see writesGranted). pi ships no delete tool — its built-ins only
// create and modify, and its own answer to "remove this file" is `rm` through
// bash — so confining bash to read-only git left the model unable to delete
// anything at all (opf/openproject#24916). `rm` covers a stray already
// committed, `clean` one still untracked; Helpers#stage_all's `git add --all`
// records either.
//
// git rather than plain `rm` because git contains the blast radius itself, with
// no path validation to get wrong: a pathspec outside the work tree is refused,
// nothing under .git/ is tracked, and `rm` reaches only tracked files, which
// `git checkout` restores. `clean` is the looser of the two — a blanket
// `git clean -fd` discards the run's own uncommitted output, which costs a
// re-run and shows as a fix that produced nothing.
const WRITE_GIT = new Set(["rm", "clean"]);

// Tokens that can turn a read into a write or a code-exec, regardless of
// subcommand: output redirection to a file, pager/exec hijacks, alt git-dir.
const DANGEROUS_OPTION = /^(--output|-o$|--exec-path|--git-dir|--work-tree|-c$|--upload-pack|--receive-pack)/;

// op_query (pi-op-mcp.ts) is listed here too, but this file does nothing
// further to guard it — opgw.js's request-body allowlist is the real control
// on what it can reach. An unknown tool name still terminates the run.
const KNOWN_TOOLS = new Set(["read", "grep", "find", "ls", "bash", "write", "edit", "op_query"]);

function resolvePath(p) {
  // Node's path.resolve, inlined: extensions run in whatever module system pi
  // loads them under, and this avoids depending on `require`/`import` working
  // for a builtin the same way in that context.
  if (typeof p !== "string" || p === "") return null;
  const cwd = "/repos";
  const parts = (p.startsWith("/") ? p : cwd + "/" + p).split("/");
  const out = [];
  for (const part of parts) {
    if (part === "" || part === ".") continue;
    if (part === "..") out.pop();
    else out.push(part);
  }
  return "/" + out.join("/");
}

export function withinRepos(p) {
  const resolved = resolvePath(p);
  return resolved === "/repos" || (resolved !== null && resolved.startsWith("/repos/"));
}

// /repos/<name>/.git is inside /repos, so confining writes to /repos is not
// enough on its own: writing .git/config turns the read-only-git allowlist
// below into arbitrary code execution, because several allowlisted
// subcommands run operator-configured helper programs. Both are verified:
//
//   [diff] external = <cmd>   runs on `git diff`
//   [core] fsmonitor = <cmd>  runs on `git status`
//
// (core.pager does NOT fire — git skips the pager when stdout is not a TTY,
// and pi always pipes. It is not a vector here.)
//
// Worse than exec in this container: .git/hooks/pre-commit runs in the RUNNER,
// which holds GITHUB_CONTRIBUTOR_TOKEN and has full network egress. Anthropic's
// sandbox-runtime hard-denies exactly this set (.git/hooks/, .gitconfig) as
// paths no configuration can re-enable.
//
// The model never needs to write here — the runner does all real git.
//
// Exact segment equality, never startsWith(".git"): a prefix test would also
// block .gitignore, .gitattributes and .github/, which real fixes do edit, and
// that failure would look like an implement run that mysteriously cannot touch
// CI config. The check runs on the RESOLVED path, so ../ cannot walk into it.
export function touchesGitDir(p) {
  const resolved = resolvePath(p);
  return resolved !== null && resolved.split("/").includes(".git");
}

// Does this run hold the WRITE tools? Deletion rides on that grant rather than
// a flag of its own: TOOLS_IMPL carries write/edit, TOOLS_READ does not.
//
// This is the load-bearing half of allowing any write through bash. Plan and
// chat read work-package text and PR comments — untrusted, prompt-injectable —
// and their read-only contract is enforced HERE, not by the prompt claiming it.
//
// server.js starts pi with `--tools <grant>`. No --tools means pi enabled every
// tool, write included, so an absent flag reads as granted.
export function writesGranted(argv) {
  const args = argv || [];
  const i = args.indexOf("--tools");
  if (i === -1) return true;
  const granted = String(args[i + 1] || "").split(",").map((s) => s.trim());
  return granted.includes("write") || granted.includes("edit");
}

// Flags refused on `git clean`, checked letter by letter so a cluster like -fdx
// is caught as surely as a lone -x. x/X also remove IGNORED files — the pd spec
// tree and every build artifact, not this run's scratch. -ff recurses into
// nested git repositories. -f, -d and a pathspec stay allowed.
export function checkClean(tokens) {
  let force = 0;
  for (const t of tokens) {
    if (t === "--force") { force++; continue; }
    if (t.startsWith("--")) continue;
    if (!t.startsWith("-")) continue;
    for (const ch of t.slice(1)) {
      if (ch === "x" || ch === "X") return `git clean ${t} would also remove ignored files`;
      if (ch === "f") force++;
    }
  }
  if (force > 1) return "git clean -ff descends into nested git repositories";
  return null;
}

// Returns a denial reason string, or null to allow. `canWrite` comes from
// writesGranted(process.argv) at the call site; it defaults to false so a
// caller that forgets it gets the read-only allowlist, not the wider one.
export function checkBash(command, canWrite = false) {
  if (typeof command !== "string" || command.trim() === "") {
    return "no command in tool input";
  }
  // No shell chaining/redirection/substitution — keep it a single git invocation.
  if (/[;&|<>`\n]|\$\(/.test(command)) {
    return `shell metacharacters are not allowed (got: ${command})`;
  }

  const tokens = command.trim().split(/\s+/);
  if (tokens.shift() !== "git") return `only git is allowed (got: ${command})`;

  // Walk leading options. Allow `-C <path>` and `--no-pager`; the first
  // non-option token is the subcommand.
  let sub = null;
  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    if (DANGEROUS_OPTION.test(t)) return `disallowed option: ${t}`;
    if (t === "-C") { i++; continue; }
    if (t === "--no-pager") continue;
    if (t.startsWith("-")) continue;
    sub = t;
    break;
  }
  if (!sub || !(READONLY_GIT.has(sub) || WRITE_GIT.has(sub))) {
    return `only read-only git is allowed (subcommand: ${sub})`;
  }
  if (WRITE_GIT.has(sub)) {
    // Its own message, so the model is told which of the two it hit.
    if (!canWrite) return `git ${sub} needs the write tools, which this phase does not have`;
    if (sub === "clean") {
      const reason = checkClean(tokens);
      if (reason) return reason;
    }
  }

  // Re-scan every token for dangerous options anywhere in the command.
  for (const t of tokens) {
    if (DANGEROUS_OPTION.test(t)) return `disallowed option: ${t}`;
  }
  return null;
}

export default function (pi) {
  pi.on("tool_call", (event) => {
    const toolName = event.toolName;
    const input = event.input || {};

    if (!KNOWN_TOOLS.has(toolName)) {
      return { block: true, terminate: true, reason: `pi-guards: unknown tool "${toolName}" is not allowed` };
    }

    if (toolName === "write" || toolName === "edit") {
      if (!withinRepos(input.path)) {
        return { block: true, reason: `pi-guards: writes are only allowed inside /repos (got ${input.path})` };
      }
      if (touchesGitDir(input.path)) {
        return { block: true, reason: `pi-guards: writes into a .git directory are not allowed (got ${input.path})` };
      }
      return undefined;
    }

    if (toolName === "bash") {
      const reason = checkBash(input.command, writesGranted(process.argv));
      if (reason) return { block: true, reason: `pi-guards: ${reason}` };
      return undefined;
    }

    // read, grep, find, ls — read-only by construction, nothing to guard.
    return undefined;
  });
}
