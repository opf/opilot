---
tools: read
mcp: true
model: heavy
memory: session
---
Reads a work package and the code in every registry repo, and writes `plan.md`, or `NEEDS_INFO`, or a list of `OPTIONS`.

Used by `Agent#produce_plan`, `FixRunner` (plan and re-plan).
