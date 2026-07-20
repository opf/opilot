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
- [Development](#development)
- [TODO](#todo)

---

## Requirements

- **Docker**
- GitHub auth token
  - Core `opf` org PRs: OpenProject member token
  - Outside contributor PRs: Any GitHub user (we currently use [op-chomper](https://github.com/op-chomper))
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
./chomper ship <id>...
# OR just draft (and approve) a plan without building
./chomper plan <id>...
# OR refresh a stale shipped PR (merge base, fix CI, address comments)
./chomper pr <id-or-pr-url>...
# and more
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
| `./chomper ship <id>...` | Plan → approve → implement → draft PR, per work package. `plan` stops at the approved plan, `build` at the local commit. Publishes via the contributor bot's fork; with `GITHUB_MAINTAINER_TOKEN` set, directly as the maintainer (each push confirmed) |
| `./chomper pr <id\|url>...` | Refresh a shipped PR: merge in the base branch, fix failing CI, address review feedback, push |
| `./chomper pull [<id>...]` | Mirror work packages into the local cache |
| `./chomper chat [message]` | Free read-only chat about the local mirrors |
| `./chomper status` / `reset` | List planned/shipped work packages / wipe `.chomper/` for a fresh start |

The `ship` / `build` / `plan` loop prompts `[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`
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
runs the full `pr`-command refresh (forced base merge, CI fix, feedback sweep).

---

## Reviewing & pushing

Chomper publishes as one of two GitHub **identities** — the command determines
which one acts, the identity determines the publishing shape, and an existing
PR determines its own push target:

* **Contributor** (`GITHUB_CONTRIBUTOR_TOKEN`)
  * A dedicated unprivileged bot account (such as [op-chomper](https://github.com/op-chomper)) with **no access to the canonical repo** — it forks, pushes to the fork, and opens the draft PR **on the fork itself** (against the fork's own base branch, kept synced with upstream), so it never clutters the canonical repo's PR queue
  * The **only** identity Agent mode uses: the loops run unattended, and the bot physically cannot push to the canonical repo
  * Also used by `ship` when no maintainer token is configured
  * Discover these PRs via the link chomper posts back on the work package; you still chat with them by commenting `@chomper …` (gh-agent watches the fork PR), and promote a good one to a real upstream PR by _adopting_ it (below)
* **Maintainer** (`GITHUB_MAINTAINER_TOKEN`)
  * Your own account, with push access to the canonical repo
  * Used by script mode (`ship` / `pr`) whenever it is configured: pushes the fix branch straight to the canonical repo and opens a same-repo draft PR
  * Every push to a canonical repo is confirmed interactively — no flag or env var bypasses that
  * Optional: without it, `ship` publishes via the contributor bot's fork instead.

Refreshing an existing PR (`pr <id|url>`, `@chomper refresh`) needs no choice:
the push goes to the PR's head repo with whichever identity owns it.

### Adopting a chomper PR

Set up the following alias:

<details>
<summary><code>gh alias set adopt …</code></summary>

```bash
gh alias set adopt '!set -e; pr="$1"
v() { gh pr view "$pr" --json "$1" -q ".$1"; }
branch="$(v headRefName)"
fork="$(gh pr view "$pr" --json headRepositoryOwner,headRepository -q "\(.headRepositoryOwner.login)/\(.headRepository.name)")"
git fetch "https://github.com/$fork.git" "$branch"
git push origin "FETCH_HEAD:refs/heads/$branch"
url="$(gh pr create --draft --head "$branch" \
  --base "$(v baseRefName)" --title "$(v title)" --body "$(v body)")"
gh pr close "$pr" --comment "Adopted in $url."
echo "Old PR (closed): $(v url)"
echo "New PR (yours):  $url"'
```

</details>

The bot's PR lives on its **fork**, so pass its **URL** (a bare number would resolve against your own repo, where the PR isn't). Run this from inside your OpenProject repo:

```bash
gh adopt https://github.com/op-chomper/openproject/pull/42
```

It fetches the branch from the bot's fork, pushes it to the canonical repo, opens an equivalent draft PR against the same base branch _under your own account_ (so secret-gated CI runs), and closes the bot's fork PR.

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
  * Rewrite commit author (and squash?)
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
