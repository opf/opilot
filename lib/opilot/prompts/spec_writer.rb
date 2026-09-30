module OPilot
  module Prompts
    module SpecWriter
      extend Sections

      # The write scope every propose/revise run is held to. Enforced afterwards by
      # the runner (which resets anything outside it), but stated here too so a run
      # normally never trips the gate.
      def self.spec_scope(change_dir)
        <<~TEXT.strip
          WRITE SCOPE — you may create or edit files ONLY inside:
            #{change_dir}
          Do not touch application source, tests, or any other part of the repo.
          This is a planning stage; nothing outside the change directory is yours.
          A write outside it discards the whole run, so stay inside it.
        TEXT
      end

      # WRITER: turn the intake material into an OpenSpec change proposal.
      #
      # The one-feature gate mirrors Planner.plan's NEEDS_INFO sentinel: a change
      # maps to exactly one FEATURE work package, so material that plainly spans
      # several must stop rather than be crammed into one proposal.
      def self.propose(change_id:, change_dir:, intake_dir:, specs_dir:, repo:, repo_path:, instructions:)
        tagged(<<~PROMPT)
          #{charter}

          Produce an OpenSpec change proposal for `#{change_id}`.

          INTAKE (the raw human intent — read all of it first):
            #{intake_dir}
            #{intake_dir}/attachments/README.md lists every attachment, what it was
            converted to, and anything that could NOT be read. Treat an unreadable
            attachment as a known gap, not as absent.
          EXISTING SPECS (what is already built — read what is relevant):
            #{specs_dir}
          CODEBASE: the #{repo} repository is checked out at #{repo_path}. Read it to
          ground the proposal in the system that actually exists.

          #{TOOLING}

          #{spec_scope(change_dir)}

          FIRST, judge scope. A change becomes exactly ONE work package of type
          FEATURE — one atomic, QA-able feature. If the intake plainly covers more
          than one such feature, write NO files at all and output exactly the
          following, starting on the very first line, then stop:

            TOO_BROAD
            ### Suggested split
            - <one line per feature you would propose separately>

          If the scope is fine, just write the files — don't narrate the check.

          Otherwise write the artifacts below, in the order given, and nothing else.

          These instructions come from the `openspec` CLI itself — follow each
          artifact's <instruction> and <template> exactly. `openspec validate
          --strict` runs afterwards and only checks part of this, so matching the
          template is on you, not on the validator.

          #{instructions}

          Two things opilot needs on top of the above:
          - In tasks.md, each top-level `## ` section becomes ONE work package, so
            make them independently implementable and reviewable. Aim for 3-6.
          - Ground every claim in the intake or the code. Where the intake is silent
            on something you had to decide, say so in design.md rather than
            inventing a requirement.

          #{PLAIN_ENGLISH}
        PROMPT
      end

      # WRITER: fix a proposal the strict validator rejected. Runs in the same
      # session, so the artifacts are already in context.
      def self.propose_revise(change_id:, change_dir:, failures:, attempt:, max_attempts:)
        tagged(<<~PROMPT)
          `openspec validate #{change_id} --strict` rejected the proposal you just
          wrote (attempt #{attempt} of #{max_attempts}):

          #{failures}

          #{spec_scope(change_dir)}

          Fix exactly what the validator reported and nothing else — the proposal's
          content was not the problem, its structure was. The most common causes are
          a requirement with no scenario, a delta missing its ADDED/MODIFIED/REMOVED
          heading, and a malformed scenario block.
        PROMPT
      end

      # WRITER: revise a proposal in response to review comments on its spec PR.
      # Same write scope; the reviewer's words are the instruction.
      def self.propose_feedback(change_id:, change_dir:, pr_thread:, comment_section:)
        tagged(<<~PROMPT)
          #{charter}

          Revise the OpenSpec change proposal `#{change_id}` in response to review
          feedback on its pull request.

          PROPOSAL: #{change_dir}
          PR THREAD: #{pr_thread}  #{THREAD_NOTE}

          #{comment_section}

          #{spec_scope(change_dir)}

          Apply what the comment asks for. Preserve everything still valid — revise,
          don't rewrite. If the comment is a question rather than a change request,
          make no edits and answer it in your reply.

          #{PLAIN_ENGLISH}
        PROMPT
      end
    end
  end
end
