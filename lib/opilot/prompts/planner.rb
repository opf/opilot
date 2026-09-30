module OPilot
  module Prompts
    module Planner
      extend Sections

      # First line of an answer that names the approach before (or instead of) a
      # plan. Shared by every reader of that answer (OpAgent, FixRunner) so the
      # word is written once.
      OPTIONS_SENTINEL = "OPTIONS"

      # The second gate on a `ship` plan call: name the approach before writing
      # the plan, and stop after naming 2-3 when there is a real choice — that
      # choice belongs to the reporter. `OpAgent#produce_plan` turns a stopped
      # multi-option answer into options.json plus one comment; a single named
      # approach reads straight through into the plan behind it.
      #
      # Folded into the plan call rather than run as its own call: the writer has
      # already read the repos, so the single-approach case costs no extra call.
      #
      # The option lines are pipe-delimited data, not prose — OpAgent#post_options
      # composes the comment, so its wording cannot pick up a heading or sign-off.
      OPTIONS_CONTRACT = Prompts.block("options_contract")

      # The AVAILABLE REPOS block + repo-selection instruction shared by plan/replan.
      # `repos` is an array of { name:, path:, description: }; `summary` is the
      # registry's top-level routing hint. the LLM reads across the listed repos and
      # declares its choice on the first line as `REPOS: <name>[, <name>…]`.
      def self.repos_section(summary, repos)
        listing = repos.map { |r| "  - #{r[:name]}  (#{r[:path]})  — #{r[:description]}" }.join("\n")
        hint = summary.to_s.strip.empty? ? "" : "\n#{summary.strip}"
        <<~TEXT.strip
          AVAILABLE REPOS — a fix may belong in one of these, or span several. Each is
          checked out at the path shown; read across them as needed to decide.#{hint}
          For each repo you touch, read its CLAUDE.md and AGENTS.md (at the repo's
          root, if present) FIRST — the harness does not load them for you.
          #{listing}

          On the first line of the PLAN declare the repo(s) this fix will touch,
          using only names from the list:  REPOS: <name>[@<base>][, <name>…]
          (When an OPTIONS line precedes the plan, REPOS still opens the plan
          itself, not the OPTIONS line — the option's own repo field is only an
          estimate.) Append @<base> ONLY when the issue or the user explicitly
          asks to base that repo's PR on a specific branch (e.g.
          openproject@release/17.6); a bare name uses the repo's default base.
          (If you emit NEEDS_INFO below, omit the REPOS line.)
        TEXT
      end

      # WRITER: produce a fresh implementation plan for an issue.
      #
      # Two gates. NEEDS_INFO is the sufficiency gate: on a vague WP the writer
      # emits it instead of a plan, and OpAgent#produce_plan posts the questions back
      # to the WP. `allow_options:` adds OPTIONS_CONTRACT whenever no human has
      # chosen an approach yet; it stays off once an option or a direction is given.
      #
      # The clause under NEEDS_INFO keeps that gate narrow, and the tilt is
      # deliberate rather than balanced: every feature ticket describes something
      # absent from the tree — that is what a feature ticket is — so a premise the
      # writer cannot verify must default to an assumption written into
      # "Risks / assumptions", not to a question. A false NEEDS_INFO costs more than
      # the loop SEARCH_STOP_RULE exists to stop: the loop wastes one harness slot
      # for one run, while OpAgent#produce_plan posts the questions into the activity
      # tab and stalls the ticket until somebody answers them.
      def self.plan(repos_summary:, repos:, item:, item_id:, title:, hint: "", related: nil,
                    allow_options: false, op_mcp: false)
        focus = hint.empty? ? "" : "\nFOCUS:        #{hint}"
        options_gate = allow_options ? "\nSECOND, name the approach.\n#{OPTIONS_CONTRACT}\n" : ""
        tagged(<<~PROMPT)
          #{charter}

          #{repos_section(repos_summary, repos)}

          ISSUE:        #{item}  #{item_fields("type", "status", "version", "assignee")}#{related_line(related)}#{focus}#{op_query_line(op_mcp)}
          Produce a plan only.

          #{SEARCH_STOP_RULE}

          FIRST, judge whether this issue gives you enough to plan a concrete fix.
          #{THIN_REPORT_GATE}
          When the issue is too thin to confidently locate AND reproduce the problem,
          do not write a plan — output exactly the following, starting on the first
          line, and stop:

            NEEDS_INFO
            ### Questions for the reporter
            - <each specific thing you need before you can proceed>

          A stated fact you cannot find is not a reason to stop. Write what you
          found under "Risks / assumptions", build the simpler shape, and continue.
          Use NEEDS_INFO for it ONLY when the missing fact changes the whole shape of
          the fix — never when it changes a detail you can state and move past.
          #{options_gate}
          Otherwise, produce the plan:

          #{plan_skeleton(item_id, title)}
        PROMPT
      end

      # The shape of plan.md, plus the language it is written in. A plan is read by
      # the reporter and the reviewer, not only by the implementer, so it obeys
      # PLAIN_ENGLISH like every other published text. Shared by plan and replan,
      # which must produce the same document.
      def self.plan_skeleton(item_id, title)
        <<~TEXT.strip
          #{PLAIN_ENGLISH}

          ## Plan: #{Helpers.wp_label(item_id)} — #{title}
          ### Files to change
          ### Approach
          (when a flow or a structure is hard to say in words, add one ```mermaid
          fence here — the plan is published as a gist, which shows it as a picture)
          ### Tests to run
          ### Risks / assumptions
        TEXT
      end

      # WRITER: revise an existing plan to incorporate reviewer/user feedback.
      # `resumed:` — true when the call resumes a session that already holds the
      # plan and issue (skip the re-read); false for a fresh session (read first).
      def self.replan(repos_summary:, repos:, item:, plan:, feedback:, item_id:, title:, resumed: true, related: nil,
                      op_mcp: false)
        context_line =
          if resumed
            "The existing plan and the issue are already in this session's context — do NOT re-read them."
          else
            "Read the existing plan and the issue from the paths above first."
          end
        tagged(<<~PROMPT)
          #{charter}

          #{repos_section(repos_summary, repos)}

          ISSUE:         #{item}
          EXISTING PLAN: #{plan}
          FEEDBACK:      #{feedback}#{related_line(related)}#{op_query_line(op_mcp)}

          #{context_line} Revise the plan to incorporate the feedback above.
          Preserve structure and content that is still valid; only change what the feedback requires.
          Produce a plan only.

          #{SEARCH_STOP_RULE}

          #{plan_skeleton(item_id, title)}
        PROMPT
      end
    end
  end
end
