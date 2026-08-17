<div align="center">

<img width="100" height="100" alt="opilot" src="https://github.com/user-attachments/assets/1a0383fb-7c98-4cea-b3b6-8c8ef638f9b6" />

# OPilot

**Your friendly neighborhood OpenProject software development agent**

⚠️ _Proof of concept — use at your own risk!_

</div>

## What is this?

AI tools help us design and implement faster. Nevertheless, outside that creative process, there is still some inevitable legwork: checking out branches, running local AI coding assistants by hand, and managing pull requests.

Use OPilot to remove that friction from your development workflow. It can automate anything from simple bug-fixing to entire E2E product delivery. Just chat with `@OPilot` in OpenProject and GitHub PRs!

* **Work package refinement**: Discuss & refine work packages via `@OPilot grill` & free-form chatting
* **Prototyping**: Generate auto-correcting code prototypes via `@OPilot build`. Refine the code by chatting with [OPilot Bot](https://github.com/op-chomper) within the PR.
  * **Human take-over**: Run `gh adopt <pr-id>` to make the prototype your own, thus cleanly transferring ownership
* **General PR assistance**: Tag `@OPilot` in any upstream PR with questions.
* **Product development**: Use the experimental `pd` product development pipeline to automatically deliver entire features end-to-end, using OpenProject as the work tracking backend.

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
- [OpenRouter](https://openrouter.ai/keys) API key — held only by the `authgw` container, never by the one running untrusted work-package content
- GitHub auth token tied to a permission-less contributor account (we currently use [op-opilot](https://github.com/op-opilot))
- Project-scoped OpenProject API token (read/write for the product development pipeline, or just read-only for the rest)

---

## Quick start

### Setup
```bash
git clone https://github.com/opf/opilot
cd opilot
# Create .env based on .env.example OR just leave it to the first startup wizard
```

### Agent mode
```bash
# Run the agent: it scans for new activity on OpenProject WPs + its own GitHub PRs and acts on @opilot mentions
./opilot agent
```

### Script mode
```bash
# Run one-time E2E fix of one or more specific WPs
./opilot wp ship <id>...
# OR just draft (and approve) a plan without building
./opilot wp plan <id>...
# OR refresh a stale shipped PR (merge base, fix CI, address comments)
./opilot wp pr <id-or-pr-url>...
# and more — ./opilot wp lists the group
```

## Bird's-eye view

```
           ┌─────────────────┐
           │ ./opilot        │
           │ (shell wrapper) │
           └────────┬────────┘
                    │
                    │ docker compose run
                    │
┌── Docker ─────────┼─────────────────────────────────────────────────────────────────────────┐
│                   ▼                                                                         │
│ ┌─ runner container ────────────────┐            ┌─ harness container ────────────────────┐ │
│ │                                   │            │                                        │ │
│ │ Ruby 4.0 script                   │            │ Node.js server (:47291)                │ │
│ │  * Pulls WP content from OP API   │◀── json ──▶│   POST / -> `pi --mode json`           │ │
│ │  * Manages metadata in .opilot/   │            │ volumes: .opilot/                      │ │
│ │      * WP metadata mirror         │            │                                        │ │
│ │      * Plan files                 │            │                                        │ │
│ │      * Draft PR data              │            └─────────┬─────────────────────┬────────┘ │
│ │  * Pushes branches, opens PRs     │                      │                     │          │
│ │  * Delegates chat to the LLM      │                      │                     │          │
│ └───────┬──────────────────┬────────┘                      ▼                     ▼          │
│         │                  │                     ┌─ proxy ───────────┐ ┌─ authgw ─────────┐ │
│         │                  │                     │ tinyproxy (:8888) │ │ replaces gateway │ │
│         │                  │                     │ egress allowlist  │ │ token = real key │ │
│         │                  │                     └─────────┬─────────┘ └─────────┬────────┘ │
│         │                  │                               │                     │          │
└─────────┼──────────────────┼───────────────────────────────┼─────────────────────┼──────────┘
          ▼                  ▼                               ▼                     ▼
    ┌──────────┐      ┌────────────┐                  ┌─────────────┐      ┌───────────────┐
    │ OP API   │      │ GitHub API │                  │ Rails docs  │      │ openrouter.ai │
    └──────────┘      └────────────┘                  │ (allowlist) │      │ (any model)   │
                                                      └─────────────┘      └───────────────┘
```

### Security model

The harness container processes untrusted text (work package descriptions and
comments), so it is boxed in from several directions:

* **No host or LAN exposure** — port 47291 stays unpublished. The container
  sits on an internal Docker network reachable only by the runner.
* **Server-side tool allowlist** — `server.js` accepts only two known
  `X-Harness-Tools` grants, and validates every session ID.
* **Egress allowlist** — model calls go straight to `authgw`. All other
  traffic passes through a tinyproxy allowlist (Rails docs only). A prompt
  injection has no path to send data out.
* **API key isolation** — the real `OPENROUTER_API_KEY` stays in the `authgw`
  gateway. The harness container holds only a fixed, non-secret handshake
  token. A prompt injection can trigger API calls but cannot read the key.
* **Write confinement** — `pi-guards.ts` blocks file writes outside `/repos`
  and allows only read-only git in Bash. The `.opilot` state dir is also
  mounted read-only, so plans and session files stay safe even if the guard
  fails.
* **Container hardening** — read-only rootfs, `cap_drop: ALL`,
  `no-new-privileges`. No OpenProject token, GitHub token, or OpenRouter key
  is present in the environment.
* **Human gate** — everything ships as a *draft* PR. Review it as untrusted
  code — WP content can attempt prompt injection.

---

## Interface

### Script mode (terminal-driven)

| Command | What it does |
|---|---|
| `./opilot wp ship <id>...` | Plan → approve → implement → draft PR, per work package. `wp plan` stops at the approved plan, `wp build` at the local commit. Publishes via the contributor bot's fork |
| `./opilot wp pr <id\|url>...` | Refresh a shipped PR: merge in the base branch, fix failing CI, address review feedback, push |
| `./opilot wp pull [<id>...]` | Mirror work packages into the local cache |
| `./opilot chat [message]` | Free read-only chat about the local mirrors |
| `./opilot status` / `reset` | List planned/shipped work packages / wipe `.opilot/` for a fresh start |
| `./opilot usage` | OpenRouter spend: account balance, this key's usage/limit, and pricing for the configured models |

Everything keyed on a work-package id lives under `wp` (`./opilot wp` lists the
group); the spec-driven pipeline lives under `pd`.

The `wp ship` / `wp build` / `wp plan` loop prompts `[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`
for each drafted plan; several ids run in turn and one failure doesn't abort the rest.

### Agent mode (comment-driven)

Simply run `./opilot agent`

On a watched **work package** (gated by `OPILOT_ALLOWED_OP_USER_IDS`):
`@opilot build` plans and ships in one step. `@opilot grill` stress-tests the
ticket or plan. `@opilot summarize` recaps a long thread. Any other comment
just chats. Naming opilot in a WP's **Developers** field also triggers
`build`, once per WP, from any user. Set `OPILOT_DEVELOPER_TRIGGER=0` to
disable this, or `OPILOT_DEVELOPER_FIELD` to use a different field.

When a fix has more than one defensible shape, `build` **offers options
first**: two or three numbered one-liners, with no code until someone replies
`@opilot build <number>`. Extra words after the number become direction for
that option. A single-shape fix, or a reply with free-text direction (`@opilot
build use a toast instead`), skips straight to shipping. `./opilot wp ship`
offers the same options at the console.

Once the prototype is open, review happens on the pull request. Ask for
changes there, and opilot reads the comments and pushes. A later `@opilot
build` on a shipped work package just answers with the link.

On an opilot-opened **GitHub PR** (gated by `OPILOT_ALLOWED_GH_USERS`): any
`@opilot` comment gets a reply, and code when asked. `@opilot refresh` runs
the full `wp pr` refresh — forced base merge, CI fix, feedback sweep. Opilot
picks up failing CI on its own.

Set `OPILOT_TRACK_UPSTREAM_PRS=1` to also track the product repos' **upstream**
PRs: opilot has no write access there, so it replies in text and offers
applicable changes as one-click GitHub suggestions. Off by default — the only way
opilot looks outside its own PRs.

### Product development (`pd`)

A separate, spec-driven pipeline: OpenProject **Documents** → an
[OpenSpec](https://github.com/Fission-AI/OpenSpec) change proposal reviewed as a PR
→ generated work packages → one implementation PR per work package.

```bash
./opilot pd init <project-id>                    # resolve ids, seed the spec store
./opilot pd intake <project-id> <change-id>      # documents (+ attachments) → intake/
./opilot pd propose <change-id>                  # proposal + the spec PR that gates it
./opilot pd generate-wp <change-id>              # one parent + a child per tasks.md section
./opilot pd implement <wp-id>...                 # build one work package from its spec
```

The spec PR **is** the approval gate: nothing is written to OpenProject until you run
`generate-wp`, which is why that step needs a token with add-work-packages rights.
`./opilot pd` lists the commands; CLAUDE.md carries the full design.

---

## Reviewing & pushing

OPilot publishes as a single GitHub **identity**, the **contributor**
(`GITHUB_CONTRIBUTOR_TOKEN`), in every mode:

* A dedicated unprivileged bot account (such as [op-opilot](https://github.com/op-opilot)), with **no access to the canonical repo**. It forks, pushes to the fork, and opens cross-repo draft PRs
* No push ever targets a canonical repo. Fork PRs are the only publishing shape, so a maintainer's review and merge is always the gate — the unattended loops cannot land code upstream on their own
* Find these PRs from the link opilot posts on the work package. Comment `@opilot …` to keep chatting — gh-agent watches the PR. To run secret-gated CI, _adopt_ a good PR under your own account (below)

Refreshing an existing PR (`wp pr <id|url>`, `@opilot refresh`) pushes to the PR's
head branch on the bot's fork. A PR whose head lives on the canonical repo (one
you adopted, say) is not opilot's to write to, so its refresh is discarded.

### Adopting an opilot PR

Set up the following alias:

<details>
<summary><code>gh alias set adopt …</code></summary>

```bash
gh alias set adopt '!set -e
v() { gh pr view "$1" --json "$2" -q ".$2"; }
branch="$(v "$1" headRefName)"; base="$(v "$1" baseRefName)"; num="$(v "$1" number)"
fork="$(gh pr view "$1" --json headRepositoryOwner,headRepository --template "{{.headRepositoryOwner.login}}/{{.headRepository.name}}")"
git fetch origin "$base"
git fetch "https://github.com/$fork.git" "$branch"
git checkout -B "$branch" FETCH_HEAD
git rebase "origin/$base" -x "git commit --amend --no-edit --reset-author"
git push origin "$branch"
body="$(v "$1" body | sed "/<!-- opilot:banner -->/,/<!-- \/opilot:banner -->/d; s#hxxp://#http://#g; s#hxxps://#https://#g")"
body="Adapted from #$num.
$body"
url="$(gh pr create --draft --head "$branch" --base "$base" --title "$(v "$1" title)" --body "$body")"
gh pr comment "$1" --body "Adopted in $url."
echo "New PR (yours): $url"'
```

</details>

Then, from inside your OpenProject repo, run this:

```bash
gh adopt 42        # or paste the PR URL
```

It does the following:
* Refreshes the code branch from upstream
* Rewrites commit ownership to **you**
* Pushes a new branch to the upstream repo
* Opens a draft PR for the new branch.

The opilot agent will pick up on this and close its PR, pointing to yours.

---

## Configuration

Everything lives in `.env`, which the first run writes interactively — the table
below is for editing it afterwards, and `.env.example` carries the same set with
fuller comments. `CLAUDE.md` documents each one's rationale.

| Variable | Purpose |
|---|---|
| `OPENPROJECT_URL` | OpenProject instance URL |
| `OPENPROJECT_TOKEN` | API token — read work packages, comment on them |
| `OPENROUTER_API_KEY` | Required. Held by the authgw gateway, never by the harness container |
| `GITHUB_CONTRIBUTOR_TOKEN` | The bot account's classic token (`public_repo`, `workflow`, `gist`) — opilot's only identity |
| `OP_REPO_PATH` | Optional. A local openproject checkout to seed that clone from, for a faster first clone |
| `OPILOT_ALLOWED_OP_USER_IDS` | OpenProject user ids allowed to trigger `@opilot` (comma-separated). Empty = anyone |
| `OPILOT_ALLOWED_GH_USERS` | GitHub logins allowed to trigger `gh-agent` (comma-separated). Empty = any GitHub user, on opilot's own PRs |
| `OPILOT_TRACK_UPSTREAM_PRS` | `1` to also track the product repos' upstream PRs, so an `@opilot` mention on one gets answered (read-only). Off by default; needs the allowlist too |

### Repos

The product repos are the committed registry in `repos.json` — each with a `name`,
its `upstream` owner/repo, the `base` branch PRs target, and a description the LLM
reads. There is no per-repo setup beyond that: `./opilot` clones each one into
`.opilot/repos/<name>` on first use.

A fix is not tied to one repo. The LLM declares its targets on the first line of the
plan (`REPOS: openproject, primer_view_components`), and opilot then ships an
independent branch and PR to each repo that actually changed. `REPOS:
openproject@release/17.6` targets a non-default base branch, for a backport.

State lives in `.opilot/` (gitignored) and is safe to delete with
`./opilot reset`:

| Path | What's in it |
|---|---|
| `work_packages/<host>/<id>/` | Per-work-package mirror: `item.json`, `plan.md`, `pr.md`, `pr_url.txt`, session ids |
| `work_packages/<host>/op_agent_filters.json` | The saved search filters, written on the first `agent op` run |
| `pr_reviews/<owner>-<repo>/<number>/` | Review state for an upstream PR opilot didn't open |
| `openspec/<repo>/`, `changes/<host>/<id>/` | The `pd` pipeline's canonical spec store and per-change state |
| `repos/<name>/` | Each product repo's standalone clone, mounted into the harness container |
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
docker compose run --no-deps --rm runner bundle exec ruby -Itest test/opilot/agent_test.rb
```

**After changing `Gemfile`**, regenerate the lockfile and rebuild the image:

```bash
docker compose run --no-deps --rm runner bundle lock
docker compose build runner
```

The suite uses Minitest (ships with Ruby) and WebMock for HTTP stubs. No network calls are made during the test run.

CI (`.github/workflows/test.yml`) runs the same suite in a bare `ruby:4.0-slim` rather than `Dockerfile.runner`, so it has no `openspec` CLI — the tests that would shell out to it stub `Open3` instead.

---

## TODO

### Productization
* Wire the agent into our Compose stack!
  * either via an override file or a separate branch/fork
* Make use of the MCP server
  * Use MCP calls instead of (or additionally to) the local JSON WP mirrors
* Make use of our own LLM
  * We probably need to be able to fetch settings from the OP instance
* Introduce proper UI!
  * AI chat noise deflected from the main activity comments
  * LLM working/typing indicator using HocusPocus
* Make the agent work off webhooks instead of constant polling

### Security & Hosting
* Switch from Docker to Podman for root-less process model

### AI Architecture
* Set up token limits & cleanly handle threshold breaches
* Centralize our skill and agent definitions into another OP repo, so that OPilot may leverage them
  * Good candidate: https://github.com/opf/openproject-agent-skills
* Use more clear split between agent "personas" -- reviewer, developer etc.
* Try to compact token usage
  * Inspiration: https://andrewpatterson.dev/posts/token-savings-rtk-headroom/

### Feature ideas
* Generate arbitrary non-code artifacts like SVGs or stylesheets
  * For now, at least gists could be good enough for basic text reports
* Add a diagram that maps OPilot commands to complete product development flow (waterfall-ish)
* Adoption workflow:
  * More universal `adopt` alias that does not require `gh`?
  * Port the `adopt` alias to a script in a trusted repo inside the `opf` org (e.g. a `gh` extension), so maintainers install it from a first-party source rather than pasting an inline alias
* AppSignal integration — ingesting the errors is the open half; ticket creation itself now exists (`pd generate-wp`)
  * Currently tricky, as we don't want to share user data with a 3rd party LLM
* Consider running actual tests -- tricky, as they'd need to be run via the `docker compose` stack on the host system
  * There _are_ ways of giving the runner container access to Docker via a shared socket. However, this breaks the sandbox model, as it escalates the runner's permissions to run/access any containers on the host system.
  * Or just run OPilot in the same local network as the docker stack, then trigger commands via a HTTP API slapped into the main OP container
* Idea: Use sub-WPs for any OPilot interactions in agent mode
* Intent classification interface?
  * user issues a free-text prompt ("generate a PR pls") → a light model converts it to a "build" command
