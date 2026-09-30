module OPilot
  module Prompts
    module Scribe
      extend Sections
      ROLE = :scribe

      # Generate a GitHub PR description for a committed fix.
      def self.pr_description(item:, plan:, diff_stat:, template_section:)
        tagged(<<~PROMPT)
          Write a GitHub PR description for this change.
          #{READ_ONLY}

          The issue and plan are already in this session's context — do NOT re-read them.
          Base the description on the diff below. (The paths are only a fallback for the rare
          case where they are genuinely missing from your context.)

          ISSUE: #{item}
          PLAN:  #{plan}
          DIFF:
          #{diff_stat}
          #{template_section}
          Always include a ## Screenshots section immediately after the "## What approach did you choose and why?" section,
          even if empty (write "N/A" or "No visual changes").
          Keep it tight — a sentence or two per section; don't restate the issue or
          narrate the diff file-by-file. The full plan is linked from the PR, so
          summarize the approach at a high level. Output only the PR description —
          no preamble.

          #{PLAIN_ENGLISH}
        PROMPT
      end

      # A one-line git commit subject for the follow-up change opilot just made on
      # a PR branch. Stateless — the diff is embedded — so it runs on a cheap model
      # (MODEL_LIGHT) without dragging the gh-reply session's context, since the
      # subject describes the change itself, not the feedback that prompted it.
      def self.commit_subject(diff:)
        tagged(<<~PROMPT)
          Write a single git commit subject line for this change:

          #{diff}

          - Imperative mood, e.g. "Guard against a nil invoice total".
          - At most ~70 characters; no trailing period; no enclosing quotes.
          - Describe the change itself, not the reviewer or the request.
          - Do NOT prefix it with an issue id or "[…]" tag.
          - Output ONLY the subject line — nothing before or after it.
        PROMPT
      end
    end
  end
end
