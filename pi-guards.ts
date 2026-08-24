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
// write tools (see writesGranted). They exist because pi ships no delete tool:
// its seven built-ins are bash, edit, find, grep, ls, read and write, and its
// own answer to "remove this file" is `rm` through bash. Confining bash to
// read-only git took that answer away and left nothing in its place, so the
// model could create and modify files but never remove one. A reviewer asking
// opilot to drop a stray file off a PR got a promise it could not keep
// (opf/openproject#24916).
//
// Together they cover both states a stray file can be in: `rm` for one already
// committed to the branch, `clean` for one still sitting untracked in the
// clone — which is how a stray reaches a commit at all, since Helpers#stage_all
// runs `git add --all`. That same `add --all` is why neither call needs the
// runner's cooperation to be recorded: it stages deletions with everything else.
//
// git rather than a plain `rm` because git contains the blast radius itself,
// with no path validation for this file to get wrong:
//
//   - a pathspec outside the work tree is refused, so /repos confinement is
//     free (and --work-tree/--git-dir are DANGEROUS_OPTIONs already);
//   - nothing under .git/ is tracked and `clean` never descends into it, so
//     the .git/config and .git/hooks exec vectors documented below stay out
//     of reach;
//   - `rm` removes only TRACKED files — by definition restorable with
//     `git checkout`, i.e. replaceable data in a disposable clone.
//
// `clean` is the looser of the two: an untracked file is in no object database,
// so a blanket `git clean -fd` discards the run's own uncommitted output. That
// costs a re-run and shows up as a fix that produced nothing — bounded, and
// visible when it happens. CLEAN_REFUSED below keeps it from reaching anything
// that is NOT the run's own scratch.
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
// on a flag of its own: TOOLS_IMPL carries write/edit, TOOLS_READ does not, so
// the plan and chat phases stay read-only with nothing extra to keep in sync.
//
// This is the load-bearing half of allowing a write through bash at all. Those
// read-only phases read work-package text and PR comments — untrusted,
// prompt-injectable input — and their read-only contract is enforced HERE, not
// by the prompt that claims it. A bash that could delete in every grant would
// hand an injected instruction a way to empty a clone from a phase whose whole
// promise is that it changes nothing.
//
// server.js starts pi with `--tools <grant>`. No --tools at all means pi
// enabled every tool, write included, so an absent flag reads as granted.
export function writesGranted(argv) {
  const args = argv || [];
  const i = args.indexOf("--tools");
  if (i === -1) return true;
  const granted = String(args[i + 1] || "").split(",").map((s) => s.trim());
  return granted.includes("write") || granted.includes("edit");
}

// Flags refused on `git clean`, checked letter by letter so a combined cluster
// like -fdx is caught as surely as a lone -x:
//
//   x / X      also remove IGNORED files. Those are not the run's scratch:
//              they are the pd spec tree (PD::ChangeState keeps it in the
//              clone git-excluded and force-added) and every build artifact.
//   -ff        recurses into nested git repositories.
//
// Everything else about clean is deliberately left alone — -f, -d and a
// pathspec are the useful, bounded form.
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
    // Named separately from the line above so the model is told which of the
    // two it hit: "rm is not allowed here" and "no git subcommand like this is
    // allowed" call for different next moves.
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
