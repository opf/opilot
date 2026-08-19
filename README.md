<div align="center">

<img width="100" height="100" alt="opilot" src="https://github.com/user-attachments/assets/1a0383fb-7c98-4cea-b3b6-8c8ef638f9b6" />

# OPilot

**Your friendly neighborhood OpenProject agent**

⚠️ _EXPERIMENTAL PROOF OF CONCEPT — use at your own risk!_

</div>

## What is this?

A standalone & secure "OpenProject copilot" that uses the [`pi` agent harness](https://pi.dev/) to automate various tasks. 

Chat with it throughout the OpenProject interface and let it work in the background!

## Who is this for?


### Software developers

AI tools help us design and implement faster. Nevertheless, outside that creative process, there is still some inevitable legwork: checking out branches, running local AI coding assistants by hand, and managing pull requests.

Use OPilot to remove that friction from your development workflow. It can automate anything from simple bug-fixing to entire E2E product delivery. Just chat with `@OPilot` in OpenProject and GitHub PRs!

* **Prototyping**: Generate auto-correcting code prototypes via `@OPilot build`. Refine the code by chatting with [OPilot Bot](https://github.com/op-opilot) within the PR.
  * **Human take-over**: Run `gh adopt <pr-id>` to make the prototype your own, thus cleanly transferring ownership
* **General PR assistance**: Tag `@OPilot` in any upstream PR with questions.
* **Product development**: Use the experimental `pd` product development pipeline to automatically deliver entire features end-to-end, using OpenProject as the work tracking backend.

### General audience


* **Free-form work package refinement**: Discuss work packages in the chat via free-form chatting or preset commands like `@OPilot grill`.

### ...and others?

---

## Table of Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Bird's-eye view](#birds-eye-view)
- [Interface](#interface)
- [Reviewing & pushing](#reviewing--pushing)
- [Configuration](#configuration)
- [Development](#development)
- [TODO](TODO.md)

---

## Requirements

- **Docker**
- An inference endpoint: an [OpenRouter](https://openrouter.ai/keys) API key, or
  your own OpenAI-compatible server (see [Models](#models))
- GitHub auth token tied to a permission-less contributor account (we currently use [op-opilot](https://github.com/op-opilot))
- Project-scoped OpenProject API token

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
┌── Docker ─────────┼───────────────────────────────────────────────────────────────────┐
│                   ▼                                                                   │
│ ┌─ runner container ────────────────┐        ┌─ harness container ────────────────┐   │
│ │                                   │        │                                    │   │
│ │ Ruby 4.0 script                   │  json  │ Node.js server (:47291)            │   │
│ │  * Pulls WP content from OP API   │◀──────▶│   POST / -> `pi --mode json`       │   │
│ │  * Manages metadata in .opilot/   │        │ volumes: .opilot/                  │   │
│ │      * WP metadata mirror         │        │                                    │   │
│ │      * Plan files                 │        │                                    │   │
│ │      * Draft PR data              │        └───────────────────┬────────────────┘   │
│ │  * Pushes branches, opens PRs     │                            │                    │
│ │  * Delegates chat to the LLM      │                            │                    │
│ └───────┬──────────────────┬────────┘                            ▼                    │
│         │                  │                          ┌─ authgw ──────────────┐       │
│         │                  │                          │ * attach real API key │       │
│         │                  │                          │ * limit access to     │       │
│         │                  │                          │   inference API-only  │       │
│         │                  │                          │                       │       │
│         │                  │                          └───────────┬───────────┘       │
│         │                  │                                      │                   │
└─────────┼──────────────────┼──────────────────────────────────────┼───────────────────┘
          ▼                  ▼                                      ▼
  ┌─────────────────┐  ┌────────────┐                     ┌───────────────────────┐
  │ OpenProject API │  │ GitHub API │                     │ Inference API:        │   
  └─────────────────┘  └────────────┘                     │ OpenRouter, or your   │
                                                          │ own OpenAI-compatible │
                                                          │ endpoint              │
                                                          └───────────────────────┘
```

The harness has **no other way out**. It sits on an internal Docker network
with no default route, so authgw — one pinned upstream, one small set of
allowed paths — is its entire egress.

### Security model

The harness container processes untrusted text (work package descriptions and
comments), so it is locked down: no host/LAN exposure, **no network egress at
all except authgw**, an isolated API key, writes confined to `/repos` (and
never into a `.git/` directory), Bash confined to read-only git, resource caps,
a hardened container, and everything ships only as a *draft* PR for human
review.

authgw is the whole of that egress. It holds the key, forwards to one fixed
upstream at an address pinned at boot, and allows only the inference paths — so
a prompt injection has nowhere to send anything, even when the upstream needs
no key at all. See `CLAUDE.md` for the full model.

**One channel this does not close.** The harness cannot reach the network, but
its *output* becomes the PR description and the work-package comments that the
runner publishes to GitHub. A crafted work package can ask for repository
contents to be quoted there, and no egress from the harness is needed for that
to work. Draft status, the bot-only account and human review are what stand in
the way today. Treat a public prototype PR as something a human reads before it
matters, and do not point opilot at repositories whose contents you could not
tolerate in a draft PR body.

---

## Interface

### Script mode (terminal-driven)

| Command | What it does |
|---|---|
| `./opilot wp ship <id>...` | Plan → approve → implement → draft PR, per work package. `wp plan` stops at the approved plan, `wp build` at the local commit. Publishes via the contributor bot's fork |
| `./opilot wp pr <id\|url>...` | Refresh a shipped PR: merge in the base branch, fix failing CI, address review feedback, push |
| `./opilot wp pull <id>...` | Mirror work packages into the local cache |
| `./opilot chat [message]` | Free read-only chat about the local mirrors |
| `./opilot status` / `reset` | List planned/shipped work packages / wipe `.opilot/` for a fresh start |
| `./opilot usage` | On OpenRouter: account balance, this key's usage/limit, and pricing for the configured models. On a self-hosted upstream: the endpoint and models in use — there is no spend to report |

Everything keyed on a work-package id lives under `wp` (`./opilot wp` lists the
group); the spec-driven pipeline lives under `pd`.

The `wp ship` / `wp build` / `wp plan` loop prompts `[y]es / [s]kip / [d]rop / [c]hat / [r]e-plan`
for each drafted plan; several ids run in turn and one failure doesn't abort the rest.

### Agent mode (comment-driven)

Simply run `./opilot agent`

On a watched **work package** (gated by `OPILOT_ALLOWED_OP_USER_IDS`):
`@opilot build` plans and ships in one step. `@opilot grill` stress-tests the
ticket or plan. `@opilot summarize` recaps a long thread. Any other comment
just chats.

On an opilot-opened **GitHub PR** (gated by `OPILOT_ALLOWED_GH_USERS`): any
`@opilot` comment gets a reply, and code when asked. `@opilot refresh` forces
a full refresh — base merge, CI fix, feedback sweep. `@opilot close` closes the
PR without a merge, to retire a prototype you do not want.

See `CLAUDE.md` for the options-first flow for multi-shape fixes, and
tracking upstream PRs (`OPILOT_TRACK_UPSTREAM_PRS`).

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

Everything lives in `.env`, which the first run writes interactively. See
`.env.example` for the full list of variables, with comments; `CLAUDE.md`
documents each one's rationale.

### Models

opilot reaches models through **authgw**, a small gateway container that is the
harness's only route out. Any model OpenRouter carries is one config change
away — swap `OPILOT_MODEL_HEAVY` (planning, chat, implementation) and
`OPILOT_MODEL_LIGHT` (one-shot passes like commit subjects) in `.env`.

#### Your own endpoint

Point `OPILOT_INFERENCE_URL` at any OpenAI-compatible server — vLLM, Ollama,
llama.cpp, TGI, LM Studio — and give the models a provider prefix of your
choosing:

```
OPILOT_INFERENCE_URL=http://10.0.0.5:8000/v1
OPILOT_INFERENCE_KEY=                       # empty if the server needs none
OPILOT_MODEL_HEAVY=local/qwen2.5-coder:32b
OPILOT_MODEL_LIGHT=local/qwen2.5-coder:7b
```

That prefix is the only switch: `openrouter/…` uses the provider config
committed in `pi-models.json`, anything else makes the harness generate one
pointing at your endpoint. There is no separate mode variable to keep in sync.

Two upstreams need more than a URL. **Azure OpenAI** wants its key in an
`api-key` header rather than a Bearer token, so set
`OPILOT_INFERENCE_AUTH=api-key: {key}`. A **native Anthropic or Google**
endpoint differs in wire format too, not just the header — set
`OPILOT_MODEL_API=anthropic-messages` (or `google-generative-ai`) alongside the
matching `x-api-key:`/`x-goog-api-key:` template. Everything else works on the
defaults.

Sanity-check a new endpoint with `./opilot chat "list the repos you can see"`
before running a real fix — it exercises the whole path for one cheap call.
`./opilot usage` reports spend on OpenRouter and the configured upstream
otherwise. Be aware that a local model has to hold a large context and call
tools reliably across many turns; that, rather than the plumbing, is what
decides whether a given model can drive opilot.

#### Wanting cost attribution

If you need per-work-package spend or hard budget caps, [LiteLLM
proxy](https://docs.litellm.ai/docs/proxy/virtual_keys) is the component for
it. Put it **behind** authgw (`harness → authgw → LiteLLM → providers`) rather
than in place of it: its management surface is exactly what must never be
reachable from the harness — an unauthenticated `POST /key/generate` mints an
unlimited key, and `/model/update` lets an attacker repoint `api_base` to
intercept traffic and forge tool calls. Keep `store_prompts_in_spend_logs`
off; opilot's prompts carry private repository source.

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
| `work_packages/<host>/op_agent_scan.json` | op-agent's saved scan-window watermark, written on the first `agent op` run |
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

The roadmap lives in [TODO.md](TODO.md).
