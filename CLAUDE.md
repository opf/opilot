# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What This Project Is

`openproject-opilot` is an AI agent that plans fixes for OpenProject work
packages, implements them in isolated git clones, and opens draft PRs.

A fix can land in **one or more product repos**, defined in `repos.json` (`name`,
`upstream`, `base`, optional `shared_repo_path`, `description`, plus a top-level
`summary`). the LLM sees the registry while planning and declares the targets on the
plan's first line — `REPOS: <name>[@<base>][, <name>…]` — which
`Helpers#record_chosen_repos` stores in `target_repos.json`, with any `@<base>`
override (e.g. `openproject@release/17.6`) in `target_base.json`. The fix branch is
both cut from and PR'd against that base (`ItemState#base_for`).

Each repo is a standalone clone at `.opilot/repos/<name>`, mounted into the harness
container at `/repos/<name>`; the runner ships an independent branch + PR to each
repo that actually changed (`OPilot::Registry`/`OPilot::Repo`). `OP_REPO_PATH`
seeds *only* the openproject clone from a local checkout (a wrong path falls back to
a fresh clone).

## Modes

Agent loops: `./opilot agent` (both), `agent op`, `agent gh` — the older
`op-agent`/`gh-agent` names still work and are used below.

### op-agent

Polls work packages, driven by `@opilot` comments. There are two command words —
**`@opilot build`** (alias `fix`) and **`@opilot create wp`** (long form
`create work package`); every other word is chat. The words `build` replaced —
`ship`, `plan`, `approve`, `prototype`, `pr`, `implement` — are chat too, so an old
habit gets an answer that names the real command rather than silence. `create`
without the noun is chat as well: alone it could mean a branch, a PR or a comment,
and the noun is what makes it one operation.

**Discovery is server-side comment search, not project scanning.** Each tick,
`Pull#poll_intents` asks OpenProject's own `comment` filter (`~`, "contains") for
work packages whose comments mention opilot — keyed on the bot's own OpenProject
display name, fetched dynamically from `/users/me` (`Pull#mention_filter_json`),
never hardcoded. There is no project scope in this query at all: the API token's
own project access is the trust boundary instead, so op-agent needs no
project-picker setup. This is a **hard dependency** — a failed identity lookup
(`Pull#ensure_bot_identity!`) raises before the loop starts (`Agent#setup`, so it
fails loudly once rather than being silently retried forever by `guarded_tick`)
and again at the top of every `poll_intents` call.

OpenProject's `contains` filter takes only one value and ANDs its
whitespace-split tokens — there is no way to OR in a second literal term in the
same query — so the search is deliberately the bot's one real display name
rather than also trying to match literal `"@opilot"`/`"@chomper"` text. The
accepted narrowing: plain text typed without using the mention picker (so it
never contains the bot's actual display name) is no longer a recognized
trigger — the mention picker is the real-world path.

**Once a prototype exists, the work package is done.** `#handle_ship` answers a
shipped WP with the PR link and spends no LLM call: code review belongs on the
pull request, where gh-agent reads comments and pushes changes, and two tracks for
one fix would split the record of it. Planning again would also rewrite `plan.md`
while the PR keeps linking the gist of the plan as it was.

**A plan on file with no new direction is built, not rewritten.** That is what the
retired `approve` did, and the only way to get a prototype of the exact plan a human
has read.

**`ship` always names the approach before it writes code.** The writer opens
every invited plan call with a third first-line sentinel beside `NEEDS_INFO`
and `REPOS:` — `OPTIONS`, then one pipe-delimited line per approach
(`Prompts::OPTIONS_CONTRACT`). Most tickets have exactly one sensible approach:
the writer names it in a single option line, then continues straight into the
plan in the *same* response, so a one-shape ticket still costs exactly one
plan call — just with a stated approach instead of a silent one.
`Agent#produce_plan` reads that as a single named approach, saves the plan
(header stripped), posts "This is a straightforward problem, so I will now
implement the following approach: `<title>` — `<summary>`", and ships
immediately — no reply required. A fix with more than one defensible shape is
answered instead with 2–3 numbered options, one sentence each, and nothing
else happens until someone replies `@opilot build <n>`; the writer stops right
after naming them, so no plan is attached to wait on. `#post_options` composes
that comment in Ruby (the writer supplies only title and sentence, so the
wording, numbering and reply instructions cannot drift). The sentinel is
honoured even when options were *not* invited, so an uninvited block is never
shipped as a plan; an unusable answer (no plan attached, and not a real
multi-option list either) buys one retry for a plan, then `:failed`. Naming an
approach is skipped only when something has already settled it: a saved plan,
a chosen option, or free-text direction.
A **leading** number selects, and words after it ride along as direction
(`Helpers.option_choice`/`#option_focus_text`, shared with the terminal), so
"2 but keep the toast" neither loses the option nor loses the sentence. The repo/size
line is labelled an **estimate**, because the plan's own `REPOS` line decides where
the fix lands; the chosen option's repos are passed into the plan call as the expected
targets so the two rarely disagree.

Selecting is allowlist-gated like any comment trigger, which the offer says out
loud when `OPILOT_ALLOWED_OP_USER_IDS` is set. A rejected trigger is no longer
silent: `Pull#note_refused_trigger` answers the commenter **once per WP**
(`refusal_noted_at`), because opilot offers options to anyone who can comment while
only allowlisted users may choose one, and because a reply is the one thing an
unlisted user can make opilot do — a per-comment answer would let anyone fill the
activity tab.

Planning or chatting also pulls in the WP's **related** WPs (relations plus
parent/children), each cached as its own `item.json` with a `related.json` index the
prompts reference. `dev build`/`commit`/`plan` share this.

### gh-agent

Polls two sources each tick. Both watch the thread and inline review comments, are
gated by the GitHub-login allowlist, and never merge. Shared caching and
mention-matching live in `GhPrCache`.

**OPilot's own PRs** (`GhPull`, those with a `repos/<name>/pr_url.txt`) — always
reply, code if asked, pushing to the fork. There are two command words
(`GhPull#parse_command`), and both are acted on **only here** — `!reply_only` — so
an upstream PR's "refresh"/"close" is read as prose and answered in text.

**`@opilot refresh`** is the full `dev refresh` treatment
(`PrRunner#refresh_one`) with the base merge forced and the CI fix run regardless of
act-state or cap. Built `interactive: false`, so fork pushes go straight through
while a canonical-repo target is refused and the refresh discarded.

**`@opilot close`** closes the PR unmerged (`GhAgent#handle_close`) — the one way to
retire a prototype nobody wants without a maintainer opening GitHub. It needs no
access to the canonical repo: GitHub lets a PR's own author close it, and opilot
opened this one. Closing is not merging, so nothing lands and the "never merge"
rule is untouched. It spends no LLM call, pushes nothing, and writes no state —
the next poll reads the PR as `closed` and sets `pr_done` itself
(`#intents_for_dir`), the same path a human closing it takes, which keeps the flag
in one place so `dev refresh` can still clear it on a reopen. The close runs **before**
the reply, so the reply only states something that already happened; a close that
raises is reported by `#handle_and_ack`'s rescue instead. `close` is matched before
`refresh`, so "close it and refresh" closes — one comment has one outcome, and
refreshing a PR about to close spends a call and a push on a branch nobody reads.
The command is allowlist-gated like every other trigger, and the WP stays shipped:
a closed prototype does not re-open its work package for planning.

`close` is also the **one command word a `pd` spec PR recognises**
(`GhPull#command_for`), and `GhAgent#handle` checks it *ahead of* the spec branch: a
proposal PR is opilot's own too, so retiring it is the same need — and without the
reorder, "close this" would spend a `revise_proposal` call and push a spec edit.
`refresh` stays off spec PRs, since `PrRunner` is keyed by work package and a change
id names no WP dir.

It also **auto-fixes failed CI** (always on). Once checks complete with ≥1 failure,
the detail (annotations, output summaries, failed-job log tails) is cached to
`ci.json`, fixed with `Prompts.fix_ci`, committed and pushed. The trigger is the
**head SHA**: `gh_pr.json` tracks `ci_acted_sha` (once per commit) and `ci_attempts`
(`OPILOT_CI_MAX_ATTEMPTS`, default 5; past the cap it posts a one-time "needs a
human" note and sets `ci_gave_up`). It acts on the *first* failure rather than
waiting out slow jobs, never acts in the same tick as a comment trigger, ignores
`OPILOT_CI_IGNORE_CHECKS`, and needs no allowlist. A green verdict is cached
(`ci_quiet_sha`) only once the commit has **settled** (`CI_SETTLE_SECONDS`) — checks
register over time, so a just-pushed commit can look green before its failing jobs
appear. Check-run reads are fully paginated (`auto_paginate` is off by default,
which would truncate a big CI matrix).

**Tracked upstream PRs** (`UpstreamGhPull`) — open PRs on a registry `upstream` that
@-mention opilot, except the bot's own (`own_pr?`). Found via the search API so a
an LLM call is spent only on real mentions. The trigger is a prompt addressed to
opilot, not a review pass over other people's work; what differs is write access,
so these intents are `reply_only` — read-only fetch, answered in text
(`Prompts.pr_review`), never pushed. Applicable code still lands: for lines already
in the diff the review emits a `SUGGESTIONS:` block
(`Prompts::SUGGESTION_CONTRACT`) that `GhAgent#post_suggestions` posts as a review
of inline `suggestion` comments (anchored to the head SHA, `event: COMMENT`) — the author
applies each with one click; a bad line range 422s and falls back to prose. A
failing CI run is read too (keyed by head SHA), so "why is CI red?" gets an
explained answer. State lives in `pr_reviews/<owner>-<repo>/<number>/` (the name
predates this framing; renaming it orphans every tracked PR's act-state).

**Off unless `OPILOT_TRACK_UPSTREAM_PRS` is set, and it also needs
`OPILOT_ALLOWED_GH_USERS`** — the only source reaching outside opilot's own PRs.
The startup banner names which of the three states the run is in, since "scanned
nothing" and "not scanning" look identical in the log.

### Terminal modes (`dev`)

- **`dev build <id>...`** (alias `dev fix`) — fetch by id (ignoring filters), run a
  plan/approve loop (`[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`) per id, ship each
  approved plan as a draft PR. One failure doesn't abort the rest. A fix with more than
  one shape is offered as the same numbered options first
  (`#prompt_option_choice`) — a number picks one, free text is direction of the
  operator's own — so a ticket behaves the same at the console as in the thread. A
  one-shape fix names its approach the same way, but the operator already sees it
  streamed live and still has to say `[y]es` before anything is built — there is
  no auto-ship at the console.
- **`dev commit <id>...`** — stop after the local commit. A later `ship` finds the
  branch (`branch_has_commits?`) and goes straight to publish.
- **`dev plan <id>...`** — stop at the approved plan.
- **`dev refresh <id|pr-url>...`** — refresh shipped PRs (`PrRunner`). A URL is matched
  against local state, else *adopted* via the OpenProject ticket link in the
  description's top 15 lines; a WP id with no state is *discovered* by searching each
  upstream for open bot-authored PRs mentioning the id, adopted only after verifying
  author = bot login and the ticket link (the author check is the trust boundary —
  `pr` pushes to the PR's head branch). Per PR: sync to the head; merge the base
  **only when the branch has had no commits for over a day** (judged on the head
  commit's date, so a fresh comment doesn't block a merge and a just-pushed branch
  doesn't churn merge commits); fix failing CI regardless of act-state or cap (a
  failure past GitHub's ~1-month log retention has no detail left, so it falls back
  to base-merge + push); address comments newer than opilot's last action (no
  mention or allowlist gate — the point is sweeping feedback that never pinged
  opilot). Pushed to the fork after a `[y]es push / [d]iscard` prompt. The summary
  is posted as a 🤖 comment and the cutoff advances so gh-agent doesn't re-handle it.
- **`chat [message]`** — free read-only conversation over the local mirrors, never
  fetching, planning, or shipping. `.opilot/` is mounted read-only at `/state`, so
  `Prompts.free_chat` orients the LLM at the layout and it Greps/Reads from there.
  Fresh per-run session; needs no tokens or allowlist. **It reads only what another
  run already mirrored** — a `dev` verb or an agent tick. Nothing seeds the cache on
  its own: `op wp get` prints a work package but caches nothing, so a WP opilot has
  never worked on is not visible to `chat`.

### pd (product development)

`./opilot pd <subcommand>` is a spec-driven pipeline, separate from the bug-fix
modes: OpenProject Documents → an [OpenSpec](https://github.com/Fission-AI/OpenSpec)
change proposal reviewed as a PR → generated work packages → one implementation run
per WP → archive. It has its own namespace because the bug-fix verbs also take a
work-package id while meaning something else entirely. Like every mode it publishes
as the contributor bot. Implemented: M0–M3.

The stages (`init`, `intake`, `propose`, `generate-wp`, `implement`), the
three-copy spec store, attachment conversion, and the `openspec` CLI wrapper are
documented in **[`lib/opilot/pd/CLAUDE.md`](lib/opilot/pd/CLAUDE.md)** — read that
before touching anything under `lib/opilot/pd/`.

## Commands

```bash
# Run both agent loops (polls every 20s) — the normal way to run opilot.
# `agent op` / `agent gh` run one; the old op-agent / gh-agent names still work.
./opilot agent

# Plan and ship work packages by id (terminal approval; `dev fix` is an alias)
./opilot dev build <id>...
./opilot dev commit <id>...   # stop after the local commit — no push, no PR
./opilot dev plan <id>...    # stop at the approved plan

# Refresh shipped PRs: merge base, fix CI, address new comments, push (confirmed)
./opilot dev refresh <id|pr-url>...

# Free read-only chat about the local mirrors
./opilot chat [message]

# Read the OpenProject API directly — one command per client method, JSON on
# stdout. `./opilot op --help` lists all 13.
./opilot op wp get <id>
./opilot op wp list --filter 'subject~login'
./opilot op wp create --project <id> --type <name> --subject <text> [--dry-run]   # the one write
./opilot op wp form --project <id> --type <name> --required   # what it demands; creates nothing
./opilot op cf items <id>            # a hierarchy custom field's allowed values

# Product development (spec-driven)
./opilot pd init <project-id> [--repo <name>]
./opilot pd intake <project-id> <change-id> [--doc-id <id>]...
./opilot pd propose <change-id>
./opilot pd generate-wp <change-id>
./opilot pd implement <wp-id>...

./opilot dev status   # list planned/shipped work packages
./opilot usage     # OpenRouter spend: account balance, this key, model pricing
./opilot reset     # delete .opilot/ (clones included)

# Tests
docker compose run --no-deps --rm runner bundle exec rake
docker compose run --no-deps --rm runner bundle exec ruby -Itest test/opilot/agent_test.rb

# Rebuild runner image (required after editing Gemfile)
docker compose run --no-deps --rm runner bundle lock
docker compose build runner
```

## Architecture

Four Docker containers orchestrated by `compose.yml` (three plus `opgw`, which
starts only when `OPILOT_OP_MCP` is set):

- **Runner** (Ruby 4.0) — the agent. Polls OpenProject, dispatches intents, calls
  the LLM, pushes branches, opens PRs. Does all real git.
- **Harness** (Node 22 + [pi], compose service `harness`, `Dockerfile.harness`) —
  wraps `pi --mode json` via `server.js` on port 47291 (internal network only,
  never published), which translates pi's JSON event stream into the frame
  shapes `lib/opilot/harness.rb` (`OPilot::Harness`) parses. Any model is one
  `OPILOT_MODEL_HEAVY` away. Working directory is
  `/repos` with every worktree at
  `/repos/<name>`; `--no-context-files` stops pi auto-loading a repo's
  CLAUDE.md/AGENTS.md, so the plan/implement prompts tell it to read each
  target repo's directly instead. Its Bash grant is **read-only git** —
  history for context, but no commit, push, or non-git command. Two
  extensions load via `--no-extensions -e` (repeatable): `pi-guards.ts` (pi's
  only PreToolUse-style hook) enforces that plus the write confinement: no
  writes outside `/repos`, and **none into any `.git/` directory** — that one
  is not cosmetic, since `.git/config`'s `diff.external` and
  `core.fsmonitor` run programs on allowlisted read-only subcommands, and
  `.git/hooks/pre-commit` would execute in the *runner*, which holds the
  GitHub token. Writes are checked on the resolved path by exact segment
  match, so `.gitignore`/`.github/` stay editable. `pi-op-mcp.ts` registers
  the `op_query` tool (see the Opgw entry below); it is always loaded, but
  registers nothing when `OPILOT_OPGW_URL` is unset.

  pi always talks to authgw at `http://authgw:47292/v1`, resolving its
  `apiKey` to `OPILOT_GW_TOKEN` (a fixed handshake value, not a secret) — the
  real key never reaches this container. `server.js` decides which provider
  config pi gets from **the provider prefix on `OPILOT_MODEL_HEAVY`**:
  `openrouter/…` copies `pi-models.json` from git, anything else generates one
  (`buildModelsJson`). That prefix is the only signal, deliberately — a second
  "mode" variable could disagree with the slug.
- **Authgw** (Node 20, `authgw.js`) — the harness's **only** route to a model,
  and **containment is its load-bearing job, not authentication**. The name
  predates that. It does four things, and holding the key is the only optional
  one: a **fixed upstream** (`OPILOT_INFERENCE_URL`, default
  `https://openrouter.ai/api/v1`), an **address pinned at boot** and re-used
  per request (closing DNS rebinding; re-resolved only after a connection
  fails), a **path allowlist** (`chat/completions`, `messages`, `responses`,
  `models…`, `credits`, `key` — everything else 403s, notably Ollama's
  `/api/pull`, which takes an arbitrary registry host), and the key swap.

  It validates the fixed gateway token, then **deletes** the incoming
  `Authorization` before setting whatever `OPILOT_INFERENCE_AUTH` names
  (default `Authorization: Bearer {key}`, `api-key: {key}` for Azure OpenAI).
  The delete is unconditional and load-bearing: a set-without-delete on a
  differently-named header would ship the gateway token to a third party.

  Every client speaks a uniform `/v1`; authgw re-applies the upstream's own
  path prefix, so `/v1/chat/completions` reaches `/api/v1/chat/completions` on
  OpenRouter. That is why `./opilot usage` (`Clients::OpenRouter`) asks for
  `/v1/credits` and `/v1/key`. It converts **headers, never protocols** — the
  wire format is pi's `api` field (`OPILOT_MODEL_API`), not authgw's concern.
  A keyless self-hosted endpoint still goes through it; "no secret to hide" is
  not a reason to bypass containment.
- **Opgw** (Node 20, `opgw.js`) — the harness's only route to the OpenProject
  MCP server (see `MCP.md`), on whenever the harness is (`OPILOT_OP_MCP`
  defaults **on**; set it to `0`/`false`/`no`/`off` to disable). Same
  containment shape as authgw — a fixed upstream (`OPENPROJECT_URL`), an
  address pinned at boot, and a swap of the handshake token for
  `OPENPROJECT_TOKEN` (basic auth, `apikey:<token>`) — but the allowlist is on
  the **JSON-RPC request body**, not the path: every call is the same `POST
  /mcp`, so opgw parses it and allows only `initialize`/`tools/list`, and for
  `tools/call` only eight read-only operation names. The instance's own
  `tools/list` answer is also trimmed to those eight before it reaches pi, so
  the model is never shown a tool it cannot call. A second route, `GET
  /tools`, answers the runner with the **unfiltered** list — used once at
  startup (`Helpers#report_op_mcp_status`) to log which write tools the
  instance still has enabled; opilot cannot disable those, only an
  administrator can. `OPENPROJECT_TOKEN` can write — six of the instance's MCP
  tools do — so this allowlist is the actual control, not a refinement one.
  The pi extension side (`pi-op-mcp.ts`/`op-mcp-client.js`, loaded via a
  second `-e`) trims a `search_work_packages` answer to a fixed subset of
  fields (full records run ~8 KB each) and registers nothing at all when
  `OPILOT_OPGW_URL` is empty — the harness-side half of the same feature flag.
  A 404 ("MCP server is not available") is a normal per-instance state, not an
  error: the MCP server is an Enterprise add-on an administrator must enable.
**There is no egress proxy.** A tinyproxy sidecar used to sit beside authgw,
allowlisting a couple of documentation hosts for Claude Code's WebFetch. pi
ships no fetch tool — its built-ins are `bash, edit, find, grep, ls, read,
write`, and Bash is confined to read-only git — so nothing could use it, and
its logs showed zero requests across every recorded run. It was also the only
service straddling `internal` and `egress`, which made it a bridge *out* of the
contained network rather than a restriction on one. Removing it made the
harness's egress strictly zero-except-authgw (plus opgw, per above), and means
any future outbound path has to be added deliberately instead of already
being there.

[pi]: https://github.com/badlogic/pi-mono

`./opilot` handles first-run setup (`.env` wizard, cloning each repo) then invokes
the runner. `compose.yml` mounts key on `SCRIPT_DIR`, exported as an absolute host
path so clones mount at their real paths (the agent computes host paths that must
resolve identically inside the container); it defaults to the current project, so
bare `docker compose run …` works from the repo root.

### Core Ruby modules (`lib/opilot/`)

| File | Role |
|------|------|
| `cli.rb` | Arg parsing and dispatch — the one place args are validated, config loaded, the log header stamped. `--help` works in any position (except `chat`'s free-text tail) |
| `ui.rb` | Help text, `status`, `reset` — the single home for every command description; `PD::Runner#usage!` renders `#pd_usage_text` rather than duplicating it |
| `context.rb` | Singleton config — env vars, paths, allowed users, the repo registry |
| `repo.rb` | `Repo` + `Registry` — loads `repos.json`, resolves clone paths, `by_upstream` |
| `pull.rb` | Polls OpenProject; parses `@opilot` comments into `Intent`s |
| `agent.rb` | Main event loop — dispatches the three intents, `:chat`, `:ship` and `:create_wp` |
| `gh_pull.rb` | Polls opilot's own open PRs (one seen merged/closed is stamped `pr_done` and dropped for good; `pr` clears it on reopen); yields `GhIntent`s and per-head-SHA `:ci` intents |
| `upstream_gh_pull.rb` | Tracks registry upstreams for PRs mentioning opilot; `reply_only` intents. `#enabled?` gates on the flag **and** an allowlist |
| `gh_pr_cache.rb` | PR-content cache (`pr.json`, keyed by `updated_at`), mention matching, fresh-comment filtering, CI cache (`ci.json`, keyed by head SHA) |
| `gh_agent.rb` | `gh-agent` loop — own PRs: reply + code + push; upstream: read-only. `#sources` keeps the banner honest |
| `fix_runner.rb` | Terminal `dev build`/`commit`/`plan` — one pipeline named by where it stops |
| `pr_runner.rb` | Terminal `dev refresh`, and gh-agent's `@opilot refresh` via `#refresh_one` |
| `op_runner.rb` | Terminal `op` — one command per `Clients::OpenProject` method it exposes. Three rules hold: **stdout is data** (JSON only, diagnostics to stderr, never `log_script`), every action **reads except `wp create`**, and **`--type` is required of every payload**. `wp form --required` is how you learn what else a project demands. The file header argues all three — read it there rather than re-deriving them |
| `harness.rb` | HTTP client to the harness container; per-WP session IDs |
| `prompts.rb` | All LLM prompts in one place. Everything opilot publishes (WP comments, PR replies and descriptions, plans, spec proposals) is written in ASD-STE100 Simplified Technical English — stated once in `Prompts::PLAIN_ENGLISH` and pulled into the shared blocks (`OP_COMMENT_FORMAT`, `REPLY_CONTRACT`, `TERMINAL_REPLY`, `#plan_skeleton`), never re-worded per prompt. Code and commit messages are out of scope |
| `publish.rb` | Pushes branches to the fork; opens cross-repo draft PRs via Octokit |
| `clients/openproject.rb` | OpenProject REST API. `#add_comment` is the funnel every WP comment passes through, so it demotes markdown headings to bold — the activity tab is a narrow column |
| `clients/github.rb` | GitHub API (Octokit) |
| `clients/http.rb` | Shared HTTP transport with Retriable exponential backoff |

### The `pd` pipeline (`lib/opilot/pd/`, namespace `OPilot::PD`)

Its own namespace and its own doc — see
**[`lib/opilot/pd/CLAUDE.md`](lib/opilot/pd/CLAUDE.md)** for the file table and
every stage. It shares nothing with the bug-fix flow but the core above, and
`lib/opilot/pd.rb` keeps that boundary load-bearing: nothing under `pd/` is
required at boot (`CLI#pd` requires it on demand), and `pd/intake` is lazier still,
keeping roo/nokogiri/rubyzip out of runs that never read a document. The one
exception is `PD::ChangeStore`, required by `gh_pull.rb` because identifying a spec
PR needs the store's layout on every tick.

### Per-work-package state machine

1. **Poll** — `Pull#poll_intents` fetches WPs matching the comment-search filter and
   their comments, de-dupes by `last_acted_comment_at`, and drops every comment
   opilot wrote itself (`Pull#own_comment?`, on the author's user id). That guard
   has to be complete rather than best-effort, because the cutoff cannot back it
   up: a reply is always posted *after* the trigger it answers, so it always sits
   above `last_acted_comment_at`, and opilot's own comments quote the command word
   routinely (`#post_options` tells the reader to answer `@opilot build 1`). It
   replaced a record of the last comment id, which covered one reply and no more —
   a handler that posts two left the first one live, and the notes `Pull` itself
   posts were never recorded at all. This is why `Pull#ensure_bot_identity!`
   demands the bot's **user id** as well as its display name.
2. **Plan** — the LLM (read-only tools) produces `plan.md`; `NEEDS_INFO` aborts with a
   comment, and on a `ship` trigger `OPTIONS` stops here instead (`options.json` plus
   one comment) until a reply names a number. Every clone is first synced to current upstream
   (`sync_bases_for_reading` → `#sync_base!`) because `./opilot` fetches each base
   once at launch and no run checks the tree back off its fix branch — without this a
   long-lived loop plans against the original clone commit or another WP's leftover
   branch, with nothing in the tree saying so. The whole registry is synced at plan
   time (which repos the fix lands in is the plan's own output); `:chat` syncs just
   the target repos. A **dirty** tree is left strictly alone, and a fetch failure
   warns rather than fails.
3. **Implement** — the LLM (Read/Write/Edit + read-only Bash) works across each chosen
   clone on `bug/<id>-<slug>` in one resumed session; the runner commits
   `[<label>] <subject>` per changed repo (`Helpers.wp_label`: `#59942` for numeric
   ids, bare `STC-162` for semantic ones).
4. **Publish** — opilot has **one GitHub identity**, the contributor
   (`GITHUB_CONTRIBUTOR_TOKEN`, a bot with no access to the canonical repos); every
   mode publishes as it and commits are authored by it. The branch goes to the bot's
   fork, a draft PR is opened against the repo's upstream and `base` with a
   cross-repo head and `maintainer_can_modify: true`, and the PR link(s) are posted
   back to the WP.

   The body's WP link is **defanged** (`http`→`hxxp`) so OpenProject's GitHub
   integration doesn't clutter the activity tab with a fork PR nobody has adopted;
   `PrRunner#op_ticket_id` accepts `hxxp` so opilot reads it back, and `gh adopt`
   re-fangs it. The body opens with a bot-only preamble — the AI-prototype disclaimer
   plus an **adopt note** (`gh adopt <number>`) telling maintainers how to re-publish
   under their own account, since fork PRs can't run secret-gated CI
   (`#add_adopt_note`; the number only exists post-create, hence the follow-up body
   edit). Both are fenced between `Publish::BANNER_OPEN`/`BANNER_CLOSE`
   (`<!-- opilot:banner -->` … `<!-- /opilot:banner -->`), because neither is true
   of an adopted PR: `gh adopt` deletes exactly that range and prepends
   `Adapted from #<bot-pr>`. **The fence is a published interface** — the alias lives
   in the README and in maintainers' shells, so changing a marker orphans every PR
   opened before the change. The plan gist link sits *outside* the fence and survives
   adoption.

   The one push-safety rule is **target-based**: any push targeting a registry
   upstream (`#canonical_repo?`) is **refused outright** (`#refuse_canonical_push?`,
   shared by `open_pr`/`open_spec_pr`, gh-agent's `push_followup`, and the `pr`
   refresh) — the fork is the only place opilot writes, so a canonical target is
   always a mistake rather than a mode. The commit stays in the clone and, for a `pr`
   refresh, the branch is reset. There is deliberately no confirmation prompt to
   answer "yes" to. `protected_branch?` (`dev`/`main`/`master`/`release*`) is the
   backstop under it.

**Preflight, shared across commands.** `ship` refuses without its publishing token
up front rather than after a full plan and implement run (`build`/`plan` need none).
`Helpers#require_clone!` is called from **`Helpers#worktree`**, the funnel every git
operation goes through, because a per-command check gets forgotten — `./opilot`
only *warns* when a clone fails, and `Git.open`'s error names neither the repo nor
the fix. `#ensure_claude!` fails with "start the container" at every entry point that
will call the LLM, not mid-run with a connection error.

`:ship` (`@opilot build`, alias `fix`) is the fix intent: it plans and
implements in one pass, unless the plan call answers with `OPTIONS` and waits for
`@opilot build <n>`. The separate `:plan`/`:approve` intents are **gone** — the
options step replaced plan-and-wait, and the code is reviewed as a prototype on the
PR. The intent keeps the name `:ship` because publishing the prototype is what it
does; only the word people type is `build`, and `./opilot dev build` takes the same
word for the same operation, so one thing has one name wherever it is typed. The
difference is who is watching: the terminal verbs have an operator at the console.
Chat lenses (`grill`, `summarize`) are preset instructions over
the ordinary `:chat` intent (`Prompts::LENSES`), with trailing text as a focus hint.

**`:create_wp` (`@opilot create wp <what>`)** splits something out of the thread into
its own work package — `create wp for Rosanna's suggestion` — or, when the request
names several separate pieces of work, into **up to five at once**
(`Agent::MAX_CREATE_WP`), each declared a child of the thread or a peer beside it.
It is op-agent's **only non-comment write to OpenProject**,
and every guard on it stands on one fact: a work package can never be deleted (the
HTTP client has no DELETE verb anywhere), so nothing downstream can undo a wrong or
duplicate create.

- **It refuses outright without `OPILOT_ALLOWED_OP_USER_IDS`** (`Agent#create_wp_enabled?`),
  said once per work package (`create_wp_refusal_noted_at`) and folded into the
  no-allowlist line of the startup banner, since "created nothing" and "cannot create
  anything" look identical in a log — only in that state, because a line confirming the
  normal state is noise on every start.
  With no allowlist every user who can comment could mint work packages without limit.
  The requirement also makes the allowlist gate *unconditional* for this command:
  `Pull#intent_from_comments` drops a non-allowlisted trigger whenever a list exists,
  so every create that reaches the handler is from a listed user.
- **Every work package it will create comes out of ONE LLM call, gated by
  `NEEDS_INFO`** (`Prompts.create_wp`, `Agent#write_work_packages`). When the request
  points at nothing in the thread, questions are the only acceptable answer. N answers
  cost the same one call as one, and a call per work package would not see the others —
  two of them could write the same suggestion, and the duplicate could not be deleted.
  An unreadable answer buys one retry — safe, because nothing is created yet — and
  then stops.
- **The answer is rigidly delimited: `ANSWER:`, then one `BEGIN WORK PACKAGE` …
  `END WORK PACKAGE` block each, carrying `SUBJECT:`, an optional `TYPE:` and an
  optional `LINK:`** (`Helpers.parse_work_packages`). The outer marker
  keeps the writer's deliberation as scratch (a leading sentinel made a real run
  spend its whole output limit getting ready to comply). The **end marker exists to
  detect truncation**: every block shares one output budget, so a cut-off last block
  is the real failure mode, and without it that half-written text would be created as
  a work package. One unclosed block rejects the whole answer. Marker lines inside a
  fenced code block are text — a description quotes the thread, and somebody will
  paste opilot's own answer into a comment (`PD::TasksFile` learned this with an
  example `##` heading).
- **The cap is stated in the prompt and enforced in the runner.** A prompt limit
  drifts; `MAX_CREATE_WP` does not. Over the cap nothing is created and there is no
  retry: the blocks read fine, so the problem is scope and a retry produces the same
  list.
- **It is idempotent on the trigger comment's timestamp** (`created_wps.json`, each
  record written the instant its POST returns 201, before the link and before the
  reply). `Intent` carries no comment id, and `comment_at` is the key
  `Pull#mark_acted` already de-dupes on; one comment now holds **several** records.
  A re-fired trigger re-reports every record it finds and creates nothing more —
  including after a *partial* create, where the ones that landed are the answer and
  the reader is told to ask for the rest on their own.
- **The project is the source work package's**, read from a *fresh* fetch: `item.json`
  caches no project, and its `"id"` may be semantic while the relations route takes
  only numeric ids. The type is one the project really offers (the draft names it, the
  runner matches it case-insensitively); with no match the type link is omitted and
  OpenProject assigns the project's own default.
- **`:add_work_packages` is checked before the LLM call**, on a second GET of the
  project — a work package carries only a link stub for its project, and
  `Helpers.create_wp_allowed?` reads the `createWorkPackage*` links the project
  resource renders only for a user who holds the permission.
- **Every drafted payload is preflighted through the create form, before the first
  POST** (`Agent#payloads_accepted?` → `#payload_accepted?` →
  `POST /api/v3/work_packages/form`). The form does not save, so preflighting the
  whole set first is the only atomic-ish gate there is, and one rejection abandons
  **all** of them: half a tree is worse than none when the halves cannot be deleted,
  the same rule `pd generate-wp` follows. A project can
  *require* custom fields, per project **and type**, so without this the command
  ends as a 422 in the log with the reader told nothing. The form runs the same
  `SetAttributesService` the create runs and does not save, so a payload it accepts
  is one the create accepts — and it answers **200 even for a payload it rejects**,
  which is why `_embedded.validationErrors` decides and the status code does not.
  opilot **must not fill a required custom field itself**: the value carries
  business meaning only a person has, and the work package would be permanent. The
  fields are named back in the instance's own wording (naming *which* one was
  rejected when there are several), with the project's other types listed, and
  nothing is created. A form that answers anything else (403, a proxy's HTML) is not
  an answer about the payload, so the create proceeds and reports its own failure.
- **Child or peer is DECLARED per work package, never inferred.** Each block carries
  a `LINK:` line — `child` or `related` — and `Helpers::DEFAULT_WP_LINK` makes an
  absent or unrecognised value `related`. The difference is not cosmetic:
  OpenProject derives a parent's dates and progress from its children, so a `child`
  link *mutates the source work package*. That is right for "split this into three
  tasks" and wrong for "Rosanna's idea is separate work" — a distinction only the
  request itself carries, which is why the count does not decide it and why the
  default is the reversible direction (a person can re-parent a related work
  package; a wrong parent has already changed the source by the time they see it).
  One set may hold both shapes. `related` uses
  `Clients::OpenProject#create_relation` (the per-work-package route — the global
  `/api/v3/relations` has no POST); the reply states each one's shape, because the
  reader cannot read it off the list.
- **The parent is set after the create, never in the payload, and falls back to
  `relates`.** Hierarchy needs `:manage_subtasks` — a **third** permission next to
  `:add_work_packages` and `:manage_work_package_relations` — so in the create
  payload a missing permission would kill the create itself; as a follow-up PATCH
  (`Clients::OpenProject#update_work_package`, which handles the `lockVersion` retry)
  it costs only the shape of the link. Every link is best-effort and never raised:
  a failure is reported and recorded (`related: false`) for the next ask to finish,
  because the work package exists and cannot be deleted. The new description also
  backlinks the source, which is what a reader sees when the link is the part that
  failed.
- **The declared shape is stored on each record (`link_wanted`).** Records are
  written per-201, so a batch of three where only the first lands leaves one record
  — anything that re-derived the shape later (from the set's size, say) would read
  that survivor as a peer and relate it permanently. `link` records what actually
  landed. A legacy record has neither field and reads as `relates`, which is what
  every record written before this got.
- **Nothing is posted on the new work package, and no reply names `@opilot`.** The poll
  filter searches comment *content*, and a new work package has no acted-state or
  cutoff under it. `Pull#own_comment?` now rejects any comment opilot authored, so
  this is belt-and-braces rather than the only guard — but it costs nothing, and a
  work package that cannot be deleted is the wrong place to lean on one check.
  Same reasoning as `Pull#note_refused_trigger`'s wording.
- **This handler answers its own failures**, unlike every other one (`#handle_and_ack`
  stays silent by design): a reader who asked for a work package waits for a link, and
  silence reads as a broken bot. The reply is composed in Ruby (`#created_note`,
  `#already_created_note`), for `#post_options`' reason: it states what actually
  happened — which links exist, which are children, which POST failed, which type the
  instance substituted — and a sentence the writer composed could drift from that.

### State on disk (`.opilot/` — gitignored)

Per-instance state is namespaced so a different `OPENPROJECT_URL` can't collide (WP
#42 on instance A ≠ #42 on B): work packages and saved filters live under
`work_packages/<op_host>/`. Upstream-PR state is keyed by `<owner>-<repo>/<number>`,
globally unique, so `pr_reviews/` is flat.

```
.opilot/
├── progress.txt             # pipe-delimited audit log
├── chomp.log                # full prompt/response log
├── chat_session_id          # LLM session for the current `chat` REPL (reset each run)
├── work_packages/<op_host>/
│   ├── op_agent_scan.json      # op-agent's saved scan-window watermark
│   ├── resolved-ids.json       # `pd init` cache: project, type ids, statuses + isClosed
│   └── <wp_id>/
│       ├── item.json            # WP metadata + poll cache + acted_at
│       │                        #   + refusal_noted_at (the one allowlist note per WP)
│       │                        #   + create_wp_refusal_noted_at (the one `create wp` off note)
│       ├── related.json         # related WPs pulled in at plan time
│       ├── plan.md              # implementation plan (shared across target repos)
│       ├── options.json         # offered implementation options; present = waiting for a number
│       ├── created_wps.json     # WPs `create wp` made FROM this one, keyed by the trigger's
│       │                        #   comment_at (SEVERAL records per comment); `link_wanted` is
│       │                        #   the shape asked for (parent/relates), `link` what landed,
│       │                        #   `related` whether any link landed at all
│       ├── target_repos.json    # repo names from the plan's REPOS line
│       ├── target_base.json     # optional per-repo base overrides ({repo: base})
│       ├── gist_url.txt         # secret gist of plan.md, linked from every repo's PR
│       ├── session_id           # LLM session (plan + implement)
│       └── repos/<repo_name>/
│           ├── pr.md            # PR description (per-repo diff)
│           ├── pr_url.txt       # published PR URL
│           ├── pr.json          # PR-content cache, keyed by updated_at
│           ├── ci.json          # CI failure detail, keyed by head SHA
│           ├── gh_pr.json       # act-state: last_acted_comment_at, reply ids, ci_acted_sha,
│           │                    #   ci_quiet_sha, ci_attempts, ci_gave_up, pr_done
│           └── gh_session_id    # gh-agent's LLM session
├── pr_reviews/<owner>-<repo>/<number>/   # tracked upstream PR (opilot didn't open it)
│   └── pr.json / ci.json / gh_pr.json / gh_session_id
├── changes/ , openspec/     # `pd` state — see lib/opilot/pd/CLAUDE.md
├── repos/<repo_name>/       # this repo's standalone clone (mounted at /repos/<name>)
├── pi-agent/                # pi's config dir (settings.json/models.json seeded by
│                            #   server.js from pi-settings.json/pi-models.json, auth.json)
└── pi-sessions/             # pi session transcripts, keyed by --session <id>
```

### Harness container communication

Runner POSTs to `http://harness:47291` with headers:

- `X-Harness-Tools` — `"read,grep,find,ls,bash"` (planning/chat) or
  `"read,grep,find,ls,bash,write,edit"` (implementation), each with a `,op_query`
  variant sent by the specific call sites `Helpers#read_tools`/`#impl_tools`
  cover when `Context#op_mcp?` is on (see `MCP.md`) — most `TOOLS_READ`/`TOOLS_IMPL`
  call sites keep the plain grant regardless. `server.js` rejects any other
  grant, so its allowlist (`ALLOWED_TOOL_GRANTS`, four strings) must stay in
  sync with `TOOLS_READ`/`TOOLS_IMPL`/`TOOLS_READ_OP`/`TOOLS_IMPL_OP`.
- `X-Harness-Model` — one model per WP for every session-bound phase (`MODEL_HEAVY`),
  plus `MODEL_LIGHT` for stateless one-shots (a commit subject, a PR description) —
  always `<provider>/<model-id>` (`openrouter/anthropic/claude-sonnet-5`,
  `local/qwen2.5-coder:32b`), not bare Anthropic API ids. **The provider prefix
  selects which pi provider config `seedAgentDir()` writes.** Validated by
  format, not an allowlist — model choice grants no privilege. The format
  permits `:` because every Ollama tag carries one.
- `X-Harness-Session` — session ID (omit on first call; save from the response).

`server.js` spawns `pi --mode json` (plus `--no-extensions -e /app/pi-guards.ts`,
`--no-context-files`, `--no-approve`, `--offline`, and the tools/model/session
above), translates its JSON event stream into the assistant/result/session_id/exit
frame shapes harness.rb parses, and persists the session ID. It sets no `cwd`, so it
inherits `/repos`. See `translate()`'s comment in server.js for the full event-shape mapping.

A run is bounded **twice**, because "stuck" and "long" are different failures. The
tight bound is on **idle** time (`OPILOT_PI_IDLE_TIMEOUT_MIN`, default 5 min),
rearmed on every byte pi writes to stdout *or* stderr: a real implementation run
streams tool calls the whole way, so only a wedged run falls silent. Under it sits
an absolute ceiling (`OPILOT_PI_MAX_RUN_MIN`, default 45 min), which exists because
the server is serialized one-run-at-a-time — a run that never finishes blocks every
other tick's LLM call. A single total cap was the earlier design and it killed
productive multi-repo fixes for being big. SIGTERM escalates to SIGKILL after 10s,
or a pi that ignored it would hold the queue's `busy` flag forever. The exit frame
carries `timeout_kind` (`idle`/`max`) so the runner's error names which fired.

`Harness::READ_TIMEOUT` derives itself from those same two env vars (ceiling + one
idle window + slack) and must stay the **outer** bound: the server writes nothing
until a run starts, so a queued request sees a silent socket for the whole run ahead
of it, and a runner that gives up first turns a named timeout into a bare
`Net::ReadTimeout` — which `#http_stream` does not rescue.

### Required environment variables (`.env`)

| Variable | Purpose |
|----------|---------|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token. Read access suffices for `op`/`chat` (except `op wp create`); agent mode needs write (to comment), plus `:add_work_packages` once `@opilot create wp` is enabled, `:manage_work_package_relations` for its backlink and `:manage_subtasks` to make several of them children of the source (without either link permission the work packages are still created, only unlinked — or related instead of parented); `pd` needs `:add_work_packages` |
| `HARNESS_URL` | Optional; where the runner reaches the harness container (default `http://harness:47291`) |
| `OP_REPO_PATH` | Optional; local openproject checkout to seed that clone from. openproject-only — other repos are configured in `repos.json` |
| `GITHUB_CONTRIBUTOR_TOKEN` | The **contributor identity** — a bot account that is **not a collaborator on the canonical repos** (that lack of access is what enforces isolation). Classic token with `public_repo`, `workflow` (the lagging fork re-introduces upstream's `.github/workflows/*`, rejected without it) and `gist` (the plan gist; skipped if absent). Fine-grained tokens can't open fork→upstream PRs |
| `OPILOT_ALLOWED_OP_USER_IDS` | Comma-separated OpenProject user ids allowed to trigger agent mode (the number in `/users/<id>` — not emails, which a non-admin token can't read). Empty = unrestricted, which needs explicit confirmation — and **switches `@opilot create wp` off entirely**, since a work package can never be deleted |
| `OPILOT_ALLOWED_GH_USERS` | Comma-separated GitHub logins allowed to trigger `gh-agent`. Empty means anyone can trigger on opilot's own PRs — i.e. push code to the bot's branch — so the wizard demands confirmation |
| `OPILOT_TRACK_UPSTREAM_PRS` | Optional (`1`/`true`); also track registry upstreams' PRs for `@opilot` mentions (read-only answers). **Off by default** — the only source reaching outside opilot's own PRs. Also needs `OPILOT_ALLOWED_GH_USERS` |
| `OPILOT_OP_MCP` | Optional; grants `op_query` (live OpenProject lookups via the instance's MCP server — see `MCP.md`) to the plan/chat/gh-reply phases and starts the `opgw` sidecar alongside the harness. **On by default** — set to `0`/`false`/`no`/`off` to disable. An instance with no Enterprise MCP server enabled just answers "unavailable", which is a normal, quiet state |
| `OPILOT_OPGW_URL` | Optional; not meant to be hand-set — `./opilot` exports it (to `http://opgw:47293`) for both the runner and the harness only when `opgw` is actually running. Read by the runner for the startup tool-list check and by `pi-op-mcp.ts` as its own gate: empty means the tool registers at all |
| `OPILOT_INFERENCE_URL` | Optional; the upstream authgw forwards to (default `https://openrouter.ai/api/v1`). Point it at any OpenAI-compatible server. Resolved, pinned and path-allowlisted once at boot |
| `OPILOT_INFERENCE_KEY` | The key authgw presents upstream, if the upstream wants one. Lives only in authgw — never reaches the harness container. Required for OpenRouter; leave empty for a keyless self-hosted server |
| `OPILOT_INFERENCE_AUTH` | Optional; how the key is presented, as a `Header: value with {key}` template (default `Authorization: Bearer {key}`; Azure OpenAI needs `api-key: {key}`). authgw always deletes the inbound `Authorization` first, whatever this names |
| `OPILOT_MODEL_HEAVY` | Optional; overrides the heavy model used for every session-bound phase — plan, chat, implement (default `openrouter/anthropic/claude-sonnet-5`). **Its provider prefix decides whether pi gets `pi-models.json` or a generated config** |
| `OPILOT_MODEL_LIGHT` | Optional; overrides the light model used for stateless one-shot passes — commit subject, PR description (default `openrouter/anthropic/claude-haiku-4.5`) |
| `OPILOT_MODEL_API` | Optional; the wire protocol for a generated provider — `openai-completions` (default), `openai-responses`, `anthropic-messages`, `google-generative-ai`. A different axis from the auth header: a native Anthropic or Google upstream needs both |
| `OPILOT_MODEL_CONTEXT_WINDOW` | Optional; context window for a self-hosted model. Omitted leaves pi's default |
| `OPILOT_HARNESS_MEM` / `OPILOT_HARNESS_CPUS` | Optional; caps on the harness container (defaults `4g` / `2`, generous and unmeasured). Too low reads as an idle timeout, not an OOM — measure a real `dev commit` before tightening |
| `OPILOT_PD_PARENT_TYPE` | Optional; the WP type a `pd` change becomes (default `FEATURE`), resolved by name at `pd init` |
| `OPILOT_PD_CHILD_TYPE` | Optional; the type each `tasks.md` section becomes (default `IMPLEMENTATION`) |
| `OPILOT_PD_IMPLEMENTING_STATUS` | Optional; status set when `pd implement` starts (default `In progress`). Empty skips the transition; a missing name is reported, never fatal |
| `OPILOT_PD_IMPLEMENTED_STATUS` | Optional; status set once the draft PR is open (default `Developed`) |
| `OPILOT_CI_MAX_ATTEMPTS` | Optional; how many times `gh-agent` chases one PR's CI before posting a "needs a human" note (default `5`) |
| `OPILOT_CI_IGNORE_CHECKS` | Optional; check names ignored when reading CI status (default `SaaS tests` — it needs secrets a fork PR can't access, so it always fails) |
| `OPILOT_PI_IDLE_TIMEOUT_MIN` | Optional; minutes one LLM run may produce **no output** before `server.js` kills it (default `5`) |
| `OPILOT_PI_MAX_RUN_MIN` | Optional; absolute ceiling in minutes on one LLM run (default `45`). Raise for very large fixes — but the harness runs one call at a time, so this is also how long one run may block every other poll. Both values are read by the runner too (`Harness::READ_TIMEOUT`), so its socket timeout follows on its own |
