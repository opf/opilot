# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What This Project Is

`openproject-chomper` is an AI agent that plans fixes for OpenProject work
packages, implements them in isolated git clones, and opens draft PRs.

A fix can land in **one or more product repos**, defined in `repos.json` (`name`,
`upstream`, `base`, optional `shared_repo_path`, `description`, plus a top-level
`summary`). Claude sees the registry while planning and declares the targets on the
plan's first line — `REPOS: <name>[@<base>][, <name>…]` — which
`Helpers#record_chosen_repos` stores in `target_repos.json`, with any `@<base>`
override (e.g. `openproject@release/17.6`) in `target_base.json`. The fix branch is
both cut from and PR'd against that base (`ItemState#base_for`).

Each repo is a standalone clone at `.chomper/repos/<name>`, mounted into the claude
container at `/repos/<name>`; the runner ships an independent branch + PR to each
repo that actually changed (`Chomper::Registry`/`Chomper::Repo`). `OP_REPO_PATH`
seeds *only* the openproject clone from a local checkout (a wrong path falls back to
a fresh clone).

## Modes

Agent loops: `./chomper agent` (both), `agent op`, `agent gh` — the older
`op-agent`/`gh-agent` names still work and are used below.

### op-agent

Polls work packages, driven by `@chomper` comments. The one command word is
**`@chomper build`** (alias `fix`); every other word is chat. The words this
replaced — `ship`, `plan`, `approve`, `prototype`, `pr`, `implement` — are chat too,
so an old habit gets an answer that names the real command rather than silence.

Naming chomper in a WP's **Developers** field is a second trigger, synthesizing the same
`:ship` intent (`Pull#intent_from_developer`). It fires **once per WP, ever**
(`developer_acted_at` — clearing and re-setting the field doesn't re-fire; later
re-work goes through comments) from **anyone** (not allowlist-gated: setting the
field already needs edit-WP permission; disable with `CHOMPER_DEVELOPER_TRIGGER=0`).
A same-tick comment wins, an already-shipped WP is marked acted without firing, and
the reply is unaddressed/internal with no 👀 pickup signal. The de-dup gate is the
WP's `updatedAt` vs the scan floor (the list payload carries no per-field
timestamp), so a WP handed over long ago but bumped inside the window fires once.

**Once a prototype exists, the work package is done.** `#handle_ship` answers a
shipped WP with the PR link and spends no Claude call: code review belongs on the
pull request, where gh-agent reads comments and pushes changes, and two tracks for
one fix would split the record of it. Planning again would also rewrite `plan.md`
while the PR keeps linking the gist of the plan as it was.

**A plan on file with no new direction is built, not rewritten.** That is what the
retired `approve` did, and the only way to get a prototype of the exact plan a human
has read.

**`ship` offers options before it writes code.** A fix with more than one
defensible shape is answered with 2–3 numbered options, one sentence each, and
nothing else happens until someone replies `@chomper build <n>`. The judgment is
folded into the *same* plan call as a third first-line
sentinel beside `NEEDS_INFO` and `REPOS:` — `OPTIONS`, then one pipe-delimited line
per option (`Prompts::OPTIONS_CONTRACT`) — so a one-shape ticket is planned and
shipped in that call and costs exactly what it did before. `Agent#produce_plan`
returns `:options`, writes `options.json`, and `#post_options` composes the comment
in Ruby (the writer supplies only title and sentence, so the wording, numbering and
reply instructions cannot drift). The sentinel is honoured even when options were
*not* invited, so an uninvited block is never shipped as a plan; an unusable list
buys one retry for a plan, then `:failed`. Options are invited only when nothing has
settled the approach yet: a saved plan, a chosen option, or free-text direction all
skip the question.
A **leading** number selects, and words after it ride along as direction
(`Helpers.option_choice`/`#option_focus_text`, shared with the terminal), so
"2 but keep the toast" neither loses the option nor loses the sentence. The repo/size
line is labelled an **estimate**, because the plan's own `REPOS` line decides where
the fix lands; the chosen option's repos are passed into the plan call as the expected
targets so the two rarely disagree.

Selecting is allowlist-gated like any comment trigger, which the offer says out
loud when `CHOMPER_ALLOWED_OP_USER_IDS` is set. A rejected trigger is no longer
silent: `Pull#note_refused_trigger` answers the commenter **once per WP**
(`refusal_noted_at`), because chomper offers options to anyone who can comment while
only allowlisted users may choose one, and because a reply is the one thing an
unlisted user can make chomper do — a per-comment answer would let anyone fill the
activity tab. A **Developers** handover names no
commenter, so its offer is posted **publicly** (the one visibility override in
`#post_note`): an internal comment that mentions nobody reaches nobody who can
answer it. That handover has only its one shot, so an offer nobody answers waits
for a human — by design, with no reminder.

"Developers" is a **user custom field**, not a stock one, so its `customFieldN` key
differs per instance and can't be hardcoded: `#developer_field_key` reads the WP's
`_links.schema` and matches the schema's field *names* against
`CHOMPER_DEVELOPER_FIELD` (default `Developers`, case-insensitive), memoized per
schema href so a poll costs at most one extra call per project+type. Matching by
name also means a stock field works — `CHOMPER_DEVELOPER_FIELD=Assignee` restores
the old assignee behaviour with no code change. Being multi-value, the field
renders as an array of links, and any entry naming chomper counts; the link must be a **user**
(`/users/<id>`), since a group or placeholder user could share the bot's numeric id.
An instance without the field logs one note and leaves the trigger off. The
pre-Developers marker `assignee_acted_at` is still honoured on read, so switching the
field doesn't re-fire on every WP that already had its one shot.

Planning or chatting also pulls in the WP's **related** WPs (relations plus
parent/children), each cached as its own `item.json` with a `related.json` index the
prompts reference. `wp ship`/`build`/`plan` share this.

### gh-agent

Polls two sources each tick. Both watch the thread and inline review comments, are
gated by the GitHub-login allowlist, and never merge. Shared caching and
mention-matching live in `GhPrCache`.

**Chomper's own PRs** (`GhPull`, those with a `repos/<name>/pr_url.txt`) — always
reply, code if asked, pushing to the fork. The one command word is **`@chomper
refresh`**: the full `pr`-command treatment (`PrRunner#refresh_one`) with the base
merge forced and the CI fix run regardless of act-state or cap. Built
`interactive: false`, so fork pushes go straight through while a canonical-repo
target is refused and the refresh discarded.

It also **auto-fixes failed CI** (always on). Once checks complete with ≥1 failure,
the detail (annotations, output summaries, failed-job log tails) is cached to
`ci.json`, fixed with `Prompts.fix_ci`, committed and pushed. The trigger is the
**head SHA**: `gh_pr.json` tracks `ci_acted_sha` (once per commit) and `ci_attempts`
(`CHOMPER_CI_MAX_ATTEMPTS`, default 5; past the cap it posts a one-time "needs a
human" note and sets `ci_gave_up`). It acts on the *first* failure rather than
waiting out slow jobs, never acts in the same tick as a comment trigger, ignores
`CHOMPER_CI_IGNORE_CHECKS`, and needs no allowlist. A green verdict is cached
(`ci_quiet_sha`) only once the commit has **settled** (`CI_SETTLE_SECONDS`) — checks
register over time, so a just-pushed commit can look green before its failing jobs
appear. Check-run reads are fully paginated (`auto_paginate` is off by default,
which would truncate a big CI matrix).

**Tracked upstream PRs** (`UpstreamGhPull`) — open PRs on a registry `upstream` that
@-mention chomper, except the bot's own (`own_pr?`). Found via the search API so a
Claude call is spent only on real mentions. The trigger is a prompt addressed to
chomper, not a review pass over other people's work; what differs is write access,
so these intents are `reply_only` — read-only fetch, answered in text
(`Prompts.pr_review`), never pushed. Applicable code still lands: for lines already
in the diff the review emits a `SUGGESTIONS:` block
(`Prompts::SUGGESTION_CONTRACT`) that `GhAgent#post_suggestions` posts as a review
of inline `suggestion` comments (anchored to the head SHA, `event: COMMENT`) — the author
applies each with one click; a bad line range 422s and falls back to prose. A
failing CI run is read too (keyed by head SHA), so "why is CI red?" gets an
explained answer. State lives in `pr_reviews/<owner>-<repo>/<number>/` (the name
predates this framing; renaming it orphans every tracked PR's act-state).

**Off unless `CHOMPER_TRACK_UPSTREAM_PRS` is set, and it also needs
`CHOMPER_ALLOWED_GH_USERS`** — the only source reaching outside chomper's own PRs.
The startup banner names which of the three states the run is in, since "scanned
nothing" and "not scanning" look identical in the log.

### Terminal modes

- **`wp ship <id>...`** (alias `wp fix`) — fetch by id (ignoring filters), run a
  plan/approve loop (`[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`) per id, ship each
  approved plan as a draft PR. One failure doesn't abort the rest. A fix with more than
  one shape is offered as the same numbered options first
  (`#prompt_option_choice`) — a number picks one, free text is direction of the
  operator's own — so a ticket behaves the same at the console as in the thread.
- **`wp build <id>...`** — stop after the local commit. A later `ship` finds the
  branch (`branch_has_commits?`) and goes straight to publish.
- **`wp plan <id>...`** — stop at the approved plan.
- **`wp pr <id|pr-url>...`** — refresh shipped PRs (`PrRunner`). A URL is matched
  against local state, else *adopted* via the OpenProject ticket link in the
  description's top 15 lines; a WP id with no state is *discovered* by searching each
  upstream for open bot-authored PRs mentioning the id, adopted only after verifying
  author = bot login and the ticket link (the author check is the trust boundary —
  `pr` pushes to the PR's head branch). Per PR: sync to the head; merge the base
  **only when the branch has had no commits for over a day** (judged on the head
  commit's date, so a fresh comment doesn't block a merge and a just-pushed branch
  doesn't churn merge commits); fix failing CI regardless of act-state or cap (a
  failure past GitHub's ~1-month log retention has no detail left, so it falls back
  to base-merge + push); address comments newer than chomper's last action (no
  mention or allowlist gate — the point is sweeping feedback that never pinged
  chomper). Pushed to the fork after a `[y]es push / [d]iscard` prompt. The summary
  is posted as a 🤖 comment and the cutoff advances so gh-agent doesn't re-handle it.
- **`wp pull [<id>...]`** — mirror WPs into the local cache for later `chat`. With
  ids, exactly those; without, the op-agent filter wizard plus a bulk mirror.
- **`chat [message]`** — free read-only conversation over the local mirrors, never
  fetching, planning, or shipping. `.chomper/` is mounted read-only at `/state`, so
  `Prompts.free_chat` orients Claude at the layout and it Greps/Reads from there.
  Fresh per-run session; needs no tokens or allowlist.

### pd (product development)

`./chomper pd <subcommand>` is a spec-driven pipeline, separate from the bug-fix
modes: OpenProject Documents → an [OpenSpec](https://github.com/Fission-AI/OpenSpec)
change proposal reviewed as a PR → generated work packages → one implementation run
per WP → archive. It has its own namespace because the bug-fix verbs also take a
work-package id while meaning something else entirely. Like every mode it publishes
as the contributor bot. Implemented: M0–M3.

The stages (`init`, `intake`, `propose`, `generate-wp`, `implement`), the
three-copy spec store, attachment conversion, and the `openspec` CLI wrapper are
documented in **[`lib/chomper/pd/CLAUDE.md`](lib/chomper/pd/CLAUDE.md)** — read that
before touching anything under `lib/chomper/pd/`.

## Commands

```bash
# Run both agent loops (polls every 20s) — the normal way to run chomper.
# `agent op` / `agent gh` run one; the old op-agent / gh-agent names still work.
./chomper agent

# Plan and ship work packages by id (terminal approval; `wp fix` is an alias)
./chomper wp ship <id>...
./chomper wp build <id>...   # stop after the local commit — no push, no PR
./chomper wp plan <id>...    # stop at the approved plan

# Refresh shipped PRs: merge base, fix CI, address new comments, push (confirmed)
./chomper wp pr <id|pr-url>...

# Mirror WPs into the local cache (no plan/ship); no ids → filter wizard
./chomper wp pull [<id>...]

# Free read-only chat about the local mirrors
./chomper chat [message]

# Product development (spec-driven)
./chomper pd init <project-id> [--repo <name>]
./chomper pd intake <project-id> <change-id> [--doc-id <id>]...
./chomper pd propose <change-id>
./chomper pd generate-wp <change-id>
./chomper pd implement <wp-id>...

./chomper status    # list planned/shipped work packages
./chomper reset     # delete .chomper/ (clones included)

# Tests
docker compose run --no-deps --rm runner bundle exec rake
docker compose run --no-deps --rm runner bundle exec ruby -Itest test/chomper/agent_test.rb

# Rebuild runner image (required after editing Gemfile)
docker compose run --no-deps --rm runner bundle lock
docker compose build runner
```

## Architecture

Four Docker containers orchestrated by `compose.yml`:

- **Runner** (Ruby 4.0) — the agent. Polls OpenProject, dispatches intents, calls
  Claude, pushes branches, opens PRs. Does all real git.
- **Claude** (Node 20 + Claude Code CLI) — wraps `claude -p` via `server.js` on port
  47291 (internal network only, never published). Working directory is `/repos` with
  every worktree at `/repos/<name>`, so Claude Code auto-loads
  `/repos/openproject/CLAUDE.md` as project memory. Its Bash grant is **read-only
  git** — history for context, but no commit, push, or non-git command. Two
  `PreToolUse` hooks (`--settings /app/claude-settings.json`): `guard-writes.js`
  blocks writes outside `/repos`, `guard-bash.js` allows only read-only git.
  `ANTHROPIC_API_KEY` selects auth: a real key routes via `ANTHROPIC_BASE_URL` →
  authgw with only a fixed handshake token in this container; the literal `oauth`
  (or a legacy blank) uses stored `claude auth login` creds.
- **Authgw** (Node 20, `authgw.js`) — holds the real key, validates the fixed
  gateway token (`CHOMPER_GW_TOKEN`, non-secret), injects `x-api-key`, forwards to a
  hardcoded `api.anthropic.com`. Not an open proxy, so it egresses directly.
- **Proxy** (tinyproxy) — egress allowlist for the claude container
  (`tinyproxy-filter`); everything else denied.

`./chomper` handles first-run setup (`.env` wizard, cloning each repo) then invokes
the runner. `compose.yml` mounts key on `SCRIPT_DIR`, exported as an absolute host
path so clones mount at their real paths (the agent computes host paths that must
resolve identically inside the container); it defaults to the current project, so
bare `docker compose run …` works from the repo root.

### Core Ruby modules (`lib/chomper/`)

| File | Role |
|------|------|
| `cli.rb` | Arg parsing and dispatch — the one place args are validated, config loaded, the log header stamped. `--help` works in any position (except `chat`'s free-text tail) |
| `ui.rb` | Help text, `status`, `reset` — the single home for every command description; `PD::Runner#usage!` renders `#pd_usage_text` rather than duplicating it |
| `context.rb` | Singleton config — env vars, paths, allowed users, the repo registry |
| `repo.rb` | `Repo` + `Registry` — loads `repos.json`, resolves clone paths, `by_upstream` |
| `pull.rb` | Polls OpenProject; parses `@chomper` comments into `Intent`s |
| `agent.rb` | Main event loop — dispatches the two intents, `:chat` and `:ship` |
| `gh_pull.rb` | Polls chomper's own open PRs (one seen merged/closed is stamped `pr_done` and dropped for good; `pr` clears it on reopen); yields `GhIntent`s and per-head-SHA `:ci` intents |
| `upstream_gh_pull.rb` | Tracks registry upstreams for PRs mentioning chomper; `reply_only` intents. `#enabled?` gates on the flag **and** an allowlist |
| `gh_pr_cache.rb` | PR-content cache (`pr.json`, keyed by `updated_at`), mention matching, fresh-comment filtering, CI cache (`ci.json`, keyed by head SHA) |
| `gh_agent.rb` | `gh-agent` loop — own PRs: reply + code + push; upstream: read-only. `#sources` keeps the banner honest |
| `fix_runner.rb` | Terminal `wp ship`/`build`/`plan` |
| `pr_runner.rb` | Terminal `wp pr`, and gh-agent's `@chomper refresh` via `#refresh_one` |
| `claude.rb` | HTTP client to the claude container; per-WP session IDs |
| `prompts.rb` | All Claude prompts in one place. Everything chomper publishes (WP comments, PR replies and descriptions, plans, spec proposals) is written in ASD-STE100 Simplified Technical English — stated once in `Prompts::PLAIN_ENGLISH` and pulled into the shared blocks (`OP_COMMENT_FORMAT`, `REPLY_CONTRACT`, `TERMINAL_REPLY`, `#plan_skeleton`), never re-worded per prompt. Code and commit messages are out of scope |
| `publish.rb` | Pushes branches to the fork; opens cross-repo draft PRs via Octokit |
| `clients/openproject.rb` | OpenProject REST API. `#post_activity` is the funnel every WP comment passes through, so it demotes markdown headings to bold — the activity tab is a narrow column |
| `clients/github.rb` | GitHub API (Octokit) |
| `clients/http.rb` | Shared HTTP transport with Retriable exponential backoff |

### The `pd` pipeline (`lib/chomper/pd/`, namespace `Chomper::PD`)

Its own namespace and its own doc — see
**[`lib/chomper/pd/CLAUDE.md`](lib/chomper/pd/CLAUDE.md)** for the file table and
every stage. It shares nothing with the bug-fix flow but the core above, and
`lib/chomper/pd.rb` keeps that boundary load-bearing: nothing under `pd/` is
required at boot (`CLI#pd` requires it on demand), and `pd/intake` is lazier still,
keeping roo/nokogiri/rubyzip out of runs that never read a document. The one
exception is `PD::ChangeStore`, required by `gh_pull.rb` because identifying a spec
PR needs the store's layout on every tick.

### Per-work-package state machine

1. **Poll** — `Pull#poll_intents` fetches WPs and comments, de-dupes by
   `last_acted_comment_at`. A WP whose Developers include chomper, with no fresh comment, yields a synthetic
   `:ship` (`source: :developer`, de-duped by `developer_acted_at`).
2. **Plan** — Claude (read-only tools) produces `plan.md`; `NEEDS_INFO` aborts with a
   comment, and on a `ship` trigger `OPTIONS` stops here instead (`options.json` plus
   one comment) until a reply names a number. Every clone is first synced to current upstream
   (`sync_bases_for_reading` → `#sync_base!`) because `./chomper` fetches each base
   once at launch and no run checks the tree back off its fix branch — without this a
   long-lived loop plans against the original clone commit or another WP's leftover
   branch, with nothing in the tree saying so. The whole registry is synced at plan
   time (which repos the fix lands in is the plan's own output); `:chat` syncs just
   the target repos. A **dirty** tree is left strictly alone, and a fetch failure
   warns rather than fails.
3. **Implement** — Claude (Read/Write/Edit + read-only Bash) works across each chosen
   clone on `bug/<id>-<slug>` in one resumed session; the runner commits
   `[<label>] <subject>` per changed repo (`Helpers.wp_label`: `#59942` for numeric
   ids, bare `STC-162` for semantic ones).
4. **Publish** — chomper has **one GitHub identity**, the contributor
   (`GITHUB_CONTRIBUTOR_TOKEN`, a bot with no access to the canonical repos); every
   mode publishes as it and commits are authored by it. The branch goes to the bot's
   fork, a draft PR is opened against the repo's upstream and `base` with a
   cross-repo head and `maintainer_can_modify: true`, and the PR link(s) are posted
   back to the WP.

   The body's WP link is **defanged** (`http`→`hxxp`) so OpenProject's GitHub
   integration doesn't clutter the activity tab with a fork PR nobody has adopted;
   `PrRunner#op_ticket_id` accepts `hxxp` so chomper reads it back, and `gh adopt`
   re-fangs it. The body opens with a bot-only preamble — the AI-prototype disclaimer
   plus an **adopt note** (`gh adopt <number>`) telling maintainers how to re-publish
   under their own account, since fork PRs can't run secret-gated CI
   (`#add_adopt_note`; the number only exists post-create, hence the follow-up body
   edit). Both are fenced between `Publish::BANNER_OPEN`/`BANNER_CLOSE`
   (`<!-- chomper:banner -->` … `<!-- /chomper:banner -->`), because neither is true
   of an adopted PR: `gh adopt` deletes exactly that range and prepends
   `Adapted from #<bot-pr>`. **The fence is a published interface** — the alias lives
   in the README and in maintainers' shells, so changing a marker orphans every PR
   opened before the change. The plan gist link sits *outside* the fence and survives
   adoption.

   The one push-safety rule is **target-based**: any push targeting a registry
   upstream (`#canonical_repo?`) is **refused outright** (`#refuse_canonical_push?`,
   shared by `open_pr`/`open_spec_pr`, gh-agent's `push_followup`, and the `pr`
   refresh) — the fork is the only place chomper writes, so a canonical target is
   always a mistake rather than a mode. The commit stays in the clone and, for a `pr`
   refresh, the branch is reset. There is deliberately no confirmation prompt to
   answer "yes" to. `protected_branch?` (`dev`/`main`/`master`/`release*`) is the
   backstop under it.

**Preflight, shared across commands.** `ship` refuses without its publishing token
up front rather than after a full plan and implement run (`build`/`plan` need none).
`Helpers#require_clone!` is called from **`Helpers#worktree`**, the funnel every git
operation goes through, because a per-command check gets forgotten — `./chomper`
only *warns* when a clone fails, and `Git.open`'s error names neither the repo nor
the fix. `#ensure_claude!` fails with "start the container" at every entry point that
will call Claude, not mid-run with a connection error.

`:ship` (`@chomper build`, alias `fix`) is the only working intent: it plans and
implements in one pass, unless the plan call answers with `OPTIONS` and waits for
`@chomper build <n>`. The separate `:plan`/`:approve` intents are **gone** — the
options step replaced plan-and-wait, and the code is reviewed as a prototype on the
PR. The intent keeps the name `:ship` (publishing the prototype is what it does, and
`:build` already names the terminal mode that stops before the push), so the comment
word and the symbol differ on purpose. The terminal verbs are unchanged — `wp plan`,
`wp build` and `wp ship` all have an operator at the console. Chat lenses (`grill`, `summarize`) are preset instructions over
the ordinary `:chat` intent (`Prompts::LENSES`), with trailing text as a focus hint.

### State on disk (`.chomper/` — gitignored)

Per-instance state is namespaced so a different `OPENPROJECT_URL` can't collide (WP
#42 on instance A ≠ #42 on B): work packages and saved filters live under
`work_packages/<op_host>/`. Upstream-PR state is keyed by `<owner>-<repo>/<number>`,
globally unique, so `pr_reviews/` is flat.

```
.chomper/
├── progress.txt             # pipe-delimited audit log
├── chomp.log                # full prompt/response log
├── chat_session_id          # Claude session for the current `chat` REPL (reset each run)
├── work_packages/<op_host>/
│   ├── op_agent_filters.json   # saved op-agent search filters
│   ├── resolved-ids.json       # `pd init` cache: project, type ids, statuses + isClosed
│   └── <wp_id>/
│       ├── item.json            # WP metadata (incl. developers[]) + poll cache + acted_at
│       │                        #   + refusal_noted_at (the one allowlist note per WP)
│       ├── related.json         # related WPs pulled in at plan time
│       ├── plan.md              # implementation plan (shared across target repos)
│       ├── options.json         # offered implementation options; present = waiting for a number
│       ├── target_repos.json    # repo names from the plan's REPOS line
│       ├── target_base.json     # optional per-repo base overrides ({repo: base})
│       ├── gist_url.txt         # secret gist of plan.md, linked from every repo's PR
│       ├── session_id           # Claude session (plan + implement)
│       └── repos/<repo_name>/
│           ├── pr.md            # PR description (per-repo diff)
│           ├── pr_url.txt       # published PR URL
│           ├── pr.json          # PR-content cache, keyed by updated_at
│           ├── ci.json          # CI failure detail, keyed by head SHA
│           ├── gh_pr.json       # act-state: last_acted_comment_at, reply ids, ci_acted_sha,
│           │                    #   ci_quiet_sha, ci_attempts, ci_gave_up, pr_done
│           └── gh_session_id    # gh-agent's Claude session
├── pr_reviews/<owner>-<repo>/<number>/   # tracked upstream PR (chomper didn't open it)
│   └── pr.json / ci.json / gh_pr.json / gh_session_id
├── changes/ , openspec/     # `pd` state — see lib/chomper/pd/CLAUDE.md
├── repos/<repo_name>/       # this repo's standalone clone (mounted at /repos/<name>)
└── claude-auth/             # claude CLI config (OAuth creds when no API key is set)
```

### Claude container communication

Runner POSTs to `http://claude:47291` with headers:

- `X-Claude-Tools` — `"Read,Grep,Glob,Bash"` (planning/chat) or
  `"Read,Grep,Glob,Write,Edit,Bash"` (implementation). `server.js` rejects any other
  grant, so its allowlist must stay in sync with `TOOLS_READ`/`TOOLS_IMPL`.
- `X-Claude-Model` — one model per WP for every session-bound phase (`MODEL_WORK`),
  plus `MODEL_FAST` for stateless one-shots. Validated by format, not an allowlist —
  model choice grants no privilege.
- `X-Claude-Session` — session ID (omit on first call; save from the response).

`server.js` spawns `claude -p` with `--output-format stream-json --verbose --model
<model>`, streams NDJSON back, and persists the session ID. It sets no `cwd`, so it
inherits `/repos`.

### Required environment variables (`.env`)

| Variable | Purpose |
|----------|---------|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token. Read access suffices for `wp`/`chat`; agent mode needs write (to comment), `pd` needs `:add_work_packages` |
| `CLAUDE_URL` | Optional; where the runner reaches the claude container (default `http://claude:47291`) |
| `OP_REPO_PATH` | Optional; local openproject checkout to seed that clone from. openproject-only — other repos are configured in `repos.json` |
| `GITHUB_CONTRIBUTOR_TOKEN` | The **contributor identity** — a bot account that is **not a collaborator on the canonical repos** (that lack of access is what enforces isolation). Classic token with `public_repo`, `workflow` (the lagging fork re-introduces upstream's `.github/workflows/*`, rejected without it) and `gist` (the plan gist; skipped if absent). Fine-grained tokens can't open fork→upstream PRs |
| `CHOMPER_ALLOWED_OP_USER_IDS` | Comma-separated OpenProject user ids allowed to trigger agent mode (the number in `/users/<id>` — not emails, which a non-admin token can't read). Empty = unrestricted, which needs explicit confirmation |
| `CHOMPER_ALLOWED_GH_USERS` | Comma-separated GitHub logins allowed to trigger `gh-agent`. Empty means anyone can trigger on chomper's own PRs — i.e. push code to the bot's branch — so the wizard demands confirmation |
| `CHOMPER_TRACK_UPSTREAM_PRS` | Optional (`1`/`true`); also track registry upstreams' PRs for `@chomper` mentions (read-only answers). **Off by default** — the only source reaching outside chomper's own PRs. Also needs `CHOMPER_ALLOWED_GH_USERS` |
| `ANTHROPIC_API_KEY` | A real key (recommended) lives only in authgw. The literal `oauth` selects `claude auth login` instead (creds in the claude container — less isolated); a legacy blank means the same |
| `CHOMPER_MODEL` | Optional; overrides the work model (default `claude-opus-4-8`) |
| `CHOMPER_TRIAGE_MODEL` | Optional; overrides the fast model (default `claude-haiku-4-5`) |
| `CHOMPER_DEVELOPER_TRIGGER` | Optional (`0`/`false`); disable the Developers trigger. Turn off where WP edit rights are broad. The older `CHOMPER_ASSIGN_TRIGGER` is still honoured as a fallback |
| `CHOMPER_DEVELOPER_FIELD` | Optional; the WP field whose value fires that trigger, matched against the schema's field names (default `Developers`, a user custom field). Set to a stock field name (e.g. `Assignee`) to trigger on that instead |
| `CHOMPER_PD_PARENT_TYPE` | Optional; the WP type a `pd` change becomes (default `FEATURE`), resolved by name at `pd init` |
| `CHOMPER_PD_CHILD_TYPE` | Optional; the type each `tasks.md` section becomes (default `IMPLEMENTATION`) |
| `CHOMPER_PD_IMPLEMENTING_STATUS` | Optional; status set when `pd implement` starts (default `In progress`). Empty skips the transition; a missing name is reported, never fatal |
| `CHOMPER_PD_IMPLEMENTED_STATUS` | Optional; status set once the draft PR is open (default `Developed`) |
| `CHOMPER_CI_MAX_ATTEMPTS` | Optional; how many times `gh-agent` chases one PR's CI before posting a "needs a human" note (default `5`) |
| `CHOMPER_CI_IGNORE_CHECKS` | Optional; check names ignored when reading CI status (default `SaaS tests` — it needs secrets a fork PR can't access, so it always fails) |
