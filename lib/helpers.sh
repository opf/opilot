# lib/helpers.sh — low-level helpers, claude wrappers, tool sets

_run_claude() {
    local tools="" do_fresh=false
    [ "${1:-}" = "--tools" ] && { tools="$2"; shift 2; }
    [ "${1:-}" = "--fresh" ] && { do_fresh=true; shift; }
    local args=("-p" "--output-format" "stream-json" "--verbose")
    [ -n "$tools" ]  && args+=(--allowedTools "$tools")
    $do_fresh        || args+=("--continue")
    docker exec -i "$CLAUDE_CONTAINER" claude "${args[@]}" 2>&1 \
    | while IFS= read -r line; do
        printf '%s' "$line" | jq -r '
            select(.type == "assistant") |
            .message.content[] | select(.type == "tool_use") |
            "  \(.name)  \(.input | to_entries[:1] | map(.value | tostring) | join(""))"
        ' 2>/dev/null > /dev/tty
        printf '%s' "$line" | jq -r '
            select(.type == "assistant") |
            .message.content[] | select(.type == "text") | .text
        ' 2>/dev/null
    done
}

# Sets $CLAUDE_CONTAINER. Called once after volumes are known.
_start_claude_container() {
    CLAUDE_CONTAINER=$(docker run -d --rm \
        -v "$CLAUDE_AUTH:/root/.claude" \
        -e CLAUDE_CONFIG_DIR=/root/.claude \
        -v "$WORKTREE_HOST:/repo" \
        -v "$STATE:/state" \
        -e FORCE_COLOR=1 \
        -e GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
        ${ANTHROPIC_API_KEY:+-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"} \
        "$CLAUDE_IMAGE" sleep infinity)
}

# Usage: _claude "prompt" ["tool1,tool2,..."] ["true" to start a fresh session]
_claude() {
    local prompt="$1" tools="${2:-}" do_fresh="${3:-false}"
    {
        echo "${RESET}${BOLD}[ $(date '+%H:%M:%S') ] CLAUDE CODE PROMPT${RESET}"
        printf '%s' "$CYAN"
        printf '%s' "$prompt" | awk '/[^[:space:]]/{s=s?s:NR; e=NR} {lines[NR]=$0} END{for(i=s+0;i<=e+0;i++) print lines[i]}'
        printf '%s' "$RESET"
    } | tee -a "$CLOG" > /dev/tty
    echo "${RESET}${BOLD}[ $(date '+%H:%M:%S') ] CLAUDE CODE RESPONSE${RESET}" \
        | tee -a "$CLOG" > /dev/tty
    local run_args=()
    [ -n "$tools" ]          && run_args+=(--tools "$tools")
    [ "$do_fresh" = "true" ] && run_args+=(--fresh)
    { printf '%s' "$CYAN"; printf '%s' "$prompt" | _run_claude ${run_args[@]+"${run_args[@]}"}; printf '%s' "$RESET"; } | tee -a "$CLOG"
    echo "" | tee -a "$CLOG" > /dev/tty
}

# Rewrite $BACKLOG_JSON in-place via a jq invocation.
_update_backlog() { jq "$@" > "$STATE/tmp.json" && mv "$STATE/tmp.json" "$BACKLOG_JSON"; }

# Derive test files changed in the worktree relative to origin/dev.
_test_files() {
    { git -C "$WORKTREE_HOST" diff --name-only origin/dev HEAD 2>/dev/null
      git -C "$WORKTREE_HOST" ls-files --others --exclude-standard "$WORKTREE_HOST" 2>/dev/null
    } | grep -E '_spec\.rb$|\.spec\.ts$|\.spec\.js$' | sort -u
}

# Usage: _run_tests file1 [file2 ...]
_run_tests() {
    local rb_files=() fe_files=() f pass=true
    for f in "$@"; do
        case "$f" in
            *.rb)                rb_files+=("$f") ;;
            *.spec.ts|*.spec.js) fe_files+=("$f") ;;
        esac
    done
    local out="$STATE/last_test_run.txt"
    : > "$out"
    if [ ${#rb_files[@]} -gt 0 ]; then
        echo "  [ rspec: ${rb_files[*]} ]"
        (cd "$WORKTREE_HOST" && bin/compose rspec "${rb_files[@]}") 2>&1 | tee -a "$out" | tail -30 || pass=false
    fi
    if [ ${#fe_files[@]} -gt 0 ]; then
        echo "  [ frontend (Angular): trusting ${fe_files[*]} — skipping run ]"
    fi
    $pass
}

_log_script() {
    local ts="$(date '+%H:%M:%S')"
    while IFS= read -r line; do
        printf '%s%s[ %s ] %s%s\n' "$RESET" "$BOLD" "$ts" "$line" "$RESET"
    done <<< "$*" | tee -a "$CLOG"
    printf '%s' "$GRAY" > /dev/tty
}

_strip_ansi() { perl -pe 's/\e\[[0-9;]*[mGKHFJ]//g'; }

# Usage: _claude_capture "prompt" "tools" "outfile" ["true" to start a fresh session]
_claude_capture() {
    _claude "$1" "$2" "${4:-false}" | tee /dev/tty | _strip_ansi > "$3"
    echo ""
}

# Remove a file only if its path is under SCRIPT_DIR.
_safe_rm() {
  local f="${1:?_safe_rm: path argument required}"
  [[ "$f" == "$SCRIPT_DIR/"* ]] || { echo "BUG: _safe_rm refusing unexpected path: $f" >&2; return 1; }
  rm -f "$f"
}

TOOLS_READ="Read"
TOOLS_IMPL="Read,Write,Edit,Bash(bin/compose*)"
