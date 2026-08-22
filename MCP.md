# The OpenProject MCP server in the harness

Answers the TODO item "Make use of the MCP server". Part 1 is the
investigation. Part 2 is the plan that follows from it. No code changed yet.

Date: 2026-08-21. Probed instance: `https://qa.openproject-edge.com/`
(server title "OpenProject DEV QA Edge"). Reference checkout of the product
code: `.opilot/repos/openproject` at `origin/dev`, commit `6ab64976a55`.

---

# Part 1 — Findings

## Summary

1. The MCP server works today with the token opilot already holds. The probe
   below is a live `tools/list` call that returns 19 tools.
2. **pi has no MCP client, and this is deliberate.** pi's own documentation
   states it twice. `docs/usage.md`: "It intentionally does not include
   built-in MCP, sub-agents, permission popups, plan mode, to-dos, or
   background bash". `README.md:498`: "**No MCP.** Build CLI tools with
   READMEs, or build an extension that adds MCP support." There is no
   configuration file that turns MCP on. opilot must write the MCP client
   itself, as a pi extension that calls `pi.registerTool()`.
3. The protocol is the small part of the work. The large part is the network.
   The harness container sits on the `internal` network with no default route.
   Its only outbound path is authgw, which pins one upstream and allows only
   inference paths. An MCP tool in the harness needs a **second** outbound
   path, and that path carries `OPENPROJECT_TOKEN`, which can write.
4. Six of the 19 tools write to OpenProject. They go around every guard that
   `CLAUDE.md` describes for `@opilot create wp`. Keep them out. Enforce the
   allowlist in the gateway, not in the container that runs the model.
5. Estimated effort for the read-only cut: about 400 to 500 new lines, plus
   edits in six existing files. One to two days, tests included.

## What the probe shows

Command (basic auth, user `apikey`, the same credential
`Clients::HTTP.request_raw` already sends):

```bash
curl -s -u "apikey:$OPENPROJECT_TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$OPENPROJECT_URL/mcp"
```

Result: HTTP 200. The `initialize` call reports protocol version
`2025-06-18`, server `openproject_mcp` version `1.0.0`, with `tools`,
`resources`, `prompts` and `logging` capabilities.

The `tools/list` call above ran **before** any `initialize` call, and it
answered 200 with the full list. The server needs no handshake, which confirms
from the outside what `lib/api/mcp.rb` shows from the inside: a stateless HTTP
client is enough.

Transport facts, read from `lib/api/mcp.rb` in the product code:

* One route, `POST /mcp` (`config/routes.rb:48`, `mount API::Mcp => "/mcp"`).
* One JSON-RPC request per HTTP request. The endpoint calls
  `MCP::Server#handle_json` and returns the answer. There is no SSE stream and
  no server session.
* The endpoint answers `404 "MCP server is not available."` when the
  Enterprise token does not allow `:mcp_server`, or when an administrator
  disabled the server. The MCP server is an Enterprise add-on.
* Authentication uses the `MCP_SCOPE` warden scope. `config/initializers/
  warden.rb:57` lists the strategies: `user_api_token`, `oauth`, `jwt_oidc`,
  `user_basic_auth`, `basic_auth_failure`, `session`. `user_basic_auth` is the
  `apikey:<token>` form opilot already uses, so **no OAuth work is needed**.
* An administrator can disable single tools and rename them
  (`McpConfiguration`, Administration → Artificial Intelligence → MCP). That
  control is instance-wide. It cannot serve as opilot's own control, because
  it changes the server for every MCP client of that instance.

### The 19 tools on the probed instance

Read-only (`readOnlyHint: true`), 13 tools:

| Tool | Required arguments |
|------|--------------------|
| `search_work_packages` | – |
| `list_work_package_comments` | `work_package_id` |
| `list_work_package_relations` | `work_package_id` |
| `search_projects` | – |
| `search_portfolios` | – |
| `search_programs` | – |
| `search_users` | – |
| `search_versions` | – |
| `search_custom_fields` | – |
| `search_custom_field_items` | `custom_field_id` |
| `list_types` | – |
| `list_statuses` | – |
| `current_user` | – |

Write tools, 6:

| Tool | Required arguments |
|------|--------------------|
| `create_work_package` | – |
| `update_work_package` | `id`, `data` |
| `create_work_package_comment` | `work_package_id`, `comment` |
| `create_work_package_relation` | `from_work_package_id`, `to_work_package_id` |
| `update_work_package_relation` | `id` |
| `delete_work_package_relation` | `id` |

The documentation page says the server is read-only. The probed instance
disagrees, because it runs the current `dev` code. **The tool set depends on
the instance version.** Read the list from the instance, never from the
documentation.

The server also exposes MCP resources and resource templates (`statuses`,
`types`, `users/me`, and templates for `projects/{id}`, `statuses/{id}`,
`types/{id}`, and more). The tools cover the same data, so the read-only cut
does not need the resource half of the protocol.

### What one call returns

A `tools/call` for `search_work_packages` with empty `arguments` answered 200
with **317 652 bytes** — about 80 000 tokens. The body carried 40 items of a
reported total of 54. Each item is a full work-package record: every date
field, every cost field, the raw markdown description, and the whole `_links`
section. That is roughly 8 KB per work package.

Two consequences for the extension:

* **Never send an unfiltered search.** The tool needs required or
  strongly-defaulted filter arguments, and it should trim each item to the
  fields a plan actually reads. One careless call fills the context window.
* **The envelope is `{ content: [{ type: "text", text: "<json string>" }],
  isError, structuredContent }`.** The text part holds a JSON string with
  `items` and `total`. The instance therefore runs the "Full" response format.
  An administrator sets that format instance-wide (Administration → Artificial
  Intelligence → MCP), and the three settings are Full, structured content
  only, and content only. The extension must handle whichever format the
  instance is set to, because the opilot operator may not control it.

## What pi gives, and what it does not

Verified against the published package `@earendil-works/pi-coding-agent@0.84.2`,
the version `Dockerfile.harness` pins.

* **No MCP client.** See the two quotations above. Outside them the string
  "mcp" appears in the shipped package only in a vendored syntax highlighter
  and in one comment about tool-result images ("extensions, MCP bridges,
  screenshot tools"). No shipped file name contains it.
* **An extension can register a tool.** `pi.registerTool({ name, description,
  parameters, execute })` (`docs/extensions.md`). The tool appears in the
  system prompt and the model calls it like a built-in tool.
* **`-e` accepts more than one extension.** `dist/cli/args.js:120` pushes each
  `--extension`/`-e` value onto a list, and `--no-extensions` still loads the
  explicit `-e` paths. So `pi-guards.ts` stays as it is, and the MCP client is
  a second file.
* **`--offline` does not block an extension.** `dist/main.js:443` reads the
  flag once and sets two environment variables, `PI_OFFLINE` and
  `PI_SKIP_VERSION_CHECK`. It disables startup network operations only —
  version checks, package update checks, catalog refresh
  (`docs/settings.md:84`). It installs no interception of `fetch`, so an
  extension may still call out. Confirm this with a real call before building
  on it: the whole design collapses if a later pi version gates extension
  network access.
* **`--tools` covers extension tools.** "Allowlist specific built-in,
  extension, and custom tools" (`docs/usage.md:211`). A new tool must appear
  in the grant string, or pi disables it.
* **The `tool_call` hook covers extension tools.** `dist/core/agent-session.js`
  installs `agent.beforeToolCall` once on the agent, for every tool call. So
  `pi-guards.ts` sees each MCP call as well — and its `KNOWN_TOOLS` set blocks
  an unknown name with `terminate: true`, which kills the run.

## Risks

**The write tools go around every existing guard.** `CLAUDE.md` lists what
`@opilot create wp` must do before it creates one work package: the allowlist
gate, the `NEEDS_INFO` stop, idempotency on `comment_at`, the
`:add_work_packages` precheck, the create-form preflight, and the rule that
opilot never fills a required custom field itself. All of it exists because a
work package can never be deleted. `create_work_package` as an MCP tool has
none of it.

**`create_work_package_comment` creates a trigger loop.** `Pull#poll_intents`
searches comment content for the bot's display name. A comment that the model
writes and that names opilot makes opilot read its own text as a trigger, on
every tick, forever. `CLAUDE.md` already names this hazard twice.

**The token can write.** In agent mode `OPENPROJECT_TOKEN` holds comment
rights, and `:add_work_packages` when `create wp` is on. The plan below puts
that token in a service the harness can reach. The gateway allowlist is what
keeps the reach read-only. It is therefore not a refinement; it is the
control.

**The injection surface grows, and it reaches the implement session.** Today
the runner decides which work-package text enters the model's context, and it
mirrors that text to disk first. With `search_work_packages`, the model pulls
text from any project the token can read, and that text arrives with no local
record. The session that holds `write` and `edit` on the product clones is the
same session an MCP result lands in, because plan and implement share one
session per work package. Text that a third party wrote therefore reaches a
context that is writing code. The token's own project access stays the outer
boundary, which is the same trust boundary the comment-search poll already
uses.

**Availability is per instance, and so is the shape of the answer.** The MCP
server needs an Enterprise token with `:mcp_server` and an administrator who
enabled it. `.opilot/` holds work packages from `community.openproject.org` as
well as from the probed QA instance. Check each instance separately. The
client must treat the 404 "MCP server is not available." answer as a normal
state and fall back to the mirrors. The same administrator also chooses the
response format and may disable or rename single tools, so the tool set, the
tool names and the envelope are all instance state, not constants.

## The cheaper alternative, and why the plan does not take it

The runner already holds the token, already has egress, and already has a REST
client with the same reach (`Clients::OpenProject`). A search pre-pass in the
runner, mirrored to `/state`, needs no new container, no new outbound path and
no extension. It buys less: the model cannot decide what to fetch while it
works. That difference — model-driven, on-demand querying — is the whole
reason to do the harness-side work below.

---

# Part 2 — The plan

**Status: implemented.** Steps 1–5 below are all in place — `opgw.js`,
`pi-op-mcp.ts`/`op-mcp-client.js`, the runner wiring, compose/launcher
changes, and this file. One decision changed from what is written below
during implementation, on explicit direction: **`OPILOT_OP_MCP` defaults ON**
(opt out with `0`/`false`/`no`/`off`), not off-by-default as the Decisions
table originally called for — see the note under that table.

The outcome: the plan and chat phases can look up a duplicate ticket, a work
package opilot never mirrored, or live instance metadata, while the harness
stays contained and the write tools stay unreachable.

## Decisions

| Question | Decision |
|----------|----------|
| Route | Harness-side: a new `opgw` sidecar plus a pi extension |
| Tool shape | One pi tool, `op_query`, with an `operation` parameter |
| MCP client | Own it. pi has none; the ecosystem options cost more than they save — see Step 2 |
| Phases | Plan, chat, gh-agent's own-PR reply and CI fix. **Not** the fix implement run, not upstream PR review, not `create wp` |
| Gateway code | Standalone `opgw.js`. `authgw.js` and its test stay untouched |
| Language | JavaScript, so opgw copies authgw's proven parts. Ruby was considered and dropped: a rewrite of the pinning and header rules would have to be re-reviewed from scratch. The extension has no choice — it runs inside pi |
| Default | **Changed during implementation, on explicit direction: ON.** `OPILOT_OP_MCP=0` (or `false`/`no`/`off`) turns it off |

The reasoning that originally argued for off-by-default still holds as a
description of the failure mode, just not as the conclusion: the MCP server
is an Enterprise add-on an administrator must enable, so most instances have
none. What changes the conclusion is that the whole design already treats
"unavailable" as a normal, quiet outcome rather than an error — `op_query`
itself returns one clear line and the run continues (Step 2), and the startup
check (Step 3) distinguishes a 404 (`Clients::OpMcp::Unavailable`) from a real
failure and logs it quietly rather than as a warning. Defaulting on therefore
costs an idle `opgw` container and one log line on an instance without the
add-on, not a broken or noisier run — while an instance that DOES have it
enabled gets the lookup without anyone needing to discover the flag. With the
flag off (opt-out), no `opgw` container starts, the grants stay `TOOLS_READ`
and `TOOLS_IMPL`, and the prompts say nothing about the tool — unchanged from
the original design.

## Data flow

```
pi (harness, no default route)
  └─ op_query tool  ── POST http://opgw:47293/mcp
                       Authorization: Bearer $OPILOT_GW_TOKEN
                          │
                       opgw (internal + egress)
                          │  · validates the handshake token
                          │  · parses the JSON-RPC body, allows 3 methods and 8 operations
                          │  · deletes the inbound Authorization, attaches apikey basic auth
                          │  · pinned address, fixed upstream
                          └─ POST <OPENPROJECT_URL>/mcp
```

## Step 1 — `opgw.js`, the OpenProject gateway

**New files:** `opgw.js`, `Dockerfile.opgw`, `test/js/opgw_test.js`.

Copy the proven pieces from `authgw.js`: the config parse and freeze
(`parseConfig`), the boot-time resolver with lazy re-resolution
(`createResolver`), the handler shape (`createHandler`), the `/health`
endpoint, the `Bearer $OPILOT_GW_TOKEN` handshake check, the unconditional
`delete headers['authorization']` rule, and the 401/403/502 answers.
`Dockerfile.opgw` copies `authgw`'s: `node:20-slim`, one file, `USER node`.

Five differences from `authgw.js`, all deliberate:

1. **Upstream and credential.** `OPENPROJECT_URL` is the upstream.
   `OPENPROJECT_TOKEN` becomes `Authorization: Basic base64("apikey:" + token)`.
   Refuse to boot when either is missing, the way `parseConfig` refuses today.
2. **One path.** The client may send only `POST /mcp`. The upstream path is
   `<pathPrefix>/mcp`, so an instance served under a sub-path still works.
   Keep authgw's traversal check.
3. **A body allowlist, not a path allowlist.** Every call is the same path, so
   the gateway must read the body. Buffer it (cap 64 KB, refuse above), parse
   it, and require:
   * an object, never an array — a batch must not carry an unchecked call;
   * `method` in `initialize`, `tools/list`, `tools/call`;
   * for `tools/call`, `params.name` in `READ_ONLY_OPS`.

   `READ_ONLY_OPS` = `search_work_packages`, `list_work_package_comments`,
   `list_work_package_relations`, `search_projects`, `search_versions`,
   `list_types`, `list_statuses`, `search_custom_fields`.

   Refuse with 403 and a reason on stderr, as authgw does. Log every allowed
   call as `method` plus `params.name`; that container log is the only record
   an MCP call leaves anywhere (see "The mirrors stay independent" below).
4. **The request is not streamed, and one response is filtered.** Inspection
   needs the whole body, so opgw buffers the request and sets its own
   `content-length`. Responses pipe straight back, with one exception:
   on `POST /mcp`, a `tools/list` answer is buffered and **reduced to
   `READ_ONLY_OPS`**, so the model is never shown a tool it cannot call.
   Filtering the list is not a security control — the `tools/call` check is —
   but a tool in the list that always 403s wastes turns and invites retries.
   Write both reasons in the file header; this is the one place opgw must not
   copy authgw.
5. **One extra route, `GET /tools`, for the runner.** It runs its own
   `tools/list` upstream and returns the **unfiltered** set. The filter above
   would otherwise hide the very thing the startup check in Step 3 exists to
   report — which write tools the instance still has enabled. Same handshake
   token, same internal-only network; it exposes nothing the runner cannot
   already read with its own token. Keep the two routes plainly separate in
   the code: `/mcp` is the model's door and is filtered, `/tools` is the
   operator's and is not.

The same list also lives in the extension (Step 2). The two run in different
containers, so the duplication is unavoidable. Say so in both files, and let
the gateway be the authority: the extension's copy only shapes the schema the
model sees.

## Step 2 — the pi extension `pi-op-mcp.ts`

**New files:** `pi-op-mcp.ts`, `op-mcp-client.js`, `test/js/pi_op_mcp_test.js`.
**Edited:** `Dockerfile.harness` (copy both files), `server.js`.

### Why write this, when the ecosystem has it

Three ready-made routes exist. None fits, and the reasons are worth stating
once, because the same question will come back.

* **Switch the harness to omp (`oh-my-pi`).** omp is a fork of pi
  (`@oh-my-pi/pi-coding-agent@17.4.2`, MIT, binary `omp`) with **native MCP**:
  an `mcp.json` with `type: "http"`, a `url`, and expanded `${VAR}` headers
  would point straight at opgw and need no client code at all. The cost is a
  harness migration, not a config change. `server.js`'s `translate()` is
  written against pi 0.84.2's exact `--mode json` event shapes; `pi-guards.ts`
  — the write and bash confinement — is written against pi's extension hook;
  `--offline` is not in omp's CLI reference. Each is a security-relevant
  re-verification. omp also bundles LSP, a DAP debugger, Python, browser
  control, subagents and a SQLite memory engine into the container that reads
  untrusted text, and it **discovers MCP servers from the project tree**
  (`.omp/mcp.json`, `mcp.json`, `.mcp.json`, plus Claude, Cursor and VS Code
  configs). The harness works in `/repos`, so a product clone could define an
  MCP server. That is a new injection path into the agent's own configuration.
  Revisit omp as its own decision about the harness CLI, never as a way to get
  one tool.
* **A third-party pi MCP extension.** Two exist: `pi-mcp-extension` (92 KB,
  one dependency) and `pi-mcp-adapter` (2.5 MB, twelve dependencies including
  a native keyring). pi's own packages doc warns that extensions "run with
  full system access" and "execute arbitrary code". Adding unaudited code to
  the one container that holds untrusted text and every product clone is the
  opposite of what the rest of this design does.
* **Any generic MCP client, ours or theirs.** A generic client exposes every
  tool the server offers and returns whatever the server sends. This plan
  needs the opposite on both counts: an eight-operation enum, and the trimmer
  that turns a 317 KB answer into something a context window survives. That
  trimmer is the reason to own the file, and it is most of its value.

### The two files

**Split the file in two, for the same reason `pi-guards.ts` carries no type
annotations.** `test/js/pi_guards_test.js` loads its subject straight off disk
with plain Node, and the CI loop runs `node test/js/*_test.js` outside the
harness image. An extension that imports `typebox` and `@earendil-works/pi-ai`
at module scope cannot load there. So:

* `op-mcp-client.js` — plain CommonJS, no pi imports: request building,
  the three response-format parsers, the trimmer, and the error mapping. This
  is what the test requires, and it holds everything worth asserting.
* `pi-op-mcp.ts` — the pi-only entry point: the typebox schema, the
  `registerTool` call, and a relative import of `./op-mcp-client.js`.

Verify the relative import resolves under pi's jiti loader when the image is
first built; that is the one unknown in this step.

Register one tool with `pi.registerTool()`:

* `name: "op_query"`, with `promptSnippet` and a `promptGuidelines` bullet
  that names `op_query` (pi appends the bullets flat, so "this tool" is
  useless there).
* Parameters: `operation` as a `StringEnum` of the eight operations, plus the
  flat optional arguments the MCP schemas declare — `work_package_id`,
  `subject`, `project_id`, `status_id`, `type_id`, `id`, `name`, `sharing`,
  `page`. Forward the set ones as the MCP `arguments` object. Flat fields beat
  one opaque `arguments` blob, because the model sees the real parameter
  names.
* `execute` posts one JSON-RPC `tools/call` to `${OPILOT_OPGW_URL}/mcp` with
  the handshake bearer token, under an `AbortSignal` timeout of about 30 s, so
  a wedged gateway does not spend the harness idle budget.
* **Register nothing when `OPILOT_OPGW_URL` is empty.** That is the second
  half of the feature flag; the first half is the tool grant.

Three behaviours the tests must pin:

* **Answer parsing.** An administrator chooses the response format
  instance-wide, so handle all three: prefer `structuredContent`, else parse
  the JSON string in `content[0].text`, else return the plain text. Report
  `isError` and a JSON-RPC `error` as a tool error.
* **Trimming.** `search_work_packages` returns full work-package records at
  about 8 KB each, 40 per page. Keep a fixed subset per item — `id`,
  `displayId`, `subject`, type, status, project, `updatedAt`, and a
  description excerpt of a few hundred characters — and state `total` and how
  many items came back. Cap the whole tool answer at about 25 KB.
* **Unavailable is normal.** A 404 "MCP server is not available." means the
  instance has no Enterprise MCP server. Return one clear line telling the
  model to use the mirrors instead. Never fail the run.

`server.js` changes:

* Add `-e /app/pi-op-mcp.ts` beside the existing `-e /app/pi-guards.ts`.
  `dist/cli/args.js` collects repeated `-e` values, and `--no-extensions`
  still loads explicit paths.
* Add the two new grant strings to `ALLOWED_TOOL_GRANTS`:
  `read,grep,find,ls,bash,op_query` and
  `read,grep,find,ls,bash,write,edit,op_query`.

`pi-guards.ts`: add `op_query` to `KNOWN_TOOLS`. Nothing else — an unknown
name terminates the run, and the gateway is the real control. Say that in the
comment beside it.

## Step 3 — the runner side

**Edited:** `lib/opilot/context.rb`, `lib/opilot/harness.rb`,
`lib/opilot/helpers.rb`, `lib/opilot/prompts.rb`, and the call sites below.

* `Context#op_mcp?` — copy the `track_upstream_prs?` form
  (`%w[1 true yes on].include?(...)`), reading `OPILOT_OP_MCP`.
* `Harness::TOOLS_READ_OP = "#{TOOLS_READ},op_query"` and
  `Harness::TOOLS_IMPL_OP = "#{TOOLS_IMPL},op_query"`, each with the same
  "must stay in sync with `ALLOWED_TOOL_GRANTS`" comment the other two carry.
  `ALLOWED_TOOL_GRANTS` therefore holds four strings.
* Two helpers in `Helpers` — `read_tools` and `impl_tools` — returning the
  `_OP` variant when `@ctx.op_mcp?` and the plain constant otherwise. Use them
  at the phases that get the tool, and nowhere else:

  | File | Call | Phase | Grant |
  |------|------|-------|-------|
  | `agent.rb:129` | `handle_chat` | thread chat | read |
  | `agent.rb:584`, `:594` | `produce_plan` replan and plan | plan | read |
  | `fix_runner.rb:130`, `:148`, `:333` | plan, replan, terminal chat | plan | read |
  | `chat_runner.rb:43` | `dev chat` | chat | read |
  | `gh_agent.rb:246` | `run_on_pr_head` | own-PR reply **and** CI fix | impl |

  **Read this trade-off before starting.** `gh_agent.rb:246` is the one
  `TOOLS_IMPL` call that gains the tool, because `run_on_pr_head` serves both
  `handle_own` and `handle_ci` — the two passes named in the phase choice. It
  therefore puts `op_query` in a session that holds `write` and `edit`. Two
  facts bound it: that session works on an existing PR branch that a human is
  already reviewing, and every push still goes to the fork. Strike this row if
  the surface is not worth the lookup; nothing else in the plan depends on it.

  **`gh_agent.rb:152` (`pr_review`, the upstream path) is deliberately left
  out.** The phase choice named PR replies and the CI fix, which are both the
  own-PR call above. An upstream review is the widest-reach combination
  available here — a third party's PR text, in a context that could query your
  own OpenProject instance — and it is the one gh-agent path where opilot is a
  guest. Add the row and the prompt line together if that lookup turns out to
  be worth it.

  Left on the plain grants on purpose: `agent.rb:283` (`create wp` draft —
  that command has its own guard story), `helpers.rb:922` and `:949` (light
  one-shot passes), `pr_runner.rb:407` and every `pd/runner.rb` call.
  **The fix implement run keeps no MCP tool.** Note the residue honestly: plan
  and implement share one session, so text a search pulled in during planning
  is still in context while implement writes code. Not granting the tool
  bounds how much of it can arrive, and when.
* **A startup check on what the instance really offers.** With the flag on,
  read opgw's `GET /tools` once — the unfiltered list — through a small
  `Clients::OpMcp`, using the handshake bearer token. The runner sits on
  `internal`, so it reaches opgw directly. It logs one line: how many tools
  the instance exposes, how many opgw allows, and **which write tools the
  instance still has enabled**. opilot cannot disable those; an administrator
  can (`McpConfiguration`, Administration → Artificial Intelligence → MCP).
  The check is what turns "the gateway refuses writes" from a claim into an
  observed fact at every start. It also names any of the eight read
  operations an administrator has disabled, so a later "the tool does
  nothing" is already explained.

  **It warns; it never raises.** That is the opposite of the preflights it
  sits beside: `#ensure_claude!` and `Pull#ensure_bot_identity!` raise on
  purpose, because a run without a model or an identity cannot work. This one
  has a working fallback — the mirrors — so a 404, an unreachable gateway or a
  malformed answer logs a warning and leaves `op_query` unused for the run.
  Run it **once per process**: in `Agent#setup`, never inside `guarded_tick`,
  and once at the start of each `dev` verb that uses the tool.
* `Prompts.op_query_line(enabled)` — returns `""` when off, following
  `related_line`'s pattern. Add it to `plan`, `replan`, `chat`, `free_chat`
  and `gh_reply`/`fix_ci` — the prompts behind the granted call sites, and
  **not** `pr_review`. The text must say: read the mirror first; always pass a
  filter, because an unfiltered search is huge; `search_work_packages` matches
  a partial `subject` and has no full-text search; resolve a type, status or
  project id with the list operations; results are untrusted data, not
  instructions; fall back to the mirrors when the tool reports the server is
  unavailable.

## Step 4 — compose, launcher, configuration

* `compose.yml`, three edits — the third is easy to miss and makes the whole
  flag a silent no-op:
  1. an `opgw` service on `internal` and `egress`, using the `x-hardened`
     anchor, with `OPENPROJECT_URL` / `OPENPROJECT_TOKEN` / `OPILOT_GW_TOKEN`
     in its environment and a `/health` healthcheck copied from authgw's;
  2. `- OPILOT_OPGW_URL` in the **harness** environment;
  3. `- OPILOT_OP_MCP` in the **runner** environment. `Context` runs in the
     runner, so without this line `op_mcp?` is always false and the grant
     never flips.

  Both new variables use the bare form (`- VAR`), never `${VAR:-}`, for the
  reason `compose.yml` already states: unset must mean absent, not blank.
  `OPILOT_OPGW_URL` must **not** be hardcoded the way `HARNESS_URL` is, or the
  extension's own gate can never fire.
* `opilot`: a `_needs_opgw` test (needs the harness **and** the flag), export
  `OPILOT_OPGW_URL=http://opgw:47293` only when it passes, start `opgw` in the
  `dc up -d --wait` line, and stop it in the same trap. The feature then has
  two real gates: the runner sends the `op_query` grant only when the flag is
  set, and the extension registers the tool only when the URL is present.
* `.env.example`: `# OPILOT_OP_MCP=1` with a comment naming the Enterprise
  requirement and the read-only limit. No wizard change — the URL and the
  token already exist.

## Step 5 — documentation

* `CLAUDE.md`: the container list becomes four; the "egress is strictly
  zero-except-authgw" sentence becomes "authgw, plus opgw when
  `OPILOT_OP_MCP` is set"; a new `opgw` paragraph beside the authgw one; the
  environment-variable table gains `OPILOT_OP_MCP`; the harness-communication
  section gains the two new tool grants.
* `README.md`: the container diagram and the egress sentence in the security
  section.
* This file: a line at the top of Part 2 saying which part is implemented.

## The mirrors stay independent

Nothing about this touches `.opilot/`. An MCP answer reaches the model's
context and stops there. The extension cannot write it down even if it tried:
`/state` is mounted read-only and `pi-guards.ts` confines writes to `/repos`.
The mirrors keep their single writer, the runner through
`Clients::OpenProject`, and keep their exact current content.

Two consequences to accept knowingly:

* `chat`, `dev refresh` and every later run still see only what an earlier run
  mirrored. A ticket the model found through `op_query` leaves no `item.json`.
* The record of a call is opgw's container log and the streamed `op_query`
  line in the terminal. `chomp.log` holds the prompt and the final text, not
  the tool traffic, so the gateway log is the durable half.

Mirroring MCP answers is a separate decision, and a bigger one — it would make
the model's queries part of the audit trail, and would need a writer on the
runner side, because the harness must stay unable to write there.

## Sequencing and rollback

Do the steps in order. Steps 1 and 2 are testable on their own: the gateway
answers `curl` before any pi run exists, and `op-mcp-client.js` is testable
before the extension loads. Nothing reaches a model until Step 3 flips the
grant. To roll back, unset `OPILOT_OP_MCP`: no `opgw` container starts, the
grants revert, the extension registers nothing, and the prompts drop the
block.

## Verification

Unit tests:

```bash
docker compose run --no-deps --rm runner bundle exec rake
for f in test/js/*_test.js; do node "$f" || break; done
```

`test/js/models_json_test.js` asserts `ALLOWED_TOOL_GRANTS.size === 2` today.
It must become 4 and assert both new strings. `test/opilot/chat_runner_test.rb:65`
and `test/opilot/gh_agent_test.rb:183`, `:343` assert `Harness::TOOLS_READ` for
`pr_review`, which this plan leaves unchanged — they must keep passing with
the flag **on**, which is the assertion that upstream review stays out. Add
one case per changed runner that sets the flag and expects the `_OP` grant.

Gateway behaviour, from inside the contained network:

```bash
docker compose up -d --wait opgw harness
docker compose exec harness node -e "fetch('http://opgw:47293/mcp',{method:'POST',headers:{'authorization':'Bearer '+process.env.OPILOT_GW_TOKEN,'content-type':'application/json'},body:JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/list'})}).then(r=>r.text()).then(t=>console.log(t.slice(0,300)))"
```

Expect 200, and a tool list carrying **only the eight allowed operations** —
that is the response filter working. Then check the refusals: `tools/call`
with `create_work_package` must answer 403, a JSON array body must answer 403,
and a request without the bearer token must answer 401. Confirm containment is
unchanged:

```bash
docker compose exec harness cat /proc/net/route   # no 00000000 destination row
```

End to end, on a work package that has a known duplicate, on an Enterprise
instance with the MCP server enabled:

```bash
./opilot dev plan <id>   # OPILOT_OP_MCP is on by default — nothing to set
```

Watch the startup line naming the instance's tool count and any enabled write
tools, watch the streamed `op_query` call, and check that `plan.md` names what
the search found. Confirm `.opilot/work_packages/<host>/<id>/` gained no new
file. Then run the same command against an instance with **no** MCP server (or
with `OPILOT_OP_MCP=0`) and confirm the run still works: no `op_query` line
(or, on a real Enterprise-less instance, one quiet "not available on this
instance" log line and nothing else), and no `opgw` container when the flag
is off.

## Out of scope

* The six write tools. The runner keeps writing through
  `Clients::OpenProject`, where the `create wp` guards live.
* `search_users`, `search_portfolios`, `search_programs`,
  `search_custom_field_items`, `current_user`. Add them later if a real plan
  run asks for them; each one is one line in two allowlists.
* MCP resources and resource templates. The tools carry the same data.
* Replacing the mirrors. The mirrors stay the audit trail that `chat` and
  `dev refresh` read.
