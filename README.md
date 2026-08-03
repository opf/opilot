# openproject-chomper

> ⚠️ **Proof of concept — use at your own risk!**

An OpenProject AI development orchestrator that helps you implement work packages, end to end.

**Agent mode**
* Assists you inside both WP Activity tabs and GitHub PRs.
* Just tag `@chomper` to ask questions, plan together, and even generate PRs.
* **Operates a dedicated [OpenProject](https://community.openproject.org/users/100163) & [GitHub user](https://github.com/op-chomper).**

**Script mode**
* Works entirely within your terminal.
* Run `./chomper <command>`
* **Can be scoped to your own OpenProject & GitHub user.**

---

## Table of Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Bird's-eye view](#birds-eye-view)
- [Interface](#interface)
- [Reviewing & pushing](#reviewing--pushing)
- [Configuration](#configuration)
- [Development](#development)
- [TODO](#todo)

---

## Requirements

- **Docker**
- GitHub auth token for a **bot account** that is not a collaborator on the product repos — chomper only ever opens fork PRs (we currently use [op-chomper](https://github.com/op-chomper))
- OpenProject API token (read-only for script mode, comment-writable for agent mode)

---

## Quick start

### Setup
```bash
git clone https://github.com/opf/openproject-chomper
cd openproject-chomper
# Create .env based on .env.example OR just leave it to the first startup wizard
```

### Agent mode
```bash
# Run the agent: it scans for new activity on OpenProject WPs + its own GitHub PRs and acts on @chomper mentions
./chomper agent
```

### Script mode
```bash
# Run one-time E2E fix of one or more specific WPs
./chomper wp ship <id>...
# OR just draft (and approve) a plan without building
./chomper wp plan <id>...
# OR refresh a stale shipped PR (merge base, fix CI, address comments)
./chomper wp pr <id-or-pr-url>...
# and more — ./chomper wp lists the group
```

## Bird's-eye view

```
              ┌─────────────────┐
              │    ./chomper    │
              │ (shell wrapper) │
              └─────────────────┘
                       │
                       │ docker compose run
                       │
┌─ Docker ─────────────┼──────────────────────────────────────────────┐
│                      ▼                                              │
│    ┌─────────── runner container ───────────┐                       │
│    │                                        │                       │
│    │ Ruby 4.0 script                        │                       │     ┌──────────┐
│    │  * Pulls WP content from OP API        ├───────────────────────┤────▶│  OP API  │
│    │  * Manages metadata in .chomper/       │                       │     └──────────┘
│    │      * WP metadata mirror              │                       │
│    │      * Plan files                      │                       │
│    │      * Draft PR data                   │                       │     ┌────────────┐
│    │  * Pushes branches and opens PRs       ├───────────────────────┤────▶│ GitHub API │
│    │  * Delegates conversations to Claude   │                       │     └────────────┘
│    └────────────────────────────────────────┘                       │
│                      ▲                                              │
│                      │ json                                         │
│                      ▼                                              │
│   ┌──────────── claude container ────────────┐   ┌─── proxy ───┐    │
│   │ Node.js server (:47291)                  │   │ tinyproxy   │    │   ┌────────────────────────┐
│   │   POST / → `claude -p`                   │──▶│ (:8888)     ├────┼──▶│ Anthropic telemetry,   │
│   │                                          │   │ egress      │    │   │ Rails docs (allowlist) │
│   │ volumes:                                 │   │ allowlist   │    │   └────────────────────────┘
│   │   .chomper/        → /state  (ro)        │   └─────────────┘    │
│   │   .chomper/repos   → /repos  (rw)        │   ┌── authgw ───┐    │   ┌────────────────────────┐
│   │                                          │   │ injects     │    │   │ api.anthropic.com      │
│   │ no real API key — inference via authgw,  │──▶│ x-api-key   ├────┼──▶│ (inference)            │
│   │ everything else via proxy; internal-only │   │ (real key)  │    │   └────────────────────────┘
│   └──────────────────────────────────────────┘   └─────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

### Security model

The claude container processes untrusted text (work package descriptions and
comments), so it is boxed in from several directions:

* **No host or LAN exposure** — port 47291 is not published; the container sits
  on an `internal: true` Docker network reachable only by the runner.
* **Server-side tool allowlist** — `server.js` refuses any `X-Claude-Tools`
  grant that isn't one of the two known tool sets, and validates session IDs.
* **Egress allowlist** — all outbound traffic goes through a tinyproxy sidecar
  that only permits Anthropic endpoints (plus Rails docs); a prompt injection
  has no channel to exfiltrate data.
* **API key isolation** — when an API key is configured, the real
  `ANTHROPIC_API_KEY` lives only in the separate `authgw` gateway, which injects
  it into inference requests; the claude container carries just a fixed
  (non-secret) handshake token, so a prompt injection can cause API calls but
  cannot read or exfiltrate the key. (The optional `claude auth login` fallback
  trades this away — OAuth creds then live in the claude container, though the
  egress allowlist still limits where they could go.)
* **Write confinement** — a `PreToolUse` hook (`guard-writes.js`) blocks any
  file mutation outside `/repos`, a second hook (`guard-bash.js`) confines Bash to
  read-only git, and the `.chomper` state dir is additionally mounted **read-only**
  (`/state`), so plans, cached state, and session files can't be tampered with
  even if the hook were bypassed.
* **Container hardening** — read-only rootfs, `cap_drop: ALL`,
  `no-new-privileges`, and no OpenProject/GitHub tokens or Anthropic API key in
  the environment.
* **Human gate** — everything ships as a *draft* PR; review it as untrusted
  code, since WP content can attempt prompt injection.

---

## Interface

### Script mode (terminal-driven)

| Command | What it does |
|---|---|
| `./chomper wp ship <id>...` | Plan → approve → implement → draft PR, per work package. `wp plan` stops at the approved plan, `wp build` at the local commit. Publishes via the contributor bot's fork |
| `./chomper wp pr <id\|url>...` | Refresh a shipped PR: merge in the base branch, fix failing CI, address review feedback, push |
| `./chomper wp pull [<id>...]` | Mirror work packages into the local cache |
| `./chomper chat [message]` | Free read-only chat about the local mirrors |
| `./chomper status` / `reset` | List planned/shipped work packages / wipe `.chomper/` for a fresh start |

Everything keyed on a work-package id lives under `wp` (`./chomper wp` lists the
group); the spec-driven pipeline lives under `pd`.

The `wp ship` / `wp build` / `wp plan` loop prompts `[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`
for each drafted plan; several ids run in turn and one failure doesn't abort the rest.

### Agent mode (comment-driven)

Simply run `./chomper agent`

On a watched **work package** (gated by `CHOMPER_ALLOWED_OP_USER_IDS`):
`@chomper ship` plans and ships in one step (`fix` is a legacy alias),
`@chomper plan` drafts a plan for review, `@chomper approve` ships the drafted
plan. `@chomper grill` stress-tests the ticket or plan (gaps, edge cases,
risks), `@chomper summarize` recaps a long thread — and anything else just
chats.
Setting the chomper user as a WP's **assignee** also triggers the `ship` flow —
once per WP, from any assigner (disable with `CHOMPER_ASSIGN_TRIGGER=0`).

On a chomper-opened **GitHub PR** (gated by `CHOMPER_ALLOWED_GH_USERS`): any
`@chomper` comment gets a reply — and code, when asked — while `@chomper refresh`
runs the full `wp pr` refresh (forced base merge, CI fix, feedback sweep).

---

## Reviewing & pushing

Chomper publishes as a single GitHub **identity**, the **contributor**
(`GITHUB_CONTRIBUTOR_TOKEN`), in every mode:

* A dedicated unprivileged bot account (such as [op-chomper](https://github.com/op-chomper)) with **no access to the canonical repo** — it forks, pushes to the fork, and opens cross-repo draft PRs
* No push ever targets a canonical repo: fork PRs are the only publishing shape, so a maintainer's review and merge is always the gate, and the unattended loops physically cannot land anything upstream
* Discover these PRs via the link chomper posts back on the work package; you still chat with them by commenting `@chomper …` (gh-agent watches the PR), and re-publish a good one under your own account — so secret-gated CI can run — by _adopting_ it (below)

Refreshing an existing PR (`wp pr <id|url>`, `@chomper refresh`) pushes to the PR's
head branch on the bot's fork. A PR whose head lives on the canonical repo (one
you adopted, say) is not chomper's to write to, so its refresh is discarded.

### Adopting a chomper PR

Set up the following alias:

<details>
<summary><code>gh alias set adopt …</code></summary>

```bash
gh alias set adopt '!set -e
v() { gh pr view "$1" --json "$2" -q ".$2"; }
branch="$(v "$1" headRefName)"; base="$(v "$1" baseRefName)"
fork="$(gh pr view "$1" --json headRepositoryOwner,headRepository --template "{{.headRepositoryOwner.login}}/{{.headRepository.name}}")"
git fetch origin "$base"
git fetch "https://github.com/$fork.git" "$branch"
git checkout -B "$branch" FETCH_HEAD
git rebase "origin/$base" -x "git commit --amend --no-edit --reset-author"
git push origin "$branch"
body="$(v "$1" body | sed "s#hxxp://#http://#g; s#hxxps://#https://#g")"
url="$(gh pr create --draft --head "$branch" --base "$base" --title "$(v "$1" title)" --body "$body")"
gh pr comment "$1" --body "Adopted in $url."
echo "New PR (yours): $url"'
```

</details>

Then, from inside your OpenProject repo, run this:

```bash
gh adopt 42        # or paste the PR URL
```

It fetches the branch from the bot's fork, rebases it onto the current base with `--reset-author` so **every commit becomes yours** (author from your local git identity, no capture needed), pushes it to the canonical repo, opens an equivalent draft PR against the same base branch _under your own account_ (so secret-gated CI runs), and comments a link to the new PR on the bot's original (leaving it open so gh-agent keeps tracking it). The adopted PR's body has the work-package link re-fanged (`hxxp://` → `http://`), so **your** PR is the one OpenProject's GitHub integration references on the ticket — the bot's defanged PR never clutters the activity tab. The rebase changes the commits' SHAs — expected, since they become yours — and linearizes any base-merge commits into a clean branch; if a commit collides with the base it pauses for you to resolve. The push is a plain (non-force) create: the fix branch doesn't exist on the canonical repo yet, so a rejection means something unexpected is already there and it stops rather than clobbering it.

---

## Configuration

Everything lives in `.env`, which the first run writes interactively — the table
below is for editing it afterwards. `CLAUDE.md` documents every variable,
including the optional model and CI knobs.

| Variable | Purpose |
|---|---|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token — read work packages, comment on them |
| `ANTHROPIC_API_KEY` | A real key (held by the authgw gateway, never by the claude container), or the literal `oauth` to log in with `claude auth login` instead |
| `GITHUB_CONTRIBUTOR_TOKEN` | The bot account's classic token (`public_repo`, `workflow`, `gist`) — chomper's only identity |
| `CHOMPER_ALLOWED_OP_USER_IDS` | OpenProject user ids allowed to trigger `@chomper` (comma-separated). Empty = anyone |
| `CHOMPER_ALLOWED_GH_USERS` | GitHub logins allowed to trigger `gh-agent` (comma-separated). Empty also disables upstream-PR review |

State lives in `.chomper/` (gitignored) and is safe to delete with
`./chomper reset`:

| Path | What's in it |
|---|---|
| `work_packages/<host>/<id>/` | Per-work-package mirror: `item.json`, `plan.md`, `pr.md`, `pr_url.txt`, session ids |
| `work_packages/<host>/op_agent_filters.json` | The saved search filters, written on the first `op-agent` run |
| `pr_reviews/<owner>-<repo>/<number>/` | Review state for an upstream PR chomper didn't open |
| `openspec/<repo>/`, `changes/<host>/<id>/` | The `pd` pipeline's canonical spec store and per-change state |
| `repos/<name>/` | Each product repo's standalone clone, mounted into the claude container |
| `chomp.log`, `progress.txt` | Full prompt/response log; pipe-delimited audit log |

---

## Development

The test suite runs inside the runner container so the Ruby version and gem environment match production exactly.

**Run all tests:**

```bash
docker compose run --no-deps --rm runner bundle exec rake
```

**Run a single file:**

```bash
docker compose run --no-deps --rm runner bundle exec ruby -Itest test/chomper/agent_test.rb
```

**After changing `Gemfile`**, regenerate the lockfile and rebuild the image:

```bash
docker compose run --no-deps --rm runner bundle lock
docker compose build runner
```

The suite uses Minitest (ships with Ruby) and WebMock for HTTP stubs. No network calls are made during the test run.

---

## TODO

### Security & Hosting
* Separate Claude API credit account
* (?) Permission to read OP user emails

### AI Architecture
* Plug in our OpenRouter key
* Add intent classification interface:
  * user issues a free-text prompt ("generate a PR pls") → a light model converts it to a "build" command
* Consolidate the project with AI stream: local WP JSON mirrors could be replaced with the MCP
* Set up token limits & cleanly handle threshold breaches
* Migrate from `claude -p` to a Claude SDK
* Replace Claude Code with a generic AI "file edit engine" layer
  * The LLM container should run something like `LiteLLM` or `OpenCode`, so that we can configure any model we like, commercial or open.
  * The infra is ready for this, we can just replace the chomper-claude container with some other thing that listens on HTTP :47291
* Replace Claude!
  * We can likely save a lot on costs by switching to Codex.
  * Or, lean away from US by switching to Mistral.
  * Or, **ideally**, plug in an open model.
* Centralize our skill and agent definitions into another OP repo, so that Chomper may leverage them
  * Good candidate: https://github.com/opf/openproject-agent-skills
* Use separate agents for development and review to clearly split domain ownership
* Try to compact token usage
  * Inspiration: https://andrewpatterson.dev/posts/token-savings-rtk-headroom/

### Feature ideas
* Agent forking workflow:
  * More universal `adopt` alias that does not require `gh`
  * Port the `adopt` alias to a script in a trusted repo inside the `opf` org (e.g. a `gh` extension), so maintainers install it from a first-party source rather than pasting an inline alias
* Lean more into the dev console "toolbox" interface
  * for new WPs: `chat` (-> `plan`) -> `build` -> `release`
    * more chat lenses beyond grill/summarize: simplify, options, explain, test-plan, impact
    * also add option to include the sub-WPs
* Make the interface more intuitive; The mix of hardcoded commands and free-form chatting confuses people
* AppSignal integration
  * [by implication] Ticket creation workflow
  * Currently tricky, as we don't want to share user data with a 3rd party LLM
* Make the agent mode work off webhooks instead of constant polling
* Update the WP while work is being done: transition to "in development", add release, etc.
  * Or, just set it manually for now. Or, explicitly prompt for it (when setting up new search filter query)
* Consider running actual tests -- tricky, as they'd need to be run via the `docker compose` stack on the host system
  * There _are_ ways of giving the runner container access to Docker via a shared socket. However, this breaks the sandbox model, as it escalates the runner's permissions to run/access any containers on the host system.
  * Or just run chomper in the same local network as the docker stack, then trigger commands via a HTTP API slapped into the main OP container
* Idea: Use sub-WPs for any Chomper interactions in agent mode
