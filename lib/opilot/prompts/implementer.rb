module OPilot
  module Prompts
    module Implementer
      extend Sections
      ROLE = :implementer

      # IMPLEMENTER: apply the approved plan to the worktree (tools: read/write/edit/bash).
      # `resumed:` — true when the call resumes the planning session (the plan is
      # already in context); false for a fresh session (must read the plan first).
      def self.implement(repos:, plan:, resumed: true)
        plan_line =
          if resumed
            "The approved plan is already in this session's context — you produced it earlier.\n        Implement it now; do NOT re-read the plan file."
          else
            "Read the approved plan at the path above, then implement it."
          end
        repo_list = repos.map { |r| "  - #{r[:name]}  (#{r[:path]})" }.join("\n")
        tagged(<<~PROMPT)
          TARGET REPO(S) — edit files ONLY within these worktrees, per the plan:
          #{repo_list}
          Read each target repo's CLAUDE.md and AGENTS.md (at its root, if present)
          FIRST — the harness does not load them for you.
          APPROVED PLAN: #{plan}

          #{plan_line}

          This is the IMPLEMENTATION step — the one phase where you should edit files
          in the worktree(s) above. The plan has been approved; apply it now.

          Check the current state of the worktree first and continue from wherever
          things are — there may already be partial or complete work in place.
          - Write tests as specified in the plan, then implement the change.
          - Do NOT commit or push, and do NOT run tests, linters, or builds, or any
            other command — only read and edit files; tests run later in review/CI.
            You MAY run read-only git (log, show, blame, diff, for-each-ref) for context.
          #{DELETE_NOTE}
        PROMPT
      end

      # IMPLEMENTER: build ONE work package of a change — one top-level tasks.md
      # section — from the spec the reviewer already approved.
      #
      # The mirror image of #propose: there the spec was the output and source was
      # off limits, here the spec is the INPUT and source is the deliverable. The
      # scope that matters is horizontal rather than vertical — the sibling sections
      # are other people's work packages, each with its own PR, so a run that
      # helpfully implements two of them makes both unreviewable.
      def self.implement_task(repo:, repo_path:, change_id:, change_dir:, wp_label:, section:, tasks:, item:)
        tagged(<<~PROMPT)
          You are the IMPLEMENTER. Build work package #{wp_label} of the OpenSpec
          change `#{change_id}`.

          TARGET REPO — edit files ONLY inside this worktree:
            #{repo}  (#{repo_path})

          THE SPEC — read this first; it is the requirement, not a suggestion:
            #{change_dir}/proposal.md   why the change exists and what it covers
            #{change_dir}/design.md     the decisions already taken (may be absent)
            #{change_dir}/specs/        the requirement deltas, with their scenarios
            #{change_dir}/tasks.md      every work package of this change
          WORK PACKAGE: #{item} (as OpenProject has it — read it for anything a
          human added after the proposal was written; its comments may qualify or
          override the spec, and if they conflict, the newer human wins.)

          YOUR SCOPE is this one section of tasks.md and nothing else:

          ## #{section}
          #{tasks}

          The other sections of tasks.md are separate work packages with their own
          branches and their own PRs. Do not start on them, however small or
          related they look — work that lands in the wrong PR cannot be reviewed.
          If this section cannot be built without part of another one, implement
          the smallest amount of it that unblocks you and say so in your summary.

          #{TOOLING}

          - Check the worktree first and continue from wherever things are: a
            previous run may have left partial work in place.
          - Write the tests the spec's scenarios describe, then the implementation.
          - Do NOT edit anything under #{change_dir} or any other `openspec/` path.
            The spec is your input here, and opilot ticks the checkboxes itself
            once this work lands.
          - Do NOT commit or push, and do NOT run tests, linters, builds, or any
            other command — only read and edit files; tests run later in review/CI.
            You MAY run read-only git (log, show, blame, diff, for-each-ref) for context.
          #{DELETE_NOTE}
        PROMPT
      end
    end
  end
end
