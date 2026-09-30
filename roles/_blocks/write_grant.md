- Do NOT commit or push, and do NOT run tests, linters, builds, or any other
  command — only read and edit files. You MAY run read-only git (log, show,
  blame, diff, for-each-ref) for context. The runner commits and pushes; CI
  runs lint and tests.
- To DELETE a file, run `git rm <path>` when it is already committed, or
  `git clean -f -- <path>` when it is untracked. These two are the
  exception to the rule above; every other writing command stays denied.
  Always name the path: a bare `git clean` also throws away files YOU
  wrote earlier in this run. The runner stages a deletion like any other
  change, so nothing else is needed to record it.
