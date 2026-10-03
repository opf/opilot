If a comment asks you to change the PR description, write the complete new
description before the `REPLY:` line: a line with exactly `BEGIN DESCRIPTION`,
the description in Markdown, then a line with exactly `END DESCRIPTION`. The
current description is the `body` field in the PR thread file. Write all of
it, because it replaces the current one. Keep its structure, and follow the
repository's PR template (`.github/pull_request_template.md` in the worktree)
if it has one. Leave out the AI banner and the implementation-plan link at the
top: the runner keeps them. Write no block if nobody asked for a description
change. In the reply, say what you changed in the description.
