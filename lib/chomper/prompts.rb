module Chomper
  # All Claude prompts live here, in one place, so the instructions that drive a
  # tool-enabled agent can be audited and reviewed without hunting through the
  # codebase. Methods are pure: they take already-resolved strings (container
  # paths, text) and return the prompt — no I/O, no context lookups.
  module Prompts
    # The JSON object the triage model emits for each work package (one per item,
    # between the ---BEGIN/END JSON--- delimiters).
    #
    #   - Angle-bracket values are instructions to the model, not literals.
    #   - Keys must match the backlog item fields: the parsed object is merged
    #     straight into each entry by Backlog#merge_triage_results.
    TRIAGE_SCHEMA = <<~JSON
      {
        "id":             "<same id as input>",
        "locality_group": "<subsystem: auth|api|db|ui|payments|...>",
        "complexity":     "<trivial|simple|moderate|complex>",
        "files_touched":  ["<likely source file paths>"],
        "ai_category":    "<null-safety|type-error|logic-bug|perf|refactor|test|feature|chore>",
        "state":          "pending"
      }
    JSON

    # Triage a batch of work packages into locality/complexity/category scores.
    def self.triage(paths:)
      <<~PROMPT
        Read each of these work package files:
        #{paths}

        Each file has: id, subject, description, comments[], version, category, priority.

        For each item print one line:
          #<id> <subject> → <locality_group> / <complexity>

        Then output the complete results between these exact delimiters — nothing after the closing delimiter:
        ---BEGIN JSON---
        [one object per item]
        ---END JSON---

        Schema per object:
        #{TRIAGE_SCHEMA}

        Complexity guide:
          trivial  — single obvious fix, ≤2 files
          simple   — clear fix, ≤5 files
          moderate — spans multiple subsystems
          complex  — architectural impact or high risk

        Set state to "pending" — this marks the item as triaged and ready to fix.
      PROMPT
    end

    # WRITER: produce a fresh implementation plan for an issue.
    def self.plan(repo:, item:, files_hint:, item_id:, title:)
      <<~PROMPT
        PRODUCT REPO: #{repo}
        ISSUE:        #{item}  (JSON — fields: subject, description, comments[], version, files_touched)
        HINT FILES:   #{files_hint}
        You are the WRITER. Produce a plan only — do not modify any file.

        ## Plan: ##{item_id} — #{title}
        ### Files to change
        ### Approach
        ### Tests to run
        ### Risks / assumptions
      PROMPT
    end

    # WRITER: revise an existing plan to incorporate reviewer/user feedback.
    def self.replan(repo:, item:, plan:, feedback:, item_id:, title:)
      <<~PROMPT
        PRODUCT REPO:  #{repo}
        ISSUE:         #{item}  (JSON — fields: subject, description, comments[], version, files_touched)
        EXISTING PLAN: #{plan}
        FEEDBACK:      #{feedback}

        You are the WRITER. Revise the existing plan to incorporate the feedback above.
        Preserve structure and content that is still valid; only change what the feedback requires.
        Produce a plan only — do not modify any file.

        ## Plan: ##{item_id} — #{title}
        ### Files to change
        ### Approach
        ### Tests to run
        ### Risks / assumptions
      PROMPT
    end

    # REVIEWER: critique a plan and emit a PROCEED|REVISE|REJECT verdict.
    def self.plan_review(plan:, item_id:)
      <<~PROMPT
        You are the REVIEWER. Read the plan at #{plan} and critique it.
        Flag: wrong file paths, missing edge cases, unnecessary complexity, blast radius.

        ## Review: ##{item_id}
        ### Issues found  (or 'None')
        ### Suggested adjustments  (or 'None')
        ### Verdict  PROCEED | REVISE | REJECT
      PROMPT
    end

    # WRITER: revise a plan based on the reviewer's critique.
    def self.plan_revise(plan:, review:)
      <<~PROMPT
        Read the original plan at #{plan} and the review at #{review}.
        Revise the plan incorporating the reviewer's suggestions.
        Print the complete revised plan to stdout only — do not write or edit any files.
      PROMPT
    end

    # IMPLEMENTER: apply the approved plan to the worktree (tools: Read/Write/Edit/Bash).
    def self.implement(repo:, plan:)
      <<~PROMPT
        PRODUCT REPO: #{repo}
        APPROVED PLAN: #{plan}

        Check the current state of the worktree (uncommitted changes, existing work in progress).
        Continue from wherever things are — there may already be partial or complete work in place.
        Implement what's missing to fix the issue according to the plan.
        - Write tests as specified in the plan, then implement the fix
        - Do not commit
      PROMPT
    end

    # Generate a GitHub PR description for a committed fix.
    def self.pr_description(item:, plan:, diff_stat:, template_section:)
      <<~PROMPT
        Write a GitHub PR description for this fix.

        ISSUE: #{item}
        PLAN:  #{plan}
        DIFF:
        #{diff_stat}
        #{template_section}
        Always include a ## Screenshots section immediately after the "## What approach did you choose and why?" section,
        even if empty (write "N/A" or "No visual changes").
        Output only the PR description — no preamble.
      PROMPT
    end

    # Conversational reply to an @chomper comment on a work package (read-only tools).
    def self.chat(item_id:, subject:, plan:, message:)
      <<~PROMPT
        You are chomper, an AI code assistant working on OpenProject work package ##{item_id}: #{subject}

        CURRENT PLAN:
        #{plan}

        AVAILABLE COMMANDS (mention these when relevant):
        - @chomper plan       — generate an implementation plan
        - @chomper revise ... — revise the plan with feedback
        - @chomper proceed    — approve the plan and trigger implementation

        USER: #{message}

        Reply helpfully and concisely. Your response will be posted as an internal note.
      PROMPT
    end
  end
end
