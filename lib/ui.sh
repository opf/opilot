# lib/ui.sh — status display, setup, docker, worktree, reset, usage

_status() {
  if [ ! -f "$BACKLOG_JSON" ]; then
    echo "No backlog yet. Run ./chomper to fetch and triage."
    return
  fi
  local TOTAL DONE PENDING BLOCKED UNTRIAGED ASSIGNED
  TOTAL=$(    jq '.items | length'                                             "$BACKLOG_JSON")
  DONE=$(     jq '[.items[] | select(.passes == true)]       | length'        "$BACKLOG_JSON")
  PENDING=$(  jq '[.items[] | select(.passes == false)]      | length'        "$BACKLOG_JSON")
  BLOCKED=$(  jq '[.items[] | select(.passes == "blocked")]  | length'        "$BACKLOG_JSON")
  UNTRIAGED=$(jq '[.items[] | select(.passes == null)]       | length'        "$BACKLOG_JSON")
  ASSIGNED=$( jq '[.items[] | select(.assignee != null and .assignee != "unassigned")] | length' "$BACKLOG_JSON")

  echo ""
  local summary="  $PENDING pending"
  [ "$DONE"      -gt 0 ] && summary="$summary  ✓ $DONE done"
  [ "$BLOCKED"   -gt 0 ] && summary="$summary  ✗ $BLOCKED blocked"
  [ "$UNTRIAGED" -gt 0 ] && summary="$summary  ? $UNTRIAGED untriaged"
  [ "$ASSIGNED"  -gt 0 ] && summary="$summary  ($ASSIGNED assigned)"
  echo "$summary"

  local section label passes_filter items_tsv
  for section in pending done blocked untriaged; do
    case "$section" in
      pending)   label="Pending"   ; passes_filter='select(.passes == false)'       ;;
      done)      label="Done"      ; passes_filter='select(.passes == true)'        ;;
      blocked)   label="Blocked"   ; passes_filter='select(.passes == "blocked")'   ;;
      untriaged) label="Untriaged" ; passes_filter='select(.passes == null)'        ;;
    esac
    items_tsv=$(jq -r ".items[] | $passes_filter | [.id, .subject, (.url // \"\"), (.locality_group // \"?\"), (.complexity // \"?\")] | @tsv" "$BACKLOG_JSON")
    [ -z "$items_tsv" ] && continue
    echo ""
    echo "  $label:"
    while IFS=$'\t' read -r id title url lg cplx; do
      printf "    ${BOLD}#%-6s  %s${RESET}  (%s / %s)\n" "$id" "$title" "$lg" "$cplx"
      printf "             %s\n" "$url"
      local gist_file="$STATE/items/$id/gist.txt"
      local pr_file="$STATE/items/$id/pr_url.txt"
      [ -f "$gist_file" ] && printf "             Plan: %s\n" "$(cat "$gist_file")"
      if [ -f "$pr_file" ]; then
        printf "             PR:   %s\n" "$(cat "$pr_file")"
      elif [ "$section" = "done" ]; then
        printf "             (no PR yet — run ./chomper publish %s)\n" "$id"
      fi
    done <<< "$items_tsv"
  done

  if [ -f "$PROGRESS" ] && [ -s "$PROGRESS" ]; then
    echo ""
    echo "  Recent:"
    tail -5 "$PROGRESS" | while IFS='|' read -r ts id _ note; do
      echo "    $ts  #$id  $note"
    done
  fi
  echo ""
}

_ensure_docker() {
  if ! docker image inspect "$CLAUDE_IMAGE" &>/dev/null; then
    _log_script "Building claude container image '$CLAUDE_IMAGE' (one-time)"
    docker build -t "$CLAUDE_IMAGE" "$SCRIPT_DIR"
    echo ""
  fi

  if ! docker run --rm \
      -v "$CLAUDE_AUTH:/root/.claude" \
      -e CLAUDE_CONFIG_DIR=/root/.claude \
      "$CLAUDE_IMAGE" \
      claude auth status &>/dev/null; then
    echo "[ Claude auth required — follow the prompts below ]"
    docker run --rm -it \
      -v "$CLAUDE_AUTH:/root/.claude" \
      -e CLAUDE_CONFIG_DIR=/root/.claude \
      "$CLAUDE_IMAGE" \
      claude auth login
    echo ""
  fi
}

_first_run_setup() {
  [ -f "$CONFIG" ] && return
  echo ""
  echo "=== First run — quick setup ==="
  echo ""
  printf "  OpenProject URL [https://community.openproject.org]: "
  read -r OP_URL; OP_URL="${OP_URL:-https://community.openproject.org}"
  printf "  API token (read-only, View work packages only): "
  read -rs TOKEN; echo ""
  printf "  Project identifier [communicator-stream]: "
  read -r PROJECT_ID; PROJECT_ID="${PROJECT_ID:-communicator-stream}"
  printf "  Path to your product repo [../openproject]: "
  read -r REPO_PATH; REPO_PATH="${REPO_PATH:-../openproject}"
  cat > "$CONFIG" <<EOF
OP_URL="$OP_URL"
TOKEN="$TOKEN"
PROJECT_ID="$PROJECT_ID"
REPO_PATH="$REPO_PATH"
EOF
  chmod 600 "$CONFIG"
  echo ""
  echo "  ✓ Saved to .chomper/config (gitignored, chmod 600)"
  echo ""
}

_ensure_worktree() {
  if ! git -C "$WORKTREE_HOST" rev-parse --git-dir &>/dev/null; then
    _log_script "Creating isolated worktree (your repo checkout is untouched)"
    git -C "$REPO_PATH" fetch origin dev
    git -C "$REPO_PATH" worktree add --detach "$WORKTREE_HOST" origin/dev
    echo "  ✓ Worktree at $WORKTREE_HOST"
    echo ""
  fi
}

_reset() {
  echo ""
  echo "This will de-register the worktree and delete .chomper/ entirely."
  printf "  Confirm? [y/N] "
  read -r yn
  case "$yn" in [Yy]*) ;; *) echo "Aborted."; echo ""; return ;; esac

  if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
    local worktree="$STATE/worktree"
    if git -C "$REPO_PATH" worktree list 2>/dev/null | grep -qF "$worktree"; then
      echo "  De-registering worktree $worktree..."
      git -C "$REPO_PATH" worktree remove --force "$worktree" 2>/dev/null || true
      git -C "$REPO_PATH" worktree prune 2>/dev/null || true
    fi
  fi

  echo "  Removing $STATE..."
  rm -rf "$STATE"
  echo "  ✓ Reset complete."
  echo ""
}

_usage() {
  cat <<'EOF'

Usage: ./chomper [COMMAND [IDs...]]

Commands:
  fix [id id ...]     Fix all pending bugs, or only the specified ticket IDs
  plan [id id ...]    Generate plans only — no implementation
  publish [id id ...] Push branches and open draft PRs (all committed, or specific IDs)
  status              Show backlog counts and recent progress
  reset               De-register the worktree and delete .chomper/ (fresh start)

Options:
  --help, -h    Show this help

Environment:
  CLAUDE_IMAGE            Docker image to use (default: chomper-claude)
  ANTHROPIC_API_KEY       Passed into the claude container if set

State (all in .chomper/, gitignored):
  config          OpenProject URL, token, project, repo path
  backlog.json    Fetched + triaged bugs
  items/<id>/     Per-WP folder: item.json, plan.md, review.txt, pr.md, gist.txt
  worktree/       Isolated git worktree for fixes
  progress.txt    Fix log
  claude-auth/    Persisted claude container auth (delete to re-authenticate)
  chomp.log       Full prompt + response log

EOF
}
