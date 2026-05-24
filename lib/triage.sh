# lib/triage.sh — enrich untriaged items (passes == null)

TRIAGE_BATCH_SIZE=25
TRIAGE_SCHEMA='{
  "id":             "<same id as input>",
  "locality_group": "<subsystem: auth|api|db|ui|payments|...>",
  "complexity":     "<trivial|simple|moderate|complex>",
  "files_touched":  ["<likely source file paths>"],
  "ai_category":    "<null-safety|type-error|logic-bug|perf|refactor|test|feature|chore>",
  "passes":         false
}'

_triage_stage() {
  local UNTRIAGED_COUNT
  UNTRIAGED_COUNT=$(jq '[.items[] | select(.passes == null)] | length' "$BACKLOG_JSON")
  [ "$UNTRIAGED_COUNT" -eq 0 ] && return

  local TOTAL_BATCHES=$(( (UNTRIAGED_COUNT + TRIAGE_BATCH_SIZE - 1) / TRIAGE_BATCH_SIZE ))
  echo "  $UNTRIAGED_COUNT issues · $TOTAL_BATCHES batches of $TRIAGE_BATCH_SIZE"

  local BATCH_NUM=0 BATCH TRIAGE_INPUT TRIAGE_OUTPUT TRIAGE_INPUT_C
  TRIAGE_INPUT="$STATE/triage_input.json"
  TRIAGE_INPUT_C="$STATE_CONTAINER/triage_input.json"
  TRIAGE_OUTPUT="$STATE/triage_output.json"

  while true; do
    BATCH=$(jq "[.items[] | select(.passes == null)] | .[0:$TRIAGE_BATCH_SIZE]" "$BACKLOG_JSON")
    [ "$(echo "$BATCH" | jq 'length')" -eq 0 ] && break

    BATCH_NUM=$((BATCH_NUM + 1))
    echo "  Batch $BATCH_NUM / $TOTAL_BATCHES"
    echo "$BATCH" > "$TRIAGE_INPUT"

    local PROMPT="Read $TRIAGE_INPUT_C — a JSON array of Bug work packages.
Each item has: id, subject, description, comments[], version, category, priority.

For each item print one line:
  #<id> <subject> → <locality_group> / <complexity>

Then output the complete results between these exact delimiters — nothing after the closing delimiter:
---BEGIN JSON---
[one object per item]
---END JSON---

Schema per object:
$TRIAGE_SCHEMA

Complexity guide:
  trivial  — single obvious fix, ≤2 files
  simple   — clear fix, ≤5 files
  moderate — spans multiple subsystems
  complex  — architectural impact or high risk

Set passes to false (not null) — this marks the item as triaged."

    _claude "$PROMPT" | tee /dev/tty \
      | awk '/^---BEGIN JSON---$/{found=1;next} /^---END JSON---$/{found=0;next} found' \
      > "$TRIAGE_OUTPUT"

    if [ ! -s "$TRIAGE_OUTPUT" ]; then
      echo "  Warning: no JSON extracted for batch $BATCH_NUM — skipping merge."
      rm -f "$TRIAGE_INPUT" "$TRIAGE_OUTPUT"
      continue
    fi

    # shellcheck disable=SC2016
    _update_backlog -s '
      .[0] as $backlog |
      .[1] as $triaged |
      {items: ($backlog.items | map(
        . as $item |
        ($triaged | map(select(.id == $item.id)) | first) as $t |
        if $t != null then $item + $t else $item end
      ))}
    ' "$BACKLOG_JSON" "$TRIAGE_OUTPUT"

    rm -f "$TRIAGE_INPUT" "$TRIAGE_OUTPUT"
  done

  _update_backlog '.items |= sort_by([
    (if .complexity == "trivial" then 0
     elif .complexity == "simple" then 1
     elif .complexity == "moderate" then 2
     else 3 end),
    .locality_group
  ])' "$BACKLOG_JSON"

}
