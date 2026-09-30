module OPilot
  module Prompts
    module PrAdvisor
      extend Sections

      # How a read-only review proposes an *applicable* code change on a PR opilot
      # can't push to: a GitHub suggestion the author commits with one click. The
      # block is machine-parsed (GitHub::Agent#parse_suggestions) into inline review
      # comments, so its shape is exact.
      SUGGESTION_CONTRACT = Prompts.block("suggestion_contract")

      # Reply to an @opilot comment on an UPSTREAM PR opilot did not open
      # (read-only tools). opilot cannot push to this PR's branch, so it reviews
      # and answers in text only — it must never edit files.
      def self.pr_review(repo:, pr_number:, title:, worktree:, base:, pr_thread:,
                         comment:, author:, comment_id:, in_reply_to: nil, ci: nil)
        tagged(<<~PROMPT)
          #{charter}

          You are asked about GitHub pull request ##{pr_number} ("#{title}") in #{repo} —
          a repo you do NOT own. The PR's branch is checked out at #{worktree}; its
          changes are `git diff origin/#{base}...HEAD`.

          You cannot push to this PR, and you must NEVER edit, create, or delete
          files yourself. But you CAN propose concrete edits as GitHub *suggestions*
          the author applies with one click: for a change to lines already in the
          PR's diff, emit a suggestion (see the contract below). For anything a
          suggestion can't express — a new file, a change outside the diff, a broad
          refactor — describe it precisely in your reply instead.

          PR THREAD: #{pr_thread}  #{THREAD_NOTE}
          #{ci_review_section(ci)}
          #{comment_section(comment_id: comment_id, author: author, comment: comment, in_reply_to: in_reply_to)}

          Read the diff and relevant files before answering; a review should be short
          and specific.

          #{SUGGESTION_CONTRACT}

          #{MERMAID_NOTE}

          #{REPLY_CONTRACT}
        PROMPT
      end

      # CI context for an upstream review, present only when the PR's checks are
      # failing (`ci` is the path to ci.json, else nil). Read-only: opilot can't
      # push to an upstream PR, so it explains rather than fixes. Vanishes when CI
      # is green or wasn't read, so the review runs on the diff + thread alone.
      def self.ci_review_section(ci)
        return "" if ci.to_s.empty?
        <<~TEXT.strip
          FAILING CI: #{ci}  #{CI_FAILURES_NOTE}
          When the comment is about CI, read this and explain what is failing and the
          most likely cause; if a code change is warranted, describe it for a human —
          you cannot push a fix to this PR.
        TEXT
      end
    end
  end
end
