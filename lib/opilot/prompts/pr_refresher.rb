module OPilot
  module Prompts
    module PrRefresher
      extend Sections

      # Refresh a stale opilot-opened PR on demand (tools: read/write/edit).
      # Unlike gh_reply/fix_ci (comment- and CI-triggered), the trigger is the
      # operator's terminal `pr` command, and the work is whichever of the three
      # task blocks apply: resolve the conflicts a base-branch merge left behind,
      # fix what CI is failing on, and address review feedback that has gone
      # unanswered. The runner commits and pushes; the LLM never runs git.
      def self.pr_refresh(worktree:, repo:, pr_number:, title:, base:, item:, plan:, pr_thread:,
                          ci: nil, conflicts: [], feedback_count: 0)
        tasks = []
        if conflicts.any?
          tasks << <<~TEXT.strip
            MERGE CONFLICTS — merging origin/#{base} into the PR branch stopped on
            conflicts in:
            #{conflicts.map { |f| "  - #{f}" }.join("\n")}
            Resolve each conflict in place: edit the file so it keeps both the
            upstream changes and this PR's intent, removing every <<<<<<< / ======= /
            >>>>>>> marker. Never resolve by blindly taking one side.
          TEXT
        end
        if ci
          tasks << <<~TEXT.strip
            CI FAILURES: #{ci}  #{CI_FAILURES_NOTE}
            Find the root cause and fix it. If a failure is clearly flaky or
            infrastructure (a network blip, an unrelated timeout), do NOT change
            code for it — say so in your reply instead.
          TEXT
        end
        if feedback_count.positive?
          tasks << <<~TEXT.strip
            UNADDRESSED FEEDBACK — the PR thread holds #{feedback_count} comment(s)
            newer than opilot's last action on this PR. Read the thread, make the
            concrete changes reviewers asked for, and answer their questions in your
            reply.
          TEXT
        end
        sync_note = conflicts.any? ? ", with a merge of origin/#{base} in progress" : ""
        tagged(<<~PROMPT)
          #{charter}

          The operator asked you to refresh
          GitHub pull request ##{pr_number} ("#{title}") in #{repo} — a stale PR you
          opened. Its branch is checked out in the product worktree at #{worktree},
          already synced to the PR head#{sync_note}.

          #{pr_context(item: item, plan: plan, pr_thread: pr_thread)}

          Work through each item below in the worktree (#{worktree}):

          #{tasks.join("\n\n")}

          Ground rules:
          #{PR_WRITE_RULES}

          #{REPLY_CONTRACT}
        PROMPT
      end
    end
  end
end
