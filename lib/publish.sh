# lib/publish.sh — push branches and open draft PRs

# Push branch and open a draft PR for one committed work package.
_publish_item() {
  local ITEM_ID="$1"
  local ITEM TITLE GROUP
  ITEM=$(jq -c ".items[] | select(.id == \"$ITEM_ID\")" "$BACKLOG_JSON")
  if [ -z "$ITEM" ]; then
    echo "  Error: #$ITEM_ID not found in backlog"
    return 1
  fi
  { read -r TITLE; read -r GROUP; } < <(echo "$ITEM" | jq -r '.subject, (.locality_group // "fix")')

  local id_num title_lower title_slug BRANCH
  id_num=$(printf '%d' "$ITEM_ID")
  title_lower=$(printf '%s' "$TITLE" | tr '[:upper:]' '[:lower:]')
  title_slug="${title_lower//[^a-z0-9]/-}"
  BRANCH="fix/${id_num}-${title_slug:0:40}"

  local PR_DESC_FILE="$STATE/items/$ITEM_ID/pr.md"

  if ! git -C "$WORKTREE_HOST" rev-parse --verify "$BRANCH" &>/dev/null; then
    echo "  Error: branch $BRANCH not found — has this item been committed?"
    return 1
  fi
  if [ ! -s "$PR_DESC_FILE" ]; then
    echo "  Error: no PR description at $PR_DESC_FILE (missing or empty)"
    return 1
  fi

  local existing_url
  existing_url=$(cd "$WORKTREE_HOST" && gh pr list --head "$BRANCH" --json url --jq '.[0].url' 2>/dev/null || true)
  if [ -n "$existing_url" ]; then
    echo "  PR already exists for $BRANCH: $existing_url — skipping"
    echo "$existing_url" > "$STATE/items/$ITEM_ID/pr_url.txt"
    return 0
  fi

  _log_script "Publishing #$ITEM_ID — $TITLE"
  git -C "$WORKTREE_HOST" push -u origin "$BRANCH"
  local pr_url
  pr_url=$(cd "$WORKTREE_HOST" && gh pr create --draft --base dev --head "$BRANCH" \
    --title "fix($GROUP): $TITLE (WP #$ITEM_ID)" \
    --body-file "$PR_DESC_FILE")
  echo "  ✓ $pr_url"
  echo "$pr_url" > "$STATE/items/$ITEM_ID/pr_url.txt"
  echo "$(date '+%Y-%m-%dT%H:%M')|$ITEM_ID|$BRANCH|published" >> "$PROGRESS"
}

_publish_stage() {
  local ids=("$@")
  if [ ${#ids[@]} -gt 0 ]; then
    for id in "${ids[@]}"; do
      _publish_item "$id" || true
    done
  else
    local count=0
    while IFS= read -r id; do
      _publish_item "$id" || true
      count=$((count + 1))
    done < <(jq -r '.items[] | select(.passes == true) | .id' "$BACKLOG_JSON")
    [ "$count" -eq 0 ] && echo "  Nothing committed yet — run ./chomper fix first."
  fi
}
