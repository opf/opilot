# Split ingest from execution, behind a durable job queue

## Context

`CombinedAgent#run` ([combined_agent.rb:30](lib/opilot/combined_agent.rb:30)) runs
`gh.tick`, then `op.tick`, then `sleep 20`. Each `tick` polls **and** handles every
intent to completion. One handler can hold the loop for 45 minutes, because
`Harness#run` blocks on a streaming HTTP call. So the agent cannot see new work
while it works.

The goal is to poll and execute at the same time. One job at a time is enough now.

The direction is set by a stated future: **webhooks replace polling**, so the runner
gets an HTTP server. Two facts make that direction decide the design:

1. **Both webhook senders are at-most-once.** OpenProject's
   `Webhooks::Outgoing::RequestWebhookService` logs a non-2xx and swallows it; only
   a timeout is re-raised for good_job to retry. GitHub does not auto-redeliver. A
   delivery missed during a restart is gone forever, while a poll re-reads it.
   Therefore accepted work must be **durable on disk**, and the poller stays as a
   permanent reconciler.
2. **OpenProject's `work_package:comment` webhook carries the same activity id**
   that `Pull#build_comments` already caches. So comment-id identity costs nothing
   across the migration — no translation table.

The seam is therefore: **ingest → durable queue → worker**. The webhook receiver
later replaces one object, `PollIngest`. Nothing downstream changes.

### Polling stays

**This increment builds no webhook anything.** There is no open port, and
`compose.yml` publishes none. Polling remains the only ingest driver, at the same
`POLL_INTERVAL = 20`. Webhooks appear here only as a **shaping constraint**: they
decide that the queue is durable rather than in-memory, that a job's identity is a
comment id rather than a timestamp, and that the scan window lives inside the ingest
driver instead of being threaded through the seam. Every one of those is worth having
under polling alone.

The test the plan applies to each item: *would a webhook receiver have to rewrite
this?* If yes, shape it now. If no, defer it.

**Out of scope for this increment:** the HTTP server, published ports, signature
verification, per-project webhook enablement, parallel workers, and moving the
poller's outbound API calls (👀, refusal notes, CI log downloads) off the ingest
side.

**What the later webhook step then costs**, given this plan lands: a new
`WebhookIngest` that verifies a signature, computes the same `key`/`scope`, and calls
the same `#submit`. Plus the deployment work — a port, a `CMD` in `Dockerfile.runner`,
and moving from `docker compose run --rm` ([opilot:388](opilot:388)) to a long-running
service. Note for that day: OpenProject refuses to POST to a private IP unless the
target is in `OPENPROJECT_SSRF_PROTECTION_IP_ALLOWLIST`.

---

## What this pattern is called

Nothing here is novel. Each layer has a name, and reviewers should read it by those
names rather than deriving it.

| Layer | Pattern |
|---|---|
| The seam | **Producer–Consumer** over a point-to-point channel. **Competing Consumers** once there is a second worker |
| Why a queue | **Queue-Based Load Levelling** — arrival rate and service rate differ by three orders of magnitude |
| The storage | **Maildir**, exactly: write to `tmp/`, hard-link into `ready/`, rename onward. Designed for reliable handoff on a plain filesystem with no lock manager |
| `failed/` | **Dead Letter Channel** |
| The claim | **Claim-by-rename**, the directory-as-mutex. `rename(2)` is the test-and-set, and it behaves the same across threads and processes |
| Dedup | **Idempotency Key** plus **Idempotent Receiver**. The key is content-derived, never transport-derived |
| Delivery | **At-least-once.** Exactly-once effect comes from the idempotent receiver — the standard trade |
| The scope rule | **Partition-key serialization**: one job in flight per work package, unordered across work packages |
| Reclaim | **Orphan sweep** — a degenerate visibility timeout, resolved at startup because `agent.lock` guarantees one agent |
| The ingest swap | **Ports and Adapters.** `PollIngest` and the later `WebhookIngest` are two adapters on one port |
| Polling's future | **Level-triggered reconciliation** (the Kubernetes controller pattern) |

The last row is the sharpest one, and it is why the poller never goes away. Webhooks
are **edge-triggered**: you are told once, and a missed delivery is lost — that is
what at-most-once means. Polling is **level-triggered**: it observes current state, so
a missed event costs latency, not correctness. The guidance is *edge-triggered,
level-driven* — events for speed, a reconciler for truth. Webhooks stop being the
trigger and become the fast path; the poller becomes the safety net.

## Decisions taken

| Decision | Choice |
|---|---|
| Queue | Durable directory under `.opilot/`, not `Thread::Queue` |
| Claim | `File.rename` — works the same across threads and across processes |
| Ack | At accept, and again at completion. Both idempotent |
| Burst on one item | Defer, do not drop: one job in flight per scope, enforced at claim |
| Crash | Reclaim all of `running/` at startup, `attempts` capped at 2, then `failed/` |
| Ctrl-C | Abort, do not drain. The queue makes that safe |
| Worker count | One. `server.js` still serializes pi, and the clones are single-tenant |
| Job object | Fresh `Agent`/`GhAgent` per job |

---

## Step 0 — Hardening (own commit, no behaviour change today)

These are latent bugs that the split promotes to real ones.

- **[pull.rb:569](lib/opilot/pull.rb:569)** `mark_opilot_acted` **assigns**
  `last_acted_comment_at`. `GhPull#mark_acted` ([gh_pull.rb:104](lib/opilot/gh_pull.rb:104))
  already takes `max`. Make the OP side match. A backwards cutoff replays a handled
  `build`.
- **[gh_pull.rb:133](lib/opilot/gh_pull.rb:133)** `mark_ci_acted` does
  `ci_attempts += 1`. Acking twice burns `OPILOT_CI_MAX_ATTEMPTS` at double rate.
  Return early when `state["ci_acted_sha"] == head_sha`.
- **Non-atomic writes to `item.json`.** Three plain read-modify-write sites:
  [pull.rb:423](lib/opilot/pull.rb:423) (wholesale mirror rewrite),
  [pull.rb:69](lib/opilot/pull.rb:69) (`refusal_noted_at`),
  [pull.rb:574](lib/opilot/pull.rb:574) (the ack). Route all through
  `Helpers.write_json_atomic` ([helpers.rb:492](lib/opilot/helpers.rb:492)), and add
  a per-path mutex:

  ```ruby
  Helpers.file_lock(path)            # memoized Mutex, guarded by one registry Mutex
  Helpers.update_json(path, name)    # lock + safe_json_read + yield + write_json_atomic
  ```

  Atomic writes stop torn reads. The lock stops lost updates, which is the failure
  once ingest and worker both write.
- **`Helpers::LOG_LOCK`.** `log_script` ([helpers.rb:675](lib/opilot/helpers.rb:675))
  does three writes per line; `Harness#log_append`
  ([harness.rb:347](lib/opilot/harness.rb:347)) appends during a 45-minute stream.
  Take the lock in both, or poll lines land inside a streamed response in
  `chomp.log`.
- **[pull.rb:203](lib/opilot/pull.rb:203)** `$stdin.gets.chomp` raises
  `NoMethodError` on a closed stdin. `GhAgent#prompt_scan_from`
  ([gh_agent.rb:371](lib/opilot/gh_agent.rb:371)) already uses `.to_s.chomp`. Fix it,
  and skip the prompt when `!$stdin.tty?`, taking the saved watermark. This is what
  makes a headless start possible later.

---

## Step 1 — Webhook-ready identity

### `Intent#comment_id`

Add the member to the Struct at [agent.rb:10](lib/opilot/agent.rb:10) and set it in
`Pull#intent_from_comments` ([pull.rb:303](lib/opilot/pull.rb:303)). The value is
already in hand — `react_eyes(trigger["id"])` uses it. No new API call.

### `created_wps.json` dual-key read — ship in the same commit

`Agent#records_for` ([agent.rb:597](lib/opilot/agent.rb:597)) matches
`r["comment_at"] == comment_at.to_s` with exact string equality. This is the only
guard against creating work packages twice, and a work package can never be deleted.

- `record_created_wp` ([agent.rb:607](lib/opilot/agent.rb:607)) writes **both**
  `comment_id` and `comment_at`.
- `records_for` matches on `comment_id` when the intent and the record both carry
  one, and falls back to `comment_at` otherwise. Legacy records keep working.

Splitting this from `Intent#comment_id` is the irreversible-duplication bug. Do not.

### OP act-state moves to `op_wp.json`

New sibling of `item.json`, written only through `Helpers.update_json`. It is
`gh_pr.json` for OpenProject:

```json
{ "last_acted_comment_at": "<ISO8601, always max()>",
  "handled_comment_ids":   ["...", "..."],
  "refusal_noted_at":      "...",
  "create_wp_refusal_noted_at": "..." }
```

- The **floor** compacts; the **id set** is exact and order-independent. The floor
  bounds the set, so `.last(200)` (the cap `append_opilot_comment` already uses at
  [gh_pr_cache.rb:87](lib/opilot/gh_pr_cache.rb:87)) is not a correctness hole.
- Add `Helpers.op_state(dir)` / `Helpers.update_op_state(dir)`, mirroring
  `GhPrCache#gh_state` / `#update_gh_state` ([gh_pr_cache.rb:61](lib/opilot/gh_pr_cache.rb:61)).
- **Seed on first touch** from `item.json`'s `CARRIED_KEYS`
  ([pull.rb:366](lib/opilot/pull.rb:366)), so no existing state is lost.
- Readers move: `opilot_trigger_comment` ([pull.rb:491](lib/opilot/pull.rb:491)),
  `note_refused_trigger` ([pull.rb:52](lib/opilot/pull.rb:52)),
  `Agent#note_create_wp_disabled`.
- `CARRIED_KEYS` stays in `fetch_work_package_item` for one release. It then carries
  values nothing reads, which is harmless and keeps a rollback possible. Retire it
  after.
- `PICTURE_KEYS` stays. It is real mirror state.

`gh_pr.json` gains `handled_comment_ids`, **distinct** from `opilot_comment_ids`.
The two mean different things — "opilot handled this trigger" and "opilot wrote this
comment" — and merging them would read a reply as a handled trigger.

---

## Step 2 — `lib/opilot/job_queue.rb` (new)

### No new container, and no broker

Nothing in `compose.yml`, `Dockerfile.runner` or the port configuration changes. The
queue is a directory inside the `.opilot/` tree, and `Helpers.write_json_atomic`
([helpers.rb:492](lib/opilot/helpers.rb:492)) already renames a tempfile on the same
bind mount, so the queue adds no new assumption about the filesystem.

A broker such as RabbitMQ is the wrong tool here:

- **It would be a second source of truth.** Correctness lives in the files anyway —
  `handled_comment_ids`, `last_acted_comment_at`, `created_wps.json`, `gh_pr.json`.
  A broker holding the job beside files holding "was this already done" gives two
  records that can disagree.
- **The volume is a handful of jobs a day**, with one worker and minutes per job. A
  message never waits.
- **It costs a container, a gem and a credential**, plus state to back up and
  upgrade. Today `./opilot reset` deletes `.opilot/` and the machine is clean.
- **Durability must be re-earned** through a durable queue, persistent messages,
  publisher confirms and manual acks — configuration that is wrong until checked.
- **A directory is readable.** `ls ready/` and `cat` answer what is queued, the way
  `progress.txt` and `item.json` answer everything else here.

It also buys nothing for webhooks: the receiver runs in the same process and calls
`#submit` directly.

Revisit only for ingest and workers on separate machines, many workers, or real
fan-out and dead-letter routing. `submit` / `claim` / `complete` / `fail` is already
a broker's interface, so the swap stays inside one file. SQLite is the middle rung if
the directory ever creaks first.


```
.opilot/queue/<op_host>/
├── ready/<enqueued_at>-<seq>-<sha256(key)[0,12]>.json
├── running/   (same filename)
└── failed/    (same filename)
```

The filename prefix is an ISO8601 timestamp with milliseconds plus a per-process
counter, so lexicographic order is FIFO order. `GhPull` already sorts fresh
comments oldest-first, and same-millisecond submits would otherwise collide.
Hash the key rather than slugifying it — `Helpers.slugify` maps
`openproject/openproject` and `openproject-openproject` to one name.

Envelope:

```json
{ "id": "...", "source": "op" | "gh", "attempts": 0,
  "enqueued_at": "...", "key": "...", "scope": "...",
  "intent": { "...Struct#to_h..." } }
```

### Identity

| Source | `key` | `scope` |
|---|---|---|
| OP comment | `op:<item_id>:c:<comment_id>` | `op:<item_id>` |
| GH thread comment | `gh:<repo>#<n>:issue:<comment_id>` | `gh:<repo>#<n>` |
| GH review comment | `gh:<repo>#<n>:review:<comment_id>` | `gh:<repo>#<n>` |
| GH CI | `gh:<repo>#<n>:ci:<head_sha>` | `gh:<repo>#<n>` |

Two traps to encode in the key function:

- **`kind` must be in the key.** GitHub issue-comment ids and review-comment ids are
  different id spaces. `GhPrCache#fresh_mentions`
  ([gh_pr_cache.rb:25](lib/opilot/gh_pr_cache.rb:25)) already merges them into one
  array; a collision is latent today and becomes a wrong dedup under a durable key.
- **A `:ci` intent must never key on `comment_at`.**
  `GhPull#ci_intent_for_dir` ([gh_pull.rb:238](lib/opilot/gh_pull.rb:238)) sets
  `comment_at: Time.now.utc.iso8601`, so a uniform timestamp key produces one new
  CI job per tick, forever. `head_sha` is the identity.

### Codec

`Intent` and `GhIntent` are keyword-init Structs of scalars, so `to_h` → JSON round
trips. One trap: **JSON has no Symbols.** Re-symbolize on decode, by an explicit
list, never by blanket `to_sym`:

```ruby
SYMBOL_FIELDS = { "op" => %i[command], "gh" => %i[kind command] }.freeze
```

`Intent#type` is a work-package type *name* and must stay a String.

### Operations

| Method | Behaviour |
|---|---|
| `#submit(source, intent, key:)` | Write the envelope in full to `tmp/<name>.json`, then `File.link` it into `ready/`, then unlink the tmp. `Errno::EEXIST` on the link means a duplicate key — return `false`. **No scope check here.** |
| `#claim` | Walk `Dir.children(ready/).sort` and take the first entry whose `scope` is **not** present in `running/`, by `File.rename` into `running/`. `Errno::ENOENT` means another claimer won — try the next. Stamps `claimed_at`. |
| `#complete(job)` | Unlink from `running/`. |
| `#fail(job)` | `attempts + 1`; back to `ready/` under the cap, else `failed/` with a log line. |
| `#recover_orphans!` | At startup, move **every** `running/` entry back to `ready/` with `attempts + 1`, and delete every stale `tmp/` entry. |
| `#depth`, `#running?` | For the poll log line and the tty heartbeat. |

Three properties this shape has that the obvious version does not:

- **Write-then-link, not `CREAT|EXCL`-then-write.** `CREAT|EXCL` followed by a write
  is *not* crash-safe: a crash mid-write leaves truncated JSON in `ready/`, and the
  claim then reads a broken job. Maildir's `tmp/` → `link()` → unlink gives atomic
  appearance **and** keeps `EEXIST` as the dedup signal. `rename` would give
  atomicity but silently overwrite, losing dedup.
- **Scope is enforced at claim, not at submit.** A scope check inside `#submit` is
  check-then-act: two producers (the poller now, a webhook receiver later) can both
  scan, both find nothing, and both write different keys with the same scope. Only
  the claimer knows what is actually in flight, so the rule belongs there.
  `#claim` must **skip past** a blocked entry and take the next eligible one — stopping
  at the head would let one long job block every other work package, which is the
  exact failure this whole change removes.
- **Reclaim takes everything, and checks no pid.** A pid recorded inside a container
  is meaningless after a restart: the new container starts a fresh pid namespace, so
  a stale `claimed_by: 42` can match a live pid 42 and the job is never reclaimed.
  `.opilot/agent.lock` ([opilot:63](opilot:63)) already guarantees one agent per state
  directory, so at startup there cannot be a competing worker and unconditional
  reclaim is correct. **Parallel workers will need a real lease** (heartbeat plus TTL);
  say so at the method, so worker #2 does not inherit this assumption silently.

**Behaviour note, against the option chosen during planning.** With scope enforced at
claim, a blocked trigger is enqueued **and acked**, and waits in `ready/`. The
approved sketch showed it rejected and left unacked, to be re-polled. The visible
outcome is the same or better: the work is durably captured instead of depending on a
later poll, and it still runs exactly once, after the busy scope clears.

### Resiliency

| Failure | Result |
|---|---|
| Crash mid-write | The partial file is in `tmp/`, never linked. Startup deletes it |
| Crash after link, before ack | The job is durable. The next poll recomputes the key, hits `EEXIST`, skips, and does not ack. Completion acks |
| Crash mid-job | `running/` entry reclaimed at startup, `attempts + 1` |
| Job crashes the process every time | Quarantined to `failed/` after the cap, with a log line |
| Handler raises | Rescued by `guarded_tick`, acked, completed. Today's policy, unchanged. **Only a process death retries** |
| Unparseable job file | Moved to `failed/` with a log line. Never crash the worker, never spin on it |
| Disk full on submit | `ENOSPC` propagates to the tick's `guarded_tick`. The trigger is **not** acked, so the next poll retries it. Correct by construction |
| Queue directory missing (`./opilot reset` mid-run) | Fatal, with a clear message. Not a `guarded_tick` loop that logs forever |
| Clock jumps backwards | FIFO order across scopes is disturbed. Accepted: order only matters within a scope, and one scope has one job in flight |
| Two agents despite the lock | Key dedup still holds — `File.link` is atomic across processes. Two workers on one scope is the hazard the lock already exists to prevent, and is not made worse |

`File.rename` and `File.link` are the whole mechanism on purpose. Both behave the same
across threads and across processes, so a webhook receiver process needs nothing new.
`Helpers.write_json_atomic` ([helpers.rb:492](lib/opilot/helpers.rb:492)) already
depends on same-directory `rename` over the same bind mount, so this adds no new
assumption about the filesystem.

---

## Step 3 — `PollIngest`, `Worker`, and a rewritten `CombinedAgent`

### `lib/opilot/poll_ingest.rb` (new)

Owns `Pull`, `GhPull`, `UpstreamGhPull` and both scan windows.

- `#start` — the bodies of `Agent#setup` ([agent.rb:41](lib/opilot/agent.rb:41)) and
  `GhAgent#setup` ([gh_agent.rb:51](lib/opilot/gh_agent.rb:51)), GitHub first, so both
  prompts resolve before the loop. Keeps `ensure_bot_identity!`, the allowlist
  banners and `report_mcp_status`.
- `#poll_once` — the bodies of `Agent#tick` and `GhAgent#tick` **minus**
  `intents.each { handle_and_ack }`. Yields `(source, intent, key, scope)` with an
  ack block.
- `scan_from_at` becomes an ivar here. **Nothing outside this file knows a scan
  window exists.** That is what makes `WebhookIngest` a swap rather than a rewrite.
- Suppress `each_page`'s `\r` tty heartbeat while `queue.running?` — it scribbles
  over the worker's streamed output, and it exists only to prove a silent poll is
  not hung.

### `lib/opilot/worker.rb` (new)

- `#run_once` — `claim` → build a **fresh** `Agent`/`GhAgent` → `handle_job` inside
  the existing `guarded_tick` ([helpers.rb:696](lib/opilot/helpers.rb:696)) → ack →
  `complete`, or `fail` on a crash.
- `#loop_forever` — `loop { run_once; sleep 1 unless worked }`. No doorbell: a
  `ConditionVariable` breaks the day ingest moves out of process, and 1 second
  against a 45-minute job is not a cost.
- `MAX_CONCURRENCY = 1`, with the three reasons at the constant: `server.js` is one
  global `busy` flag ([server.js:188](server.js:188)); `Harness::READ_TIMEOUT`
  ([harness.rb:83](lib/opilot/harness.rb:83)) is only correct because of that; and
  every clone at `.opilot/repos/<name>` is single-tenant.

**A fresh instance per job is what deletes the shared-state problem.**
`@requester` / `@reply_internal` ([agent.rb:93](lib/opilot/agent.rb:93)) are read by
`#addressed` at ~25 sites; threading them through as parameters is a large, risky
diff. Object lifetime = job lifetime is correct with no refactor. The cost is near
zero: `Agent` touches `@pull` only in `setup`/`tick`/`ack`, so the expensive
`/users/me` memo is never warmed on the worker path.

### `lib/opilot/combined_agent.rb` (rewritten, ~60 lines)

```ruby
def run
  ensure_harness!
  @queue.recover_orphans!
  @ingest.start                                  # prompts — main thread
  @worker_thread = Thread.new { @worker.loop_forever }
  @worker_thread.name = "opilot-worker"
  @worker_thread.report_on_exception = true

  loop do
    supervise_worker!
    guarded_tick("Ingest") { @ingest.poll_once { |*args, &ack| accept(*args, &ack) } }
    sleep POLL_INTERVAL
  end
end

def accept(source, intent, key:, scope:, &ack)
  return false unless @queue.submit(source, intent, key: key, scope: scope)
  ack&.call          # enqueue first, then ack. A webhook driver passes no block.
  true
end
```

- **Ingest stays on the main thread.** The scan prompt reads `$stdin`, and
  [bin/opilot:48](bin/opilot:48) traps INT/TERM and calls `exit`, which raises
  `SystemExit` in the main thread. Signal behaviour is unchanged.
- **A dead worker is fatal.** `supervise_worker!` exits 70 with a log line. Otherwise
  ingest keeps acking triggers while `ready/` grows and nothing runs — every trigger
  would look handled to OpenProject.
- **Ack at accept, and again at completion.** Ack-at-completion has no meaning under
  webhooks, where there is no cutoff to advance. Acking twice is safe because Step 0
  made both acks idempotent (`max`, and the id set).
- **Ack exactly the intent that was enqueued**, never the tick's maximum. For fresh
  comments `c1 < c2 < c3` where only `c1` was enqueued, acking `c3` would silently
  drop the other two.
- The class comment currently argues **for** single-threading. Replace it.
- **Ctrl-C aborts, and `bin/opilot` does not change.** A 45-minute job cannot be
  waited out. `#recover_orphans!` retries the aborted job on the next start, which is
  today's invariant reached by a different mechanism.

### `lib/opilot/cli.rb`

`agent`, `agent op`, `agent gh` and the `op-agent` / `gh-agent` aliases
([cli.rb:26](lib/opilot/cli.rb:26), [cli.rb:69](lib/opilot/cli.rb:69)) all route to
`CombinedAgent.new(@ctx, sources: …).run`. `Agent#run` / `GhAgent#run` are deleted.
Leaving them would give `agent op` ack-at-completion while `agent` gets
ack-at-ingest — two ack rules in one repo is a correctness trap.

`Agent#handle_and_ack` and `GhAgent#handle_and_ack` become `#handle_job` — rescue and
log, no ack. **Do not harmonize them**: `GhAgent` posts an error comment on the PR
and `Agent` deliberately does not.

---

## Files

| File | Change |
|---|---|
| `lib/opilot/job_queue.rb` | New. Queue, `Job`, codec, key/scope functions |
| `lib/opilot/poll_ingest.rb` | New. Owns the pollers and the scan windows |
| `lib/opilot/worker.rb` | New. Claim, build, handle, ack, complete |
| `lib/opilot/combined_agent.rb` | Rewritten |
| `lib/opilot/agent.rb` | `Intent#comment_id`; delete `run`/`setup`/`tick`; `handle_job`; `records_for`/`record_created_wp` dual key |
| `lib/opilot/gh_agent.rb` | Delete `run`/`setup`/`tick`/`sources`/the scan prompt; `handle_job` |
| `lib/opilot/pull.rb` | `max` ack; `op_wp.json`; atomic + locked writes; non-tty scan; set `comment_id` |
| `lib/opilot/gh_pull.rb` | Idempotent `mark_ci_acted` |
| `lib/opilot/gh_pr_cache.rb` | `update_gh_state` under the file lock; `handled_comment_ids` |
| `lib/opilot/helpers.rb` | `file_lock`, `update_json`, `op_state`/`update_op_state`, `LOG_LOCK` |
| `lib/opilot/harness.rb` | `log_append` under `LOG_LOCK` |
| `bin/opilot` | Require the three new files |
| `CLAUDE.md` | `.opilot/` tree gains `queue/`; module table gains three rows; the "written only *after* a handler finishes" rule and the single-threading rationale both change |
| `TODO.md` | Name `PollIngest` as the object `WebhookIngest` replaces |

Keep the new comments to a few lines each.

---

## Tests

**`test/opilot/job_queue_test.rb` (new)** — the highest-value file. Needs only
`build_ctx` from [test/support/fixtures.rb](test/support/fixtures.rb).

- FIFO across three submits in one millisecond (proves the counter).
- Round-trip `Intent` and `GhIntent` and `assert_equal` the whole struct — this
  catches the Symbol/String trap on `command` and `kind`.
- `submit` returns `false` on a duplicate `key`, and on a duplicate `scope` with a
  different `key`.
- `claim` on empty returns `nil`; `complete` removes the file.
- `recover_orphans!` requeues with `attempts + 1`; at the cap it lands in `failed/`.
- **Two `JobQueue` instances over one directory**, three jobs, alternating `claim` —
  each job returns exactly once. No threads. This is the proof that a separate
  webhook receiver process will work.

**`test/opilot/combined_agent_test.rb` (rewritten).** `FakeLoop` becomes a fake
ingest plus a handler factory, over a **real** `JobQueue`.

- GitHub `start` precedes OpenProject `start` (existing assertion, kept).
- OpenProject only when `contributor_token` is nil (existing, kept).
- `poll_once` enqueues and then acks; `ready/` holds one entry.
- A second `poll_once` while the job is in `running/` neither re-enqueues nor acks.
- `Worker#run_once` handles, acks again, and empties `running/`.
- A handler that raises leaves the worker alive and still acks.
- Exactly **one** test starts the real thread, with
  `ensure { @worker_thread.kill; @worker_thread.join(2) }`. A leaked worker over a
  removed `Dir.mktmpdir` hangs the suite.

**Additions:** `pull_test.rb` — an older ack never regresses the floor; the non-tty
path reads no stdin; `op_wp.json` seeds from `CARRIED_KEYS`; `records_for` matches a
legacy `comment_at`-only record. `gh_pull_test.rb` — `mark_ci_acted` twice on one
`head_sha` increments `ci_attempts` once. `gh_agent_test.rb` — mechanical rename of
seven `handle_and_ack` sites. `agent_test.rb` needs no change; it already calls
`@agent.handle` directly.

---

## Verification

```bash
docker compose run --no-deps --rm runner bundle exec rake
```

Then end to end, which is the only way to see the actual goal:

```bash
./opilot agent
```

1. Comment `@opilot build` on a test work package. Confirm one file appears in
   `.opilot/queue/<host>/ready/`, then moves to `running/`.
2. **While the job runs**, confirm the poll log line keeps appearing every 20
   seconds. That is the whole point of the change, and today it stops.
3. Comment again on the **same** work package while it runs. Confirm no second file
   appears (the scope rule), and confirm the trigger is handled after the first job
   ends (it was never acked).
4. Comment on a **different** work package while the first runs. Confirm a second
   file appears in `ready/` and runs after the first.
5. Ctrl-C mid-job. Restart. Confirm `recover_orphans!` moves the job back to
   `ready/` and it runs again.
6. Confirm `chomp.log` has no poll line spliced inside a streamed response.
