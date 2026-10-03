module OPilot
  module Prompts
    module PrAuthor
      extend Sections

      # In the system prompt (Prompts.charter), not in each builder.
      SYSTEM_RULES = [PLAIN_ENGLISH].freeze

      # Reply to a comment on a opilot-opened GitHub PR (tools: read/write/edit).
      # "Always reply, code if asked": the LLM answers every comment, and edits the
      # worktree only when the comment requests a concrete change. It must not run
      # git — the runner commits any changes and pushes them to the bot's fork to
      # update the draft PR; merging still requires a maintainer.
      def self.gh_reply(worktree:, repo:, pr_number:, title:, item:, plan:, pr_thread:,
                        comment:, author:, comment_id:, in_reply_to: nil, op_mcp: false)
        tagged(<<~PROMPT)
          A comment arrived on GitHub pull request ##{pr_number} ("#{title}") in #{repo}.
          The PR's branch is checked out in the product worktree at #{worktree}.

          #{pr_context(item: item, plan: plan, pr_thread: pr_thread)}#{op_query_line(op_mcp)}

          #{comment_section(comment_id: comment_id, author: author, comment: comment, in_reply_to: in_reply_to)}

          Decide what is being asked:
          - A question or discussion → just reply in text. Do NOT touch any file.
          - A concrete code change → make the change in the worktree (#{worktree}), then
            reply describing what you changed.

          When you do change code:
          #{PR_WRITE_RULES}

          #{MERMAID_NOTE}

          #{DESCRIPTION_CONTRACT}

          #{REPLY_CONTRACT}
        PROMPT
      end

      # Fix a failed CI run on a opilot-opened PR (tools: read/write/edit). Mirrors
      # gh_reply, but the trigger is CI rather than a comment: the LLM reads the
      # cached failure detail and fixes the defect in the worktree. The runner
      # commits and pushes to update the draft PR; the LLM must not run git itself.
      def self.fix_ci(worktree:, repo:, pr_number:, title:, item:, plan:, pr_thread:, ci:, op_mcp: false)
        tagged(<<~PROMPT)
          CI failed on GitHub pull request ##{pr_number} ("#{title}") in #{repo} — a PR
          you opened. Its branch is checked out in the product worktree at
          #{worktree}. Fix what CI is complaining about.

          CI FAILURES: #{ci}  #{CI_FAILURES_NOTE}
          #{pr_context(item: item, plan: plan, pr_thread: pr_thread)}#{op_query_line(op_mcp)}

          Read the failure detail and the diff (`git diff` against the base in #{worktree}),
          find the root cause, and fix it in the worktree.
          - Fix the actual defect — never silence a check by deleting or skipping the
            failing test.
          - If the failure is clearly flaky or infrastructure (a network blip, an
            unrelated timeout, a transient runner error) rather than a defect this PR
            introduced, do NOT change code — reply saying so and that a re-run is
            likely all it needs.
          #{PR_WRITE_RULES}

          #{REPLY_CONTRACT}
        PROMPT
      end
    end
  end
end
