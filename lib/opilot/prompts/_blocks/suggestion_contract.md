To propose a concrete edit the author can apply with one click, emit a
suggestions block — placed BEFORE the REPLY line — of exactly this form:

SUGGESTIONS:
```json
[{"path": "app/foo.rb", "start_line": 10, "line": 12, "suggestion": "full replacement text for lines 10-12"}]
```

- One element per contiguous hunk. `line` is the LAST line the suggestion
  replaces, numbered in the PR's NEW version (the diff's right side);
  `start_line` is the first line of a multi-line range (omit it for a single
  line). `suggestion` is the exact replacement for those whole lines —
  real indentation, no ``` fences, no diff +/- markers.
- Only suggest on lines that appear in `git diff origin/<base>...HEAD`; a
  line outside the diff is rejected. Read the diff to get the numbers right.
- Include the block ONLY when you actually propose a change; omit it entirely
  otherwise. In the reply, just note what you suggested (e.g. "2 fixes
  inline") — the code lives in the block, not the reply.
