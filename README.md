## Proof of Concept -- use at your own risk!

# openproject-chomper

An OpenProject AI development orchestrator that helps you implement work packages, end to end.

**Agent mode**: Assists you inside both WP Activity tabs and GitHub PRs. Just tag `@chomper` to ask questions, plan together, and even generate PRs.

**Script mode**: Plans & implements WPs entirely via your terminal. Point it to one or more specific packages by ID.

<img width="817" height="597" alt="Screenshot 2026-06-16 at 15 15 26" src="https://github.com/user-attachments/assets/706ddeb1-df10-485d-af48-8821135eafda" />

---

## Table of Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Bird's-eye view](#birds-eye-view)
- [Commands](#commands)
- [Reviewing & pushing](#reviewing--pushing)
- [Repo layout](#repo-layout)
- [Environment variables](#environment-variables)
- [Development](#development)
- [TODO](#todo)

---

## Requirements

- **Docker**
- A GitHub token with repo write access (for opening PRs)
- An OpenProject API token (read-only for script mode, comment-writable for agent mode)

---

## Quick start

```bash
git clone https://github.com/opf/openproject-chomper
cd openproject-chomper
# Create .env based on .env.example OR just leave it to the first startup wizard

# Run the agent: it scans for new activity on OpenProject WPs + its own GitHub PRs and acts on @chomper mentions
./chomper agent
# OR run a one-time E2E fix of one or more specific WPs
./chomper fix <id>...
# OR just draft (and approve) a plan without shipping
./chomper plan <id>...
```

## Bird's-eye view

```
              ┌─────────────────┐
              │    ./chomper    │
              │ (shell wrapper) │
              └─────────────────┘
                       │
                       │ docker compose exec
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

## Commands

| Invocation | Behaviour |
|---|---|
| `./chomper agent` | Run `op-agent` and `gh-agent` together in one loop (polls PRs first, then work packages). Falls back to `op-agent` only when `GITHUB_TOKEN` is unset |
| `./chomper op-agent` | Poll OpenProject every 10s and act on `@chomper` mentions |
| `./chomper gh-agent` | Poll chomper's open PRs every 10s; reply to `@chomper` comments and, when asked, push code to the bot's fork |
| `./chomper fix <id>...` | Plan and ship one or more work packages by id, with a terminal approval loop (each id runs in turn; one failure doesn't abort the rest) |
| `./chomper plan <id>...` | Plan-only counterpart of `fix`: same loop, but stops once each plan is approved instead of shipping |
| `./chomper pull [<id>...]` | Mirror work packages into the local cache for later `chat`, without planning or shipping. Ids fetch exactly those; no ids runs the filter wizard for a bulk grab |
| `./chomper chat [message]` | Free read-only chat about your local mirrors (items + PRs); no fetch, plan, or ship |
| `./chomper status` | List the work packages chomper has planned or shipped |
| `./chomper reset` | Delete `.chomper/` — clones included — for a fresh start |
| `./chomper --help` | Show usage |

### `./chomper fix` / `./chomper plan` flow

`fix <id>...` fetches one or more work packages by id (ignoring any saved filters) and, for each in turn, streams an implementation plan and prompts:

`[y]es implement / [s]kip / [d]rop / [c]hat / [r]e-plan`
- **y** — implement, commit, and open a draft PR (same as `@chomper fix`)
- **s** — skip this WP and move on
- **d** — drop this WP, discarding the drafted plan
- **c** — open a chat session to ask questions before deciding; chat alone never changes the saved plan
- **r** — rewrite `plan.md` from feedback you type, or — left empty — from the changes discussed in the preceding chat

With several ids each runs in turn and one failure (a bad id, a Claude error) doesn't abort the rest. A WP already shipped (`pr_url.txt` present) is reported and passed over.

`plan <id>...` is the plan-only counterpart: the same loop, but `[y]` accepts the plan and stops without shipping. Ship it later with `fix <id>`.

### `@chomper` comment commands

While the agent runs, drive it by mentioning `@chomper` in a comment on any watched work package:

| Comment | Behaviour |
|---|---|
| `@chomper fix [feedback]` | Plan and ship in one step — the right choice for most tasks |
| `@chomper plan [feedback]` | For complex tasks: draft a plan for human review before touching any code (optional feedback revises an existing plan) |
| `@chomper approve` | Implement and ship a plan that was drafted with `@chomper plan` |
| `@chomper <anything else>` | Chat — replies using the current plan as context, no state change |

Triggers are gated by the `CHOMPER_ALLOWED_OP_USER_IDS` allowlist (when set). A work
package's status is just the files in `.chomper/work_packages/<host>/<id>/`:
`plan.md` present means it has a plan, `pr_url.txt` present means it shipped.

---

## Reviewing & pushing

`@chomper approve` (and `@chomper fix`) push the branch and open a **draft** PR in
one step, posting the PR link back to the work package. This is idempotent — if a
PR already exists for the branch, the existing URL is reported instead of opening
a new one, and re-sending `approve` after a shipped fix just re-reports it.

`./chomper status` lists each watched work package with its OpenProject link and
PR link so you can see what's been planned and shipped at a glance.

---

## Repo layout

`chomper` is the bash entry point (Docker setup); `bin/chomper` is the Ruby CLI
that runs inside the runner container; `server.js` wraps `claude -p` in the
claude container. The agent itself lives in `lib/chomper/` — one module per
concern (`pull.rb`, `agent.rb`, `gh_agent.rb`, `fix_runner.rb`, `publish.rb`,
`prompts.rb`, `clients/`, …), with matching tests under `test/chomper/`.

See **CLAUDE.md** for the authoritative module-by-module breakdown and the full
`.chomper/` runtime-state layout (both kept in sync with the code there).

---

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `OPENPROJECT_URL` | — | URL of your OpenProject instance |
| `OPENPROJECT_TOKEN` | — | OpenProject API token (My Account → Access Tokens); needs WP read access plus comment write — chomper posts replies and 👀 reactions |
| `ANTHROPIC_API_KEY` | — | Recommended. When set, held only by the `authgw` gateway (injected into Anthropic requests), never passed to the claude container. If unset, chomper falls back to interactive `claude auth login` — OAuth creds then live in the claude container (less isolated). The setup wizard prompts for it (blank = use login). |
| `GITHUB_TOKEN` | — | Used to push branches and open PRs via the GitHub API |
| `CHOMPER_ALLOWED_OP_USER_IDS` | — | Comma-separated OpenProject user ids allowed to trigger the agent via `@chomper` comments (the number in a profile URL, `/users/<id>` — not emails, since a non-admin API token can't read other users' emails). The setup wizard prompts for this; it is **required when targeting the public community instance** (otherwise anyone on the internet could trigger the agent), and leaving it empty elsewhere needs explicit confirmation. |

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
* Make the interface more intuitive; The mix of hardcoded commands and free-form chatting confuses people
* Use temporal PRs that are meant to be over-taken by an actual dev
* AppSignal integration
  * [by implication] Ticket creation workflow
  * Currently tricky, as we don't want to share user data with a 3rd party LLM
* Trigger agent interaction by assigning a WP to the chomper user
* Make the agent mode work off webhooks instead of constant polling
* Update the WP while work is being done: transition to "in development", add release, etc.
  * Or, just set it manually for now. Or, explicitly prompt for it (when setting up new search filter query)
* Consider running actual tests -- tricky, as they'd need to be run via the `docker compose` stack on the host system
  * There _are_ ways of giving the runner container access to Docker via a shared socket. However, this breaks the sandbox model, as it escalates the runner's permissions to run/access any containers on the host system.
* Idea: Use sub-WPs for any Chomper interactions in agent mode
