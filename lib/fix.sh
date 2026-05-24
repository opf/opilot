# lib/fix.sh — plan, test, implement, and commit one work package
#
# _fix_plan/_fix_write_tests/_fix_impl/_fix_gate/_fix_commit are called
# within _fix_item's call stack and read its locals via bash dynamic scoping.

# Publish $PLAN_FILE as a secret gist and save the URL to $GIST_FILE (idempotent).
_publish_plan_gist() {
    [ -f "$GIST_FILE" ] && return 0
    command -v gh &>/dev/null || return 0
    local gist_url
    gist_url=$(gh gist create --filename "wp-${ITEM_ID}-plan.md" \
        --desc "Bug chomper plan: #$ITEM_ID — $TITLE" "$PLAN_FILE" 2>/dev/null || true)
    [ -n "$gist_url" ] && { printf '%s\n' "$gist_url" > "$GIST_FILE"
                             echo "  ✓ Plan gist → $gist_url"; }
}

# Generate plan + reviewer cycle. Returns 1 if REJECTED (caller should skip item).
_fix_plan() {
    if [ -s "$PLAN_FILE" ]; then
        echo "  ↩ Resuming: plan exists, skipping planning stage."
        _publish_plan_gist
        return 0
    fi

    local PLAN_FILE_C="$STATE_CONTAINER/items/$ITEM_ID/plan.md"
    local ITEM_FILE_C="$STATE_CONTAINER/items/$ITEM_ID/item.json"
    local REVIEW_FILE_C="$STATE_CONTAINER/items/$ITEM_ID/review.txt"

    _log_script "Writer: generating plan for #$ITEM_ID — $TITLE"
    local prompt="
PRODUCT REPO: $WORKTREE_CONTAINER
ISSUE:        $ITEM_FILE_C  (JSON — fields: subject, description, comments[], version, files_touched)
HINT FILES:   $FILES_HINT
You are the WRITER. Produce a plan only — do not modify any file.

## Plan: #$ITEM_ID — $TITLE
### Files to change
### Approach
### Tests to run
### Risks / assumptions
"
    _claude_capture "$prompt" "$TOOLS_READ" "$PLAN_FILE" "true"

    _log_script "Reviewer: checking plan for #$ITEM_ID"
    local review_prompt
    review_prompt="
You are the REVIEWER. Read the plan at $PLAN_FILE_C and critique it.
Flag: wrong file paths, missing edge cases, unnecessary complexity, blast radius.

## Review: #$ITEM_ID
### Issues found  (or 'None')
### Suggested adjustments  (or 'None')
### Verdict  PROCEED | REVISE | REJECT
"
    _claude_capture "$review_prompt" "$TOOLS_READ" "$REVIEW_FILE"

    local verdict
    verdict=$(grep -ioE '\b(PROCEED|REVISE|REJECT)\b' "$REVIEW_FILE" | tail -1 | tr '[:lower:]' '[:upper:]')
    case "${verdict:-PROCEED}" in
        REJECT)
            _log_script "Plan REJECTED for #$ITEM_ID — moving to next item."
            git -C "$WORKTREE_HOST" checkout --detach origin/dev
            git -C "$REPO_PATH" branch -D "$BRANCH" 2>/dev/null || true
            echo "$(date '+%Y-%m-%dT%H:%M')|$ITEM_ID|-|REJECTED" >> "$PROGRESS"
            rm -f "$REVIEW_FILE"
            return 1
            ;;
        REVISE)
            _log_script "Revising plan for #$ITEM_ID based on reviewer feedback"
            local revise_prompt
            revise_prompt="
Read the original plan at $PLAN_FILE_C and the review at $REVIEW_FILE_C.
Revise the plan incorporating the reviewer's suggestions.
Print the complete revised plan to stdout only — do not write or edit any files.
"
            _claude_capture "$revise_prompt" "$TOOLS_READ" "$PLAN_FILE"
            ;;
    esac
    _publish_plan_gist
    rm -f "$REVIEW_FILE"
}

# Write failing tests and confirm they are red.
_fix_write_tests() {
    local PLAN_FILE_C="$STATE_CONTAINER/items/$ITEM_ID/plan.md"
    _log_script "Writing failing tests for #$ITEM_ID"
    local prompt
    prompt="
PRODUCT REPO: $WORKTREE_CONTAINER
APPROVED PLAN: $PLAN_FILE_C

First check if the implementation is already present as uncommitted changes in $WORKTREE_CONTAINER.
If it is, do nothing and say so. Otherwise:

Write FAILING tests only — no implementation.
- Tests must fail right now (fix does not exist yet)
- Use the project's existing test frameworks: RSpec for Ruby, Vitest for TypeScript
"
    _claude "$prompt" "$TOOLS_IMPL"
    echo ""

    local -a test_files=()
    while IFS= read -r line; do test_files+=("$line"); done < <(_test_files)
    if [ ${#test_files[@]} -gt 0 ]; then
        _log_script "Confirming red: ${test_files[*]}"
        _run_tests "${test_files[@]}" || true
    fi
}

# Implement the fix against the approved plan.
_fix_impl() {
    _log_script "Implementing fix for #$ITEM_ID"
    local test_instruction
    if [ "${TESTS_PRE_WRITTEN:-false}" = "true" ]; then
        test_instruction="- Do not modify the tests"
    else
        test_instruction="- Write tests as specified in the plan, then implement the fix"
    fi
    local PLAN_FILE_C="$STATE_CONTAINER/items/$ITEM_ID/plan.md"
    local prompt
    prompt="
PRODUCT REPO: $WORKTREE_CONTAINER
APPROVED PLAN: $PLAN_FILE_C

Check the current state of the worktree (uncommitted changes, existing work in progress).
Continue from wherever things are — there may already be partial or complete work in place.
Implement what's missing to fix the issue according to the plan.
$test_instruction
- Do not commit
"
    _claude "$prompt" "$TOOLS_IMPL"
}

# Run the test gate: up to 3 attempts, asking Claude to fix failures between rounds.
# Args: test file paths. Returns 0 on pass, 1 if all attempts exhausted.
_fix_gate() {
    local -a test_files=("$@")
    if [ ${#test_files[@]} -eq 0 ]; then
        _log_script "Test gate: no test files found — passing."
        return 0
    fi
    _log_script "Test gate for #$ITEM_ID: ${test_files[*]}"
    local attempt
    for attempt in 1 2 3; do
        echo "  Attempt $attempt/3..."
        if _run_tests "${test_files[@]}"; then return 0; fi
        [ $attempt -lt 3 ] && _claude "Tests still failing in $WORKTREE_CONTAINER. Read the output at $STATE_CONTAINER/last_test_run.txt and fix without changing the tests or committing." "$TOOLS_IMPL"
    done
    return 1
}

# Commit the passing fix and generate a PR description.
_fix_commit() {
    git -C "$WORKTREE_HOST" add -A
    if git -C "$WORKTREE_HOST" diff --cached --quiet && git -C "$WORKTREE_HOST" diff --quiet; then
        _log_script "#$ITEM_ID — nothing to commit, leaving as pending for retry."
        echo "$(date '+%Y-%m-%dT%H:%M')|$ITEM_ID|$BRANCH|no-changes" >> "$PROGRESS"
        return 0
    fi
    git -C "$WORKTREE_HOST" diff --stat --cached; echo ""
    git -C "$WORKTREE_HOST" commit -m "fix($GROUP): $TITLE (WP #$ITEM_ID)"
    _log_script "Committed: $(git -C "$WORKTREE_HOST" log --oneline -1)"
    _update_backlog "(.items[] | select(.id == \"$ITEM_ID\") | .passes) |= true" "$BACKLOG_JSON"
    echo "$(date '+%Y-%m-%dT%H:%M')|$ITEM_ID|$BRANCH|committed" >> "$PROGRESS"

    local ITEM_FILE_C="$STATE_CONTAINER/items/$ITEM_ID/item.json"
    local PLAN_FILE_C="$STATE_CONTAINER/items/$ITEM_ID/plan.md"

    _log_script "Generating PR description for #$ITEM_ID"
    local template_file="$REPO_PATH/.github/pull_request_template.md"
    local template_section=""
    [ -f "$template_file" ] && template_section="Fill in this PR template exactly: $template_file"

    local gist_section=""
    [ -f "$GIST_FILE" ] && gist_section="Insert this line verbatim as the first line under the 'What are you trying to accomplish?' heading: **Plan:** $(cat "$GIST_FILE")"

    local prompt
    prompt="
Write a GitHub PR description for this fix.

ISSUE: $ITEM_FILE_C
PLAN:  $PLAN_FILE_C
DIFF:
$(git -C "$WORKTREE_HOST" diff HEAD~1 HEAD --stat)
$template_section
$gist_section
Output only the PR description — no preamble.
"
    _claude "$prompt" "$TOOLS_READ" | tee /dev/tty | _strip_ansi \
        | awk '/^#/{found=1} found' > "$PR_DESC_FILE"
    echo ""
    echo "  ✓ PR description → $PR_DESC_FILE"
    echo "  Push & open PR:"
    echo "    git -C $WORKTREE_HOST push -u origin $BRANCH"
    echo "    gh pr create --draft --base dev --head $BRANCH --body-file $PR_DESC_FILE"
}

# Orchestrate plan → tests → impl → gate → commit for one work package.
_fix_item() {
    local ITEM_ID="$1" CMD="${2:-}"
    local ITEM TITLE GROUP COMPLEXITY URL FILES_HINT ASSIGNEE
    ITEM=$(jq -c ".items[] | select(.id == \"$ITEM_ID\")" "$BACKLOG_JSON")
    { read -r TITLE
      read -r GROUP
      read -r COMPLEXITY
      read -r URL
      read -r FILES_HINT
      read -r ASSIGNEE
    } < <(echo "$ITEM" | jq -r '
      .subject, .locality_group, .complexity, .url,
      (.files_touched | join(", ")),
      (.assignee // "")
    ')
    if [ -n "$ASSIGNEE" ] && [ "$ASSIGNEE" != "unassigned" ] && [ "$ASSIGNEE" != "null" ]; then
        echo "  Skipping #$ITEM_ID — assigned to $ASSIGNEE"
        return 0
    fi

    local ITEM_DIR="$STATE/items/$ITEM_ID"
    local PLAN_FILE="$ITEM_DIR/plan.md"
    local ITEM_FILE="$ITEM_DIR/item.json"
    local REVIEW_FILE="$ITEM_DIR/review.txt"
    local PR_DESC_FILE="$ITEM_DIR/pr.md"
    local GIST_FILE="$ITEM_DIR/gist.txt"
    local id_num title_lower title_slug BRANCH
    id_num=$(printf '%d' "$ITEM_ID")
    title_lower=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]')
    title_slug="${title_lower//[^a-z0-9]/-}"
    BRANCH="fix/${id_num}-${title_slug:0:40}"

    mkdir -p "$ITEM_DIR"
    echo "$ITEM" > "$ITEM_FILE"

    _log_script "#$ITEM_ID — $TITLE
  Group: $GROUP | Complexity: $COMPLEXITY
  $URL"

    git -C "$WORKTREE_HOST" fetch origin dev
    if git -C "$WORKTREE_HOST" rev-parse --verify "$BRANCH" &>/dev/null; then
        git -C "$WORKTREE_HOST" checkout "$BRANCH"
        echo "  ✓ Resuming existing branch $BRANCH"
    else
        git -C "$WORKTREE_HOST" checkout -b "$BRANCH" origin/dev
        echo "  ✓ Worktree on $BRANCH (repo stays on $(git -C "$REPO_PATH" branch --show-current))"
    fi

    local BRANCH_HAS_COMMITS=false
    [ -n "$(git -C "$WORKTREE_HOST" log origin/dev.."$BRANCH" --oneline 2>/dev/null)" ] \
        && BRANCH_HAS_COMMITS=true

    if $BRANCH_HAS_COMMITS; then
        echo "  ↩ Resuming: branch has commits, skipping plan + tests + impl."
    else
        _fix_plan || return 0
        [ "$CMD" = "plan" ] && { echo "  ✓ Plan saved — plan mode, skipping implementation."; return 0; }
        local TESTS_PRE_WRITTEN=false
        if [[ "$COMPLEXITY" != "trivial" && "$COMPLEXITY" != "simple" ]]; then
            _fix_write_tests
            TESTS_PRE_WRITTEN=true
        fi
        _fix_impl
    fi

    local -a TEST_FILES=()
    while IFS= read -r line; do TEST_FILES+=("$line"); done < <(_test_files)

    if _fix_gate "${TEST_FILES[@]+"${TEST_FILES[@]}"}"; then
        _fix_commit
    else
        _log_script "BLOCKED after 3 attempts on #$ITEM_ID — abandoning branch."
        git -C "$WORKTREE_HOST" checkout --detach origin/dev
        git -C "$REPO_PATH" branch -D "$BRANCH" 2>/dev/null || true
        _update_backlog "(.items[] | select(.id == \"$ITEM_ID\") | .passes) |= \"blocked\"" "$BACKLOG_JSON"
        echo "$(date '+%Y-%m-%dT%H:%M')|$ITEM_ID|$BRANCH|BLOCKED" >> "$PROGRESS"
    fi
    echo ""
}
