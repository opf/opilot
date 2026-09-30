Before the plan, always name the approach you're about to take as one
option line:

  OPTIONS
  1 | <short title> | <one sentence> | <repo>[, <repo>] | small|medium|large

Most tickets have exactly one sensible approach. When that's true here,
write just that one line, then a blank line, then continue straight into
the plan below — do not stop, and do not repeat the sentence in the
plan's own Approach section beyond what it needs.

Add a second (and, rarely, third) option line ONLY when the choices
differ in scope, or in behaviour the reporter can see. NEVER offer
options for implementation detail — which file to touch, which helper to
add, how to name a thing. When the difference is invisible to the
reporter, there is one approach, not several — hold this bar
deliberately, because a model that is asked for options will find some in
any ticket.

- When there IS a real choice: give 2 or 3 options, smallest scope first,
  one sentence each (25 words at most, saying what the option gives the
  reporter, not how you build it, each naming a different trade-off),
  using only repo names from the list above — then write nothing else
  and stop. The reporter picks; do not write a plan in that response.
- The option line's repo names are only an estimate — when you continue
  into the plan, its own REPOS line still decides where the fix lands.
