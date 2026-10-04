# Add rootless-Podman support to chomper, alongside Docker

## Context

This project runs an AI coding agent (the `harness` container) against untrusted,
attacker-influenceable content (OpenProject work-package text). Docker's root
daemon is a bigger blast-radius risk than necessary for that threat model: a
container escape under Docker's rootful architecture has a plausible path to a
root process controlling every other container on the host. Rootless Podman
removes that daemon entirely — an escape lands as an unprivileged host UID
that owns nothing, not root.

Decisions made with the user (do not re-litigate):
- **podman-compose**, not the Docker-Compose-v2-CLI-over-Podman-socket
  approach — smaller trust footprint (no Docker-authored binary, no
  persistent listening socket), and a cleaner per-service fix for the
  rootless UID problem than the socket approach can offer.
- **Rootless Podman**, not rootful.
- **Dual-engine support, not a one-way cutover.** `./chomper` detects
  whichever of `podman-compose`/`docker` is installed and adapts; both keep
  working. This costs one small extra compose file and a handful of
  conditional branches in `./chomper` (detailed below) — bounded, not a
  rewrite.
- **Deployment target is Ubuntu 26.04 LTS ("Resolute Raccoon").** It ships
  **podman-compose 1.5.0-2** in its own default repos — no extra repo, no
  pinning. That version already fixes one of the two real podman-compose
  bugs found during planning (see below); the other is worked around in
  `./chomper` directly, scoped to only the Podman branch.

**Verified directly against podman-compose 1.5.0's source** (extracted from
the actual PyPI wheel Ubuntu's package is built from, after GitHub's
raw-content endpoint rate-limited mid-session):
1. Healthcheck `CMD`-array handling is already correct in 1.5.0 — it builds
   `--healthcheck-command` from `json.dumps(healthcheck_test)` directly, no
   shell-mangling. **No `compose.yml` healthcheck edit needed.**
2. **`--wait` does not exist** anywhere in 1.5.0's argument parser (grepped
   the full source) — only from 1.6.0 onward, which Ubuntu 26.04 doesn't
   ship. The Podman branch of `./chomper` needs a light poll loop instead;
   the Docker branch keeps native `--wait` unchanged, since it already works
   there today.
3. `podman-compose run` has no `--remove-orphans` (only `up`/`down` do), and
   `--progress` doesn't exist anywhere in podman-compose. Both are dropped
   **only on the Podman branch** of the two `dc run ...` call sites — the
   Docker branch keeps them exactly as they work today.

**Verified against Podman's own `--userns=keep-id` behavior**
([containers/podman#24934](https://github.com/containers/podman/issues/24934),
a real bug report with a reproduced example): `--userns=keep-id:uid=N,gid=N`
does two things at once — it maps the invoking host user (whatever their
real UID actually is) to container UID `N` for bind-mount ownership
purposes, *and* it forces the container's main process to run as UID `N`,
overriding the image's own default user. That second effect is what lets
this migration drop `CHOMPER_UID`/`CHOMPER_GID` entirely from the Podman
path: instead of threading the real host UID through `id -u`/`id -g` and a
`${CHOMPER_UID}` template, the Podman overlay just hardcodes
`userns_mode: "keep-id:uid=1000,gid=1000"` on both `runner` and `harness`,
and it works identically for any invoking host user. `CHOMPER_UID`/
`CHOMPER_GID` survive in `./chomper` only because the **Docker** branch still
needs them (Docker has no `keep-id` equivalent — it sets the container UID
directly with no remap layer, so it still needs to know the real host UID).

**One deliberate, small behavior change to flag plainly, not bury**: under
Podman, `runner` will always run as uid 1000, not root (its current Docker
default when `CHOMPER_UID` is unset). Nothing in `runner` — git, bundler,
ruby — needs actual root; this is a minor hardening side-effect of picking
one fixed non-root UID for both services under Podman, not an accident.

## Approach

### 1. Package installation (Ubuntu 26.04) — plain apt install

```bash
sudo apt update
sudo apt install -y podman podman-compose uidmap slirp4netns passt
```

Rootless prerequisites (subuid/subgid ranges for the deploying user):
```bash
grep -q "^$(id -un):" /etc/subuid && grep -q "^$(id -un):" /etc/subgid \
  || sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 "$(id -un)"
```

### 2. `compose.yml` — one small, engine-neutral addition; nothing else changes

```yaml
name: chomper
```
at the top, alongside `x-hardened`. Pins the Compose project name so
container/network naming (and the label-based lookup the new Podman wait
loop uses) is deterministic regardless of checkout directory — a standard
Compose Spec field, harmless and correctly read by both engines. Everything
else in `compose.yml` (the `user:` fields with `${CHOMPER_UID}`/
`${CHOMPER_GID}`, healthchecks, `cap_drop`, `read_only`, networks) stays
exactly as it is today — still needed for the Docker branch.

### 3. New file: `compose.podman.yml` (Podman-only overlay)

```yaml
x-podman:
  in_pod: false

services:
  runner:
    user: "1000:1000"
    userns_mode: "keep-id:uid=1000,gid=1000"
  harness:
    user: "1000:1000"
    userns_mode: "keep-id:uid=1000,gid=1000"
```

- `x-podman.in_pod: false` stops podman-compose from grouping all services
  into one shared pod (its default) — a shared pod has one user namespace,
  and applying `--userns` per-service inside a pod is a hard Podman error.
  Documented, confirmed-working fix (containers/podman-compose#654).
- `user: "1000:1000"` here is a literal override of the base file's
  `${CHOMPER_UID}`-templated value — when both `-f compose.yml -f
  compose.podman.yml` are loaded, this later file's scalar value wins, so
  the Podman branch always runs both containers as uid 1000 regardless of
  what the invoking host user's real UID is.
- `authgw`/`proxy` are intentionally absent — neither has a `user:`
  override or bind mounts today, so there's no ownership problem to solve
  for them.

No Dockerfile changes, no healthcheck changes (already correct in 1.5.0).

### 4. `chomper` (wrapper script) — engine detection, then a handful of scoped branches

Reference: current script read in full, edits keyed to today's line numbers.

- **Line 22** (`dc() { docker compose -f "$SCRIPT_DIR/compose.yml" "$@"; }`):
  replace with detection, placed right after `SCRIPT_DIR` is exported:
  ```bash
  if command -v podman-compose >/dev/null 2>&1; then
    ENGINE=podman
    dc() { podman-compose -f "$SCRIPT_DIR/compose.yml" -f "$SCRIPT_DIR/compose.podman.yml" "$@"; }
  elif command -v docker >/dev/null 2>&1; then
    ENGINE=docker
    dc() { docker compose -f "$SCRIPT_DIR/compose.yml" "$@"; }
  else
    echo "chomper: neither podman-compose nor docker found on PATH." >&2
    echo "  On Ubuntu: sudo apt install podman podman-compose uidmap slirp4netns passt" >&2
    exit 1
  fi
  ```

- **New rootless preflight**, only when `ENGINE=podman`, placed right after
  the block above:
  ```bash
  if [ "$ENGINE" = podman ]; then
    if [ "$(id -u)" -eq 0 ]; then
      echo "chomper: refusing to run as root — this stack is designed for rootless Podman." >&2
      exit 1
    fi
    if ! grep -q "^$(id -un):" /etc/subuid 2>/dev/null || ! grep -q "^$(id -un):" /etc/subgid 2>/dev/null; then
      echo "chomper: no subuid/subgid range for $(id -un). Run:" >&2
      echo "  sudo usermod --add-subuids 200000-265535 --add-subgids 200000-265535 $(id -un)" >&2
      exit 1
    fi
  fi
  ```

- **New `_wait_healthy_podman` function** (Podman branch only — Docker keeps
  native `--wait`), added alongside the other helpers. Deliberately minimal
  per the "stay light" direction — a plain status poll with a timeout, no
  active healthcheck invocation, no separate unhealthy fast-path, and no
  restart-on-crash behavior (none exists today; this migration doesn't add
  any):
  ```bash
  # podman-compose 1.5.0 (Ubuntu 26.04's shipped version) has no --wait.
  _wait_healthy_podman() {
    local svc cid waited
    for svc in "$@"; do
      cid="$(podman ps -a --filter "label=com.docker.compose.project=chomper" \
                          --filter "label=com.docker.compose.service=$svc" \
                          --format '{{.ID}}' | head -n1)"
      [ -z "$cid" ] && { echo "chomper: '$svc' container not found after 'up' — see: dc ps" >&2; exit 1; }
      waited=0
      until [ "$(podman inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null)" = healthy ]; do
        waited=$((waited + 1))
        [ "$waited" -ge 60 ] && { echo "chomper: timed out (60s) waiting for '$svc' — see: podman logs $cid" >&2; exit 1; }
        sleep 1
      done
    done
  }
  ```

- **Lines 226–230** (the `_needs_harness`/`_needs_authgw` branch): branch on
  `$ENGINE` — Docker keeps `--wait` exactly as today, Podman drops it and
  calls the new function after the trap is registered:
  ```bash
  if _needs_harness; then
    if [ "$ENGINE" = podman ]; then
      dc up -d --remove-orphans authgw harness
      trap 'dc stop harness proxy authgw 2>/dev/null || true' EXIT INT TERM
      _wait_healthy_podman authgw harness
    else
      dc up -d --wait --remove-orphans authgw harness
      trap 'dc stop harness proxy authgw 2>/dev/null || true' EXIT INT TERM
    fi
  else
    if [ "$ENGINE" = podman ]; then
      dc up -d --remove-orphans authgw
      trap 'dc stop authgw 2>/dev/null || true' EXIT INT TERM
      _wait_healthy_podman authgw
    else
      dc up -d --wait --remove-orphans authgw
      trap 'dc stop authgw 2>/dev/null || true' EXIT INT TERM
    fi
  fi
  ```

- **Line 213** (`done < <(dc --progress quiet run --no-deps --rm runner ruby bin/repos list)`):
  `--progress` doesn't exist in podman-compose; the Docker branch keeps it
  unchanged since it works today.
  ```bash
  if [ "$ENGINE" = podman ]; then
    dc build runner >&2
    done < <(dc run --no-deps --rm runner ruby bin/repos list)
  else
    done < <(dc --progress quiet run --no-deps --rm runner ruby bin/repos list)
  fi
  ```
  (the explicit `dc build runner >&2` keeps build chatter out of the piped
  stdout the `while IFS='|' read` loop parses, replacing what `--progress
  quiet` did for Docker)

- **Line 233** (`dc --progress quiet run --no-deps --rm --remove-orphans runner ruby "$SCRIPT_DIR/bin/chomper" "$@"`):
  same split — `--progress`/`--remove-orphans` aren't valid on
  podman-compose's `run`, but keep working on Docker's:
  ```bash
  if [ "$ENGINE" = podman ]; then
    dc run --no-deps --rm runner ruby "$SCRIPT_DIR/bin/chomper" "$@"
  else
    dc --progress quiet run --no-deps --rm --remove-orphans runner ruby "$SCRIPT_DIR/bin/chomper" "$@"
  fi
  ```

- **`CHOMPER_UID`/`CHOMPER_GID`** (lines 147–148): **unchanged** — still
  exported via `id -u`/`id -g`, still needed by the Docker branch's
  `${CHOMPER_UID}`/`${CHOMPER_GID}` templates in `compose.yml`. Under Podman
  they're harmlessly ignored for `runner`/`harness` (the overlay's literal
  `user: "1000:1000"` wins), so no behavior depends on them there.

### 5. Doc and error-string updates (mechanical, no behavior change)

| File | Change |
|---|---|
| `README.md:35` | `- **Docker**` → `- **Docker** or **Podman** (rootless) — either engine works; Podman needs \`apt install podman podman-compose uidmap slirp4netns passt\` on Ubuntu 26.04` |
| `README.md:76,78` | ASCII diagram: mention both engines, or genericize to "Compose" — keep whichever reads cleaner in context |
| `README.md:110` | `internal: true Docker network` → `internal: true network` (engine-neutral, true either way) |
| `README.md:310,316,322-323` | dev commands: note they work unchanged with either engine via `./chomper`'s own `dc()`, or show the direct `podman-compose -f compose.yml -f compose.podman.yml run ...` form as the Podman equivalent of the existing `docker compose run ...` examples |
| `README.md:335` | update the TODO — from "Switch from Docker to Podman" to reflect that both are now supported (remove the line, or note Podman is now an option) |
| `README.md:359-361` | note that neither engine's control socket is ever shared with the runner container — true of both, stronger of the two under Podman (no socket exists in this design at all) |
| `CLAUDE.md:230-231,234-235` | same dev-command note as README |
| `CLAUDE.md:240` | `Four Docker containers orchestrated by compose.yml:` → `Four containers (Docker or rootless Podman) orchestrated by compose.yml (+ compose.podman.yml under Podman):` |
| `CLAUDE.md:277` | note both `docker compose run …` and `podman-compose -f compose.yml -f compose.podman.yml run …` work, matching whichever `./chomper` auto-detected |
| `lib/chomper/harness.rb:65` | error string: mention both — e.g. "Start it with \`docker compose up -d --wait harness\` (or the Podman equivalent), or run this through ./chomper" |
| `lib/chomper/pd/openspec.rb:131` | same both-engines treatment for the rebuild hint |
| `.env.example:86` | comment header `Harness / Docker` → `Harness / Docker or Podman` |
| `tinyproxy.conf:11` | comment `# Docker networks only.` → `# Container-engine bridge networks only (RFC1918 — covers Docker's default and Podman/netavark's default 10.88.0.0/16).` |

No CI changes (`.github/workflows/test.yml` uses GitHub Actions' native
`container:` key — confirmed zero Docker/Compose dependency).

`.claude/settings.local.json` is not tracked in git — no repo change, just
worth knowing your local Claude Code permissions will need `podman`/
`podman-compose` patterns added over time as you approve them.

## Verification

Run on the actual Ubuntu 26.04 host after packages are installed and the
edits above land:

```bash
# Prerequisites
podman --version
podman-compose --version                           # expect 1.5.0
podman info --format '{{.Host.NetworkBackend}}'    # expect: netavark
grep "^$(id -un):" /etc/subuid /etc/subgid          # expect one line each

# Engine detection picks Podman when both are present, or falls back to Docker
./chomper status   # or any no-op-ish command; confirm no argument errors either way

# UID mapping: files land owned by the actual invoking host user, not uid 1000
# literally, not root, not a subuid-range number
./chomper usage
ls -ln .chomper/pi-agent .chomper/pi-sessions .chomper/repos | head
podman inspect --format '{{.Config.User}}' <harness-container-id>   # expect: 1000:1000
podman inspect --format '{{.Config.User}}' <runner-container-id>    # expect: 1000:1000 (not root)

# Healthchecks and the Podman wait loop
podman inspect --format '{{.State.Health.Status}}' <authgw-container-id>   # expect: healthy
./chomper agent            # or: wp ship <id>
# Confirm: no argument errors from podman-compose, the poll loop resolves in
# a few seconds (not the 60s timeout), Ctrl-C during startup still runs the trap.

# Network isolation — the security property this migration is meant to preserve
podman network inspect chomper_internal --format '{{.Internal}}'   # expect: true
podman exec <harness-container-id> curl -m5 -sS http://1.1.1.1; echo "exit=$?"
  # expect: nonzero / connection failure — no direct route out
podman exec <harness-container-id> curl -m5 -sS -x http://proxy:8888 https://openrouter.ai
  # expect: success — allowlisted egress via proxy still works
podman exec <harness-container-id> curl -m5 -sS -x http://proxy:8888 https://example.com
  # expect: proxy rejects — non-allowlisted host still blocked

# Docker path still works unchanged (if Docker is also installed on a test box)
# same ./chomper commands, ENGINE should resolve to docker, --wait used natively
```

Out of scope for this migration (pre-existing, unrelated to adding Podman
support, flagged but not fixed here): `Dockerfile.runner`'s `ruby:4.0-slim`
base tag looks unverifiable against current Ruby release series, and
`Dockerfile.harness` (`node:22-slim`) vs `Dockerfile.authgw` (`node:20-slim`)
use different Node majors. Worth a separate look, not part of this change.
