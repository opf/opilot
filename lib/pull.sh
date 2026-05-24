# lib/pull.sh — fetch work packages from OpenProject

# Fetch activities+reactions for a WP JSON object, build an item, append to file.
# Usage: _append_wp_item <wp-json> <output-file>
_append_wp_item() {
  local wp="$1" out="$2"
  local WP_ID; WP_ID=$(echo "$wp" | jq -r '.id')

  local ACTS RXNS COMMENTS ITEM
  ACTS=$(curl -sf --user "apikey:$TOKEN" \
    "$OP_URL/api/v3/work_packages/$WP_ID/activities" 2>/dev/null \
    || echo '{"_embedded":{"elements":[]}}')
  RXNS=$({ curl -sf --user "apikey:$TOKEN" \
    "$OP_URL/api/v3/work_packages/$WP_ID/activities_emoji_reactions" 2>/dev/null \
    || echo '{"_embedded":{"elements":[]}}'; })
  COMMENTS=$(jq -n \
    --argjson acts "$ACTS" \
    --argjson rxns "$RXNS" '
    ($rxns._embedded.elements // []
      | group_by(._links.reactable.href | split("/") | last)
      | map({
          key: (.[0]._links.reactable.href | split("/") | last),
          value: (map({key: .reaction, value: .reactionsCount}) | from_entries)
        })
      | from_entries) as $rxn_map |
    [$acts._embedded.elements[]
      | select(.comment.raw != "")
      | {
          user:       ._embedded.user.name,
          created_at: .createdAt,
          text:       .comment.raw,
          reactions:  ($rxn_map[.id | tostring] // {})
        }
    ]
  ')
  ITEM=$(echo "$wp" | jq \
    --argjson comments "$COMMENTS" \
    --arg op_url "$OP_URL" '{
      id:             (.id | tostring),
      subject:        .subject,
      url:            ($op_url + "/work_packages/" + (.id | tostring)),
      status:         ._embedded.status.name,
      priority:       ._embedded.priority.name,
      assignee:       (._embedded.assignee.name  // "unassigned"),
      author:         (._embedded.author.name    // null),
      version:        (._embedded.version.name   // null),
      category:       (._embedded.category.name  // null),
      created_at:     .createdAt,
      updated_at:     .updatedAt,
      description:    (.description.raw          // ""),
      comments:       $comments,
      locality_group: null,
      complexity:     null,
      files_touched:  [],
      ai_category:    null,
      passes:         false
    }')
  jq --argjson item "$ITEM" '. += [$item]' "$out" > "$STATE/tmp.json" \
    && mv "$STATE/tmp.json" "$out"
  printf "  #%s %s\n" "$WP_ID" "$(echo "$wp" | jq -r '.subject')"
}

# ── STAGE 1a: PULL ────────────────────────────────────────
# Fetch bugs from OpenProject into backlog.json.
# Merges with existing state: triage + fix progress is preserved.

_prompt_search_filters() {
  local _tmp _code
  _tmp=$(mktemp "$STATE/tmp.XXXXXX")

  echo ""
  echo "=== Search filters ==="
  echo ""

  printf "  Project [%s]: " "$PROJECT_ID"
  read -r _sel_project; FILTER_PROJECT_ID="${_sel_project:-$PROJECT_ID}"

  _code=$(curl -s -o "$_tmp" -w '%{http_code}' --user "apikey:$TOKEN" "$OP_URL/api/v3/projects/$FILTER_PROJECT_ID/types")
  if [ "$_code" != "200" ]; then
    echo "  Error: $OP_URL/api/v3/projects/$FILTER_PROJECT_ID/types returned HTTP $_code — check TOKEN and OP_URL"
    exit 1
  fi
  local types_json; types_json=$(cat "$_tmp")
  local type_names; type_names=$(jq -r '[._embedded.elements[].name] | join(", ")' "$_tmp")
  printf "  Types available: %s\n" "$type_names"
  printf "  Type(s), comma-separated [bug]: "
  read -r _sel_types; _sel_types="${_sel_types:-bug}"

  FILTER_TYPE_IDS=$(echo "$types_json" | jq -c \
    --arg sel "$_sel_types" '
    ($sel | split(",") | map(ltrimstr(" ") | rtrimstr(" ") | ascii_downcase)) as $names |
    [._embedded.elements[] | select(.name | ascii_downcase | IN($names[])) | .id | tostring]
  ')
  if [ "$FILTER_TYPE_IDS" = "[]" ]; then
    echo "  Error: none of the specified types found"
    exit 1
  fi

  _code=$(curl -s -o "$_tmp" -w '%{http_code}' --user "apikey:$TOKEN" "$OP_URL/api/v3/statuses")
  if [ "$_code" != "200" ]; then
    echo "  Error: $OP_URL/api/v3/statuses returned HTTP $_code — check TOKEN and OP_URL"
    exit 1
  fi
  local statuses_json; statuses_json=$(cat "$_tmp")
  local status_names; status_names=$(jq -r '[._embedded.elements[].name] | join(", ")' "$_tmp")
  printf "  Statuses available: %s\n" "$status_names"
  printf "  Status(es), comma-separated [new, confirmed]: "
  read -r _sel_statuses; _sel_statuses="${_sel_statuses:-new, confirmed}"

  FILTER_STATUS_VALUES=$(echo "$statuses_json" | jq -c \
    --arg sel "$_sel_statuses" '
    ($sel | split(",") | map(ltrimstr(" ") | rtrimstr(" ") | ascii_downcase)) as $names |
    [._embedded.elements[] | select(.name | ascii_downcase | IN($names[])) | .id | tostring]
  ')
  if [ "$FILTER_STATUS_VALUES" = "[]" ]; then
    echo "  Error: none of the specified statuses found"
    exit 1
  fi

  _code=$(curl -s -o "$_tmp" -w '%{http_code}' --user "apikey:$TOKEN" "$OP_URL/api/v3/projects/$FILTER_PROJECT_ID/versions")
  if [ "$_code" != "200" ]; then
    echo "  Warning: could not fetch versions (HTTP $_code) — skipping version filter"
    FILTER_VERSION_IDS="[]"
  else
    local versions_json; versions_json=$(cat "$_tmp")
    local version_names; version_names=$(jq -r '[._embedded.elements[].name] | join(", ")' "$_tmp")
    printf "  Versions available: %s\n" "$version_names"
    printf "  Version(s), comma-separated (leave blank for any): "
    read -r _sel_versions
    if [ -z "$_sel_versions" ]; then
      FILTER_VERSION_IDS="[]"
    else
      FILTER_VERSION_IDS=$(echo "$versions_json" | jq -c \
        --arg sel "$_sel_versions" '
        ($sel | split(",") | map(ltrimstr(" ") | rtrimstr(" ") | ascii_downcase)) as $names |
        [._embedded.elements[] | select(.name | ascii_downcase | IN($names[])) | .id | tostring]
      ')
      if [ "$FILTER_VERSION_IDS" = "[]" ]; then
        echo "  Error: none of the specified versions found"
        exit 1
      fi
    fi
  fi

  _safe_rm "$_tmp"
  echo ""
}

_pull_stage() {

  _prompt_search_filters

  local FILTERS ENCODED_FILTERS VERSION_FILTER=""
  [ "$FILTER_VERSION_IDS" != "[]" ] && \
    VERSION_FILTER=$(printf ',{"version":{"operator":"=","values":%s}}' "$FILTER_VERSION_IDS")
  FILTERS=$(printf '[{"status":{"operator":"=","values":%s}},{"type":{"operator":"=","values":%s}}%s]' \
    "$FILTER_STATUS_VALUES" "$FILTER_TYPE_IDS" "$VERSION_FILTER")
  ENCODED_FILTERS=$(printf '%s' "$FILTERS" | jq -Rr @uri)

  local NEW_ITEMS="$STATE/new_items.json"
  echo '[]' > "$NEW_ITEMS"
  PAGE=1; PAGE_SIZE=50; TOTAL_WRITTEN=0; TOTAL=0

  while true; do
    API_URL="$OP_URL/api/v3/projects/$FILTER_PROJECT_ID/work_packages?pageSize=$PAGE_SIZE&offset=$PAGE&filters=$ENCODED_FILTERS"
    HTTP_STATUS=$(curl -s -o "$STATE/response.json" -w "%{http_code}" \
      --user "apikey:$TOKEN" \
      -H "Content-Type: application/json" \
      "$API_URL")

    if [ "$HTTP_STATUS" != "200" ]; then
      echo ""
      echo "  Error: API returned HTTP $HTTP_STATUS"
      echo "  URL:      $API_URL"
      echo "  Response: $(cat "$STATE/response.json")"
      exit 1
    fi

    RESPONSE=$(cat "$STATE/response.json")
    COUNT=$(echo "$RESPONSE" | jq -r '.count // 0')
    TOTAL=$(echo "$RESPONSE" | jq -r '.total // 0')
    [ "$COUNT" -eq 0 ] && break
    [ "$PAGE" -eq 1 ] && echo "  Fetching $TOTAL work packages..."

    while IFS= read -r wp; do
      _append_wp_item "$wp" "$NEW_ITEMS"
    done < <(echo "$RESPONSE" | jq -c '._embedded.elements[]')

    TOTAL_WRITTEN=$((TOTAL_WRITTEN + COUNT))
    echo "  ── Page $PAGE — $TOTAL_WRITTEN / $TOTAL"
    [ "$TOTAL_WRITTEN" -ge "$TOTAL" ] && break
    PAGE=$((PAGE + 1))
  done

  if [ -f "$BACKLOG_JSON" ]; then
    # shellcheck disable=SC2016
    _update_backlog -s '
      (.[0].items // []) as $existing |
      .[1] as $new |
      {items: ($new | map(
        . as $item |
        ($existing | map(select(.id == $item.id)) | first) as $prev |
        if $prev != null then
          $item + {
            passes:         $prev.passes,
            locality_group: $prev.locality_group,
            complexity:     $prev.complexity,
            files_touched:  $prev.files_touched,
            ai_category:    $prev.ai_category
          }
        else $item + {passes: null} end
      ))}
    ' "$BACKLOG_JSON" "$NEW_ITEMS"
  else
    jq '{items: .}' "$NEW_ITEMS" > "$BACKLOG_JSON"
  fi

  _safe_rm "$NEW_ITEMS"
}

# ── STAGE 1b: FETCH IDS ───────────────────────────────────
# Load specific WPs by ID, skip full pull.
# Items are written with passes:false (ready to fix, no triage needed).

_fetch_ids_stage() {
  local NEW_ITEMS="$STATE/new_items.json"
  echo '[]' > "$NEW_ITEMS"

  local _tmp _code
  _tmp=$(mktemp "$STATE/tmp.XXXXXX")

  local id
  for id in "$@"; do
    _code=$(curl -s -o "$_tmp" -w '%{http_code}' --user "apikey:$TOKEN" "$OP_URL/api/v3/work_packages/$id")
    if [ "$_code" != "200" ]; then
      echo "  Warning: WP #$id returned HTTP $_code — skipping"
      continue
    fi
    _append_wp_item "$(cat "$_tmp")" "$NEW_ITEMS"
  done

  _safe_rm "$_tmp"
  jq '{items: .}' "$NEW_ITEMS" > "$BACKLOG_JSON"
  _safe_rm "$NEW_ITEMS"
}
