<div align="center">

<img width="100" height="100" alt="opilot" src="https://github.com/user-attachments/assets/1a0383fb-7c98-4cea-b3b6-8c8ef638f9b6" />

# OPilot

**Your friendly neighborhood OpenProject agent**

⚠️ _EXPERIMENTAL PROOF OF CONCEPT — use at your own risk!_

</div>

## What is this?

A standalone "OpenProject copilot" that uses the [`pi` agent harness](https://pi.dev/) + LLM of your choice to automate various tasks. 

Chat with it throughout the OpenProject interface and let it work in the background!

## Who is this for?


### Software developers

AI tools help us design and implement faster. Nevertheless, outside that creative process, there is still some inevitable legwork: checking out branches, running local AI coding assistants by hand, and managing pull requests.

Use OPilot to remove that friction from your development workflow. It can automate anything from simple bug-fixing to entire E2E product delivery. Just chat with `@OPilot` in OpenProject and GitHub PRs!

* **Prototype solutions**: Generate auto-correcting code prototypes via `@OPilot build`. Refine the code by chatting with [OPilot Bot](https://github.com/op-opilot) within the PR.
* **Take ownership**: Run `opilot-adopt <pr-id>` to make the prototypes your own, thus cleanly transferring ownership.
* **Help with upstream PRs**: Tag `@OPilot` in any upstream PR with questions. These can relate to code as well as the product context.
* **Fix production errors**: Run `./opilot appsignal fix <incident>` to turn an AppSignal exception into a work package and a draft PR. It **refuses to run unless your model is local** — production error data never reaches a third party.

### Product builders
* **Automate product development**: Use the experimental `pd` product development pipeline to deliver entire features end-to-end, using OpenProject as the work tracking backend.

### General audience

* **Refine work packages**: Discuss work packages in the chat via free-form chatting or preset commands like `@OPilot grill`.
* **Draw diagrams and write reports**: Ask for a diagram or a long report in the chat. OPilot publishes it as a secret gist and links it from the comment — a diagram is a mermaid fence, which the gist renders as a picture. Needs `OPILOT_ALLOWED_OP_USER_IDS`.
* **Create work packages**: Turn a suggestion made in a comment into its own work package(s) with `@OPilot create wp <instructions>`. OPilot builds the package content, creates them in the same project, and relates them back.
* **[Enterprise] Run project-wide discovery**: Ask `@OPilot` anything about the reachable projects' data -- it will leverage the instance's MCP server to give you a fresh answer.

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
- **LLM (inference) URL & key**: OpenRouter or your own OpenAI-compatible server (see [Models](#models))
- **GitHub auth token** for a permission-less contributor account (e.g. [opilot-agent](https://github.com/opilot-agent))
- **OpenProject API token** for a sufficiently restricted bot account (e.g. [Chomper Agent](https://community.openproject.org/users/100163) on Community)
  - At least "read work package" and "write comment" is required; more permissions (e.g. "create work package") may also unlock optional features (e.g. work package creator)

---

## Quick start

### Setup
```bash
git clone https://github.com/opf/opilot
cd opilot
docker compose build
# Create .env based on .env.example OR just leave it to the first startup wizard
```

### Agent mode
Scans for new activity on OpenProject WPs + its own GitHub PRs, and acts on @OPilot mentions
```bash
./opilot agent
```

### CLI mode
Fallback interface: Same functionality as the agent, but runnable via the CLI & adding some extras.

Some examples:
```bash
# Use the built-in OpenProject mini-SDK
./opilot op doc list
./opilot op wp create --project "COMMS" --subject "Hi"

# Use the software development commands
./opilot dev build COMMS-123

# Turn a production error into a work package and a draft PR (needs a LOCAL model)
./opilot appsignal fix 4711 --project COMMS

# Invoke the opilot chatting interface locally
./opilot chat

# See configured models and their token usage stats
./opilot usage
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
│ ┌─ runner container ────────────────┐        ┌─ harness container ───────────────┐          │
│ │                                   │        │                                   │          │
│ │ Ruby 4.0 script                   │  json  │ Node.js server (:47291)           │          │
│ │  * Pulls WP content from OP API   │◀──────▶│   POST / -> `pi --mode json`      │          │
│ │  * Manages metadata in .opilot/   │        │ volumes: .opilot/                 │          │
│ │      * WP metadata mirror         │        │                                   │          │
│ │      * Plan files                 │        │                                   │          │
│ │      * Draft PR data              │        └──────────────┬────────────────────┘          │
│ │  * Pushes branches, opens PRs     │                       │                               │
│ │  * Delegates chat to the LLM      │                       │                               │
│ └───────┬───────────────────────────┘                       │                               │
│         │                                            ┌──────┴───────────────┐               │
│         │                                            │                      │               │
│         │                                            ▼                      ▼               │
│         │                             ┌─ mcp-gw ───────────┐    ┌─ inference-gw ─────────┐  │
│         │                             │ Read-only ops      │    │ LLM inference access   │  │
│         │                             │ on various MCPs    │    │ injects the real token │  │
│         │                             │                    │    │                        │  │
│         │                             │                    │    │                        │  │
│         │                             └───────┬────────────┘    └────────────┬───────────┘  │
│         │                                     │                              │              │
└─────────┼─────────────────────────────────────┼──────────────────────────────┼──────────────┘
          │                                     │                              ▼
          │         ┌─────────────────┐────┐    │                  ┌─────────────────────────┐
          ├────────▶│ OpenProject API │/mcp│◀───┤                  │ Inference API:          │
          │         ├ ────────────────┼────┤    │                  │ OpenRouter, or your     │
          ├────────▶│ GitHub API      │/mcp│◀───┘                  │ own OpenAI-compatible   │
          │         ├ ────────────────┼────┘                       │ endpoint                │
          └────────▶│ AppSignal API   │                            └─────────────────────────┘
                    └─────────────────┘
```

### Security model

The harness container processes untrusted text (work package descriptions and comments), so it is locked down: no host/LAN exposure, **no network egress at all except inference-gw and mcp-gw**, an isolated API key, writes confined to `/repos` (and
never into a `.git/` directory), Bash confined to read-only git, resource caps,
a hardened container, and everything ships only as a *draft* PR for human
review.

---

## Reviewing & pushing

Happens via a dedicated unprivileged bot account (such as [opilot-agent](https://github.com/opilot-agent)), with **no access to the canonical repo**. It forks, pushes to the fork, and opens cross-repo draft PRs.

### Adopting an OPilot PR

You may easily transfer ownership of a prototype PR generated by the agent.

#### Pre-requirement: Install the `tools/opilot-adopt` script 
Just put it somewhere reachable. Quick suggestion:

```bash
mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/opf/opilot/main/tools/opilot-adopt -o ~/.local/bin/opilot-adopt && chmod +x ~/.local/bin/opilot-adopt
````

#### Adoption: Run the script from inside the **product** repo you are adopting into.

```bash
opilot-adopt 42        # or paste the PR URL
```

It does the following (with human approval steps):
* Refreshes the code branch from upstream
* Rewrites commit ownership to **you**
* Pushes a new branch to the upstream repo
* Opens a draft PR for the new branch, without opilot's bot-only banner
* Closes the original PR.

---

## Configuration

Everything lives in `.env`, which the first run writes interactively. See `.env.example` for the full documentation of variables.

### Models

OPilot harness reaches the inference API through **inference-gw**, a small gateway container that is the harness's only route out. Configure the taget API & auth via environment variables.

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

#### Example local model usage
(Roughly 20 GB of RAM needed)
```
ollama pull qwen3.8:27b-mlx
OLLAMA_HOST=0.0.0.0 OLLAMA_CONTEXT_LENGTH=65536 ollama serve
```

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

The suite uses Minitest (ships with Ruby) and WebMock for HTTP stubs. No network calls are made during the test run.

---

## TODO

The roadmap lives in [TODO.md](TODO.md).
