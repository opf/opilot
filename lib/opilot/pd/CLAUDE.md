# CLAUDE.md — the `pd` pipeline

Guidance for `lib/opilot/pd/` (namespace `OPilot::PD`). The root `CLAUDE.md`
covers everything else: containers, the bug-fix flow, publishing, `.env`.

`./opilot pd <subcommand>` is a spec-driven pipeline, separate from the bug-fix
modes: OpenProject Documents → an [OpenSpec](https://github.com/Fission-AI/OpenSpec)
change proposal reviewed as a PR → generated work packages → one implementation run
per WP → archive. It has its own namespace because the bug-fix verbs
(`plan`/`build`/`ship`/`pr`) also take a work-package id while meaning something
else entirely. Like every mode it publishes as the contributor bot. Implemented:
M0–M3.

```bash
./opilot pd init <project-id> [--repo <name>]
./opilot pd intake <project-id> <change-id> [--doc-id <id>]...
./opilot pd propose <change-id>
./opilot pd generate-wp <change-id>
./opilot pd implement <wp-id>...
```

## Files

| File | Role |
|------|------|
| `runner.rb` | The `pd` command family; always publishes as `:contributor` |
| `change_state.rb` | `ChangeState` (per-change paths, branch, `tracker.json`) + `ChangeStore` (canonical store, materialise/persist, `.git/info/exclude`, WP→change reverse index) |
| `resolved_ids.rb` | Id resolution by name — project, types, statuses with `isClosed`; fails fast |
| `openspec.rb` | Open3 wrapper around the `openspec` CLI (runner-only) |
| `tasks_file.rb` | Parse/rewrite `tasks.md` — sections, `(#id)` bindings, checkboxes; blanks fenced code so an example `##` can't mint a work package |
| `intake.rb` | Documents → `intake/*.md` + attachments, `intake.hash` short-circuit |
| `intake/converter.rb` | Attachment conversion, `unconvertible[]`, zip-bomb guards |

`lib/opilot/pd.rb` is the load boundary, and it is load-bearing: nothing here is
required at boot (`CLI#pd` requires it on demand), and `intake` is lazier still
(`PD::Runner#intake_client` requires it on first use, keeping roo/nokogiri/rubyzip
out of every run that never reads a document). The one exception is
`PD::ChangeStore`, which `gh_pull.rb` requires directly because identifying a spec
PR needs the store's layout on every agent tick.

## Stages

- **`pd init <project-id>`** — resolves ids **by name** (`ResolvedIds`): project,
  parent/child WP types (`OPILOT_PD_PARENT_TYPE`/`OPILOT_PD_CHILD_TYPE`, default
  `FEATURE`/`IMPLEMENTATION`, neither stock), statuses with `isClosed`. Fails fast
  listing what's missing plus the types the project offers, then seeds the canonical
  store. It is the pipeline's **preflight**, checking what a later stage would
  otherwise discover expensively: the transition statuses exist (else a typo surfaces
  during `implement`, after the spec PR is up and the code committed); the token has
  `:add_work_packages` (OpenProject renders `createWorkPackage` links only for a user
  who does, so their absence is an answer, not a guess); the clone exists — checked
  before any network call and **fatal**, because `ChangeStore#exclude_from_clone!`
  returns *silently* without `.git/info`, leaving `openspec/` sweepable into an
  unrelated commit with nothing said; and `GITHUB_CONTRIBUTOR_TOKEN` resolves to a
  login with its scopes reported (advisory — `init` and `intake` work with no GitHub
  token, and an empty scope list means a fine-grained token, i.e. "unknown").
- **`pd intake <project-id> <change-id> [--doc-id <id>]...`** — mirrors Documents to
  `changes/<change-id>/intake/`, one ordinal markdown file each with
  `id`/`title`/`updated_at` frontmatter. `--doc-id` narrows it, validated against the
  named project so a typo can't pull an unrelated project's document in.
  `<project-id>` may be numeric or the identifier: the Documents API coerces its
  `project` filter to integers, so an identifier matches nothing *silently* —
  `#project_numeric_id` resolves it once (memoized). Re-running short-circuits on
  `intake.hash`, which covers the sorted `(id, updated_at)` pairs **and the
  `--doc-id` selection**, since narrowing changes the material even when no document
  moved.
- **`pd propose <change-id>`** — turns intake into `proposal.md`, `design.md`,
  `tasks.md` and `specs/<capability>/spec.md` deltas, opens the **spec PR that is the
  approval gate**, and halts. the LLM writes with `TOOLS_IMPL`; the runner then runs
  `openspec validate --strict --json` and feeds failures back for up to
  `MAX_VALIDATE_ATTEMPTS` (2) revisions in the same session — the CLI isn't in the
  harness container, so "the agent iterates on its own output" is a runner-driven
  re-prompt loop. Intake spanning more than one atomic feature returns `TOO_BROAD`
  with a suggested split (mirroring `Prompts.plan`'s `NEEDS_INFO`), since one change
  becomes exactly one FEATURE.

  **The write scope is enforced** (`#enforce_write_scope!`) — a planning stage must
  not be able to modify source, and `pi-guards.ts` only confines the LLM to
  `/repos`. Two surfaces are checked: everything git can see, and the spec tree
  diffed against the canonical store (git reports nothing about an excluded tree).
  Anything outside `changes/<change-id>/` resets the clone and fails the run before
  any commit.

  `Publish#open_spec_pr` pushes `spec/<change-id>` to the fork and opens a draft PR
  **inside that fork** (head and base both `<bot>/<repo>`,
  `maintainer_can_modify: false` — GitHub 422s on a same-repo PR otherwise), after
  levelling the fork's base with upstream (`sync_fork_branch` → the `merge-upstream`
  endpoint). The spec branch is cut from the clone, which tracks **upstream**, while
  the PR's base is the **fork's** copy frozen at fork-creation time — left stale the
  diff carries every intervening upstream commit and is unreviewable; a genuinely
  diverged fork can't fast-forward, so the sync warns rather than fails.
  Deliberately not against upstream: the diff is planning artifacts, and nothing
  downstream needs the merge — `generate-wp` reads the local store. **`propose`
  writes nothing to OpenProject**: work packages are never deleted (the HTTP client
  has no DELETE verb), so a FEATURE created here would outlive every rejected
  proposal.
- **`pd generate-wp <change-id>`** — one parent FEATURE (`#ensure_feature_wp`,
  idempotent on `tracker.json`'s `parent_wp`, subject from `proposal.md`'s first
  heading, spec PR link posted as a comment) and one child IMPLEMENTATION per
  top-level `tasks.md` section, carrying its checklist. **Running this is the
  approval signal** — it reads the local store, so merging the spec PR stays
  optional. Every write is idempotent because none can be undone: each id is bound
  into its heading as `## Title (#1204)` (`TasksFile.bind_id`) **immediately after
  the POST that created it**, not in one pass at the end, so a crash mid-run can't
  orphan a work package the next run would duplicate; bound sections are skipped,
  bindings persist in an `ensure`, and a failed POST is reported while the loop
  continues. Four things are refused *before* the first POST, since half a tree is
  worse than none when the halves can't be deleted: no `tasks.md`, no top-level
  sections, an incomplete `pd init` cache (the message names which id is missing),
  and **duplicate section titles** — bindings are written back by heading text, so
  two unbound twins would both take the first id, giving one work package for two
  chunks of work. `ChangeStore#reverse_index` is the reverse direction, rebuilt from
  `tasks.md` on every call.
- **`pd implement <wp-id>...`** — builds one generated work package from its spec:
  its own branch (`implementation/<id>-<slug>`, from `Helpers.branch_slug`), commit,
  ticked section, draft PR. **Keyed on a work-package id**, not a change id — work
  packages are what a human assigns, comments on and closes, and implementing a whole
  change in one pass produces the unreviewable PR the decomposition exists to avoid.
  Change and repo are resolved *from* the id via `reverse_index` (`--repo` narrows
  it); an unbound id lists what *is* bound instead of just failing.
  `Prompts.implement_task` carries the spec paths, the WP's `item.json` (a human
  comment added after the proposal qualifies or overrides it) and **only this
  section's checklist** — a sibling section is another work package's PR. The write
  scope is `propose`'s mirror image: there the spec was output and source off limits;
  here the spec is *input*, so a stray edit under `openspec/` is restored from the
  store (`#restore_spec_tree!`) and the run continues — the tree is git-excluded, so
  nothing would have been committed, and discarding a working implementation over a
  stray spec edit is the wrong trade. Checkboxes are ticked by the harness
  (`TasksFile.set_section_done`) and **only after a commit exists** — a run that
  produced nothing leaves them unticked and opens no PR, which is the honest record.
  Publishing goes through the same `Publish#open_pr` as the bug-fix flow, so
  `gh-agent` picks the result up from `pr_url.txt` and `./opilot dev refresh <id>` can
  refresh it. The work package is **transitioned twice** (`#transition!`): to
  `OPILOT_PD_IMPLEMENTING_STATUS` when the LLM run starts (inside the
  `branch_has_commits?` guard, so a re-run that only publishes an already-built
  branch doesn't rewind it) and to `OPILOT_PD_IMPLEMENTED_STATUS` once the draft PR
  is open — a run that produced no code stays at the former, which is exactly what
  that status says. Both are best-effort and never fail a run that has already
  committed: a missing status is reported with the env var to set, a forbidden
  transition with its HTTP code, an already-current status skipped (re-asserting adds
  a journal entry saying nothing). That is also why the runner writes `plan.md` and
  `target_repos.json` itself — every downstream prompt and lookup expects them, so
  without them a pd PR would be the one opilot PR that can't explain itself.

`change-id` is author-supplied kebab-case (`[a-z0-9][a-z0-9-]*`), **validated rather
than sanitised** — it is the directory name everything downstream binds to, so
silently rewriting it would break the binding the operator thinks they made.

## The spec tree exists in three copies

`PD::ChangeStore` (`change_state.rb`) owns all movement between them:

- **canonical** — `.opilot/openspec/<repo>/`, a runner-owned `git init` repo. The
  durable copy, carrying its own commit identity since it is never pushed.
- **working** — `<clone>/openspec/`, the only place `pi-guards.ts` lets the LLM
  write, and where the `openspec` CLI expects the tree relative to the code.
- **review** — a `spec/<change-id>` branch pushed to the bot's fork.

A command materialises canonical → working on entry and persists working → canonical
on exit. Both mirror rather than merge, because an archive run *moves* a change
directory and a merge would resurrect it. `materialise!` also re-asserts `openspec/`
in the clone's `.git/info/exclude` on **every** call — `Helpers#commit` does
`add(all: true)`, so an unexcluded tree gets swept wholesale into an unrelated
bug-fix commit (the propose flow commits it deliberately with `git add -f`).

`tracker.json` is written to **both** copies by `PD::ChangeState#write_tracker` even
though only the runner writes it: the mirrors are wholesale (`rm_rf` + `cp_r`), so a
canonical-only write survived or vanished depending on which way the next mirror
happened to run — `intake` materialises afterwards and kept it, while a stage that
persists afterwards had the older working copy mirrored straight back over it.
`generate-wp` does exactly that, and lost `parent_wp` on every run, which is the way
to get a duplicate FEATURE.

## Attachments are converted in the runner, at intake time

`intake/converter.rb`. The harness container has no converter and `pi-guards.ts`
allows only read-only git, so the LLM's `read` tool is the sole way in — fine for
text, images and PDFs, useless on `.xlsx`/`.docx`/`.pptx`, which are ZIP-of-XML.
Spreadsheets go through `roo` to one **CSV per sheet** (500-row cap, with the
truncation written into the file itself); `.docx`/`.pptx` are extracted by hand with
rubyzip + nokogiri (both already pulled in by roo, and no maintained Ruby gem reads
`.pptx` at all) — pptx includes speaker notes, which often carry the actual
reasoning. PDFs, images and text pass through.

Legacy OLE formats (`.xls`/`.doc`/`.ppt`) and unknown types land in
**`unconvertible[]`**, recorded in `tracker.json` and in an
`intake/attachments/README.md` index, because a requirement hiding in a file nobody
could read is *missing* from the intake and that must be visible, not silent.

This is the one place opilot parses attacker-influenceable binary input inside the
trusted container, so it enforces a size cap, a zip entry-count cap, an inflated-size
cap and `Zip.validate_entry_sizes`, and isolates every failure per attachment.

## `openspec` runs in the runner, never in the harness container

`openspec.rb` — widening `pi-guards.ts` for a non-git binary would undo the
container's whole posture. `openspec init` always runs with `--tools none`, which
writes only `openspec/`: without it the CLI drops an `AGENTS.md` into the product
clone, over the real one OpenProject already has (and which its `CLAUDE.md` symlinks
to). Validation uses `--strict --json`, so failures come back structured for the
re-prompt loop rather than scraped from prose.

**The artifact format comes from the CLI, not from a paraphrase.** `--tools none`
suppresses the very mechanism OpenSpec normally uses to teach an agent its
conventions, so the format would otherwise live only in opilot's prompt — and
`validate --strict` is a weaker check than the format (it enforces delta structure
and scenarios, but not, say, whether `proposal.md` declares its `## Capabilities`),
so a hand-written version drifts with nothing noticing. It did: the first real run
produced a proposal with none of the template's four required headings and still
passed validation. So `PD::Runner#artifact_instructions` calls `openspec
instructions <artifact> --change <id>` for each of `proposal`/`specs`/`design`/
`tasks` (dependency order — proposal `<unlocks>` the rest) and drops the result
straight into `Prompts.propose`. Each block carries the CLI's own `<task>`,
`<instruction>`, `<template>` and output path — including the parts the paraphrase
had missed: the `## Capabilities` contract that tells the specs phase which spec
files to create, `RENAMED Requirements`, MODIFIED needing full content, REMOVED
needing `**Reason**`/`**Migration**`, and `skip_specs: true` for a change with no
spec-level behaviour. Two rewrites are applied: absolute paths (the CLI resolves them
against the runner) become `/repos/<name>` container paths, and unmet-dependency
`<warning>` blocks are stripped since nothing exists yet in a single pass. A CLI that
stops answering degrades to a note rather than failing the run.

## State on disk

```
.opilot/
├── changes/<op_host>/<change_id>/   # per-change cache (tracker.json lives in the store)
│   └── session_id / pr_url.txt / gh_pr.json / gh_session_id
├── openspec/<repo_name>/    # CANONICAL store — a runner-owned git repo
│   └── openspec/            #   config.yaml, specs/,
│                            #   changes/<change-id>/{proposal,design,tasks}.md
│                            #   + tracker.json (parent_wp, intake hash/selection, unconvertible[])
│                            #   + intake/ (documents as markdown, converted attachments)
└── repos/<repo_name>/openspec/   # WORKING copy, materialised per command; git-excluded
```

Work-package ids resolved by `pd init` are cached in
`work_packages/<op_host>/resolved-ids.json` (project, type ids, statuses +
`isClosed`).

## Env vars

`OPILOT_PD_PARENT_TYPE` / `OPILOT_PD_CHILD_TYPE` (default `FEATURE` /
`IMPLEMENTATION`) and `OPILOT_PD_IMPLEMENTING_STATUS` /
`OPILOT_PD_IMPLEMENTED_STATUS` (default `In progress` / `Developed`) — all resolved
by name, case-insensitively, at `pd init`. See the root `CLAUDE.md` for the full
`.env` table.
