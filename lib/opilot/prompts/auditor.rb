module OPilot
  module Prompts
    module Auditor
      extend Sections
      ROLE = :auditor

      # One-shot health check of a work package (read-only tools, no session).
      # `facts` is the container path to health.json: the rules the runner already
      # checked from exact data, so the model neither repeats nor disputes them.
      # `descendants` is the container path to descendants.json, :none for a work
      # package without children, or nil when the subtree could not be read.
      def self.health(item_id:, subject:, item:, facts:, related: nil, descendants: nil, focus: "",
                      internal: true, op_mcp: false)
        focus_line = focus.to_s.strip.empty? ? "" : "\nFOCUS: look especially at: #{focus.strip}\n"
        audience = internal ? "an internal comment" : "a PUBLIC comment — do not cite or quote an internal comment"
        # related_line omits the field when empty, which reads as "not loaded".
        related_text = related.to_s.empty? ? "\nRELATED: none — this work package has no relations, parent, or children." : related_line(related)
        tree_text, tree_check =
          case descendants
          when nil   then ["", ""]
          when :none then ["\nDESCENDANTS: none — this work package has no children.", ""]
          else
            ["\nDESCENDANTS: #{descendants}  (JSON array — every work package under this one, at any " \
             "depth: id, parent, depth, subject, type, status. The runner already checked the " \
             "statuses across the tree.)",
             "\n5. The description against the descendants. A requirement in the description that\n" \
             "   no descendant covers, a descendant outside the scope of the description, or two\n" \
             "   descendants that do the same work. Use the subjects; open a descendant with\n" \
             "   op_query only when its subject is not enough to decide."]
          end
        tagged(<<~PROMPT)
          #{charter}

          Check the health of OpenProject work package #{Helpers.wp_label(item_id)}: #{subject}

          ISSUE: #{item}  #{item_fields("type", "status", "history[]", "description_changed_at")}#{related_text}#{tree_text}#{op_query_line(op_mcp)}
          history[] holds the field changes (status, assignee, description, …) as the
          instance renders them. description_changed_at is the time of the last
          description edit.
          FACTS: #{facts}  (JSON — `findings` the runner already established from exact
          data, `not_checked`, and `inputs`: linked pull requests and commits. Do NOT
          repeat a fact finding and do NOT dispute it. Use `inputs` as evidence.)
          #{focus_line}
          Find where this work package is not consistent with itself. Check:
          1. The description against the comments. A decision, a scope change, or a new
             acceptance criterion in a comment that the description does not show. A
             comment that contradicts the description. A question nobody answered.
             Reactions on a comment (a 👍 from the assignee) are a sign of agreement.
          2. The description against the pictures. `read` every entry in pictures[].
             A mockup that shows a field, a label, or a flow that the text does not
             mention, or the opposite. When you cannot see a picture, write a GAP.
          3. The description against the related work packages. Overlapping scope, or
             a related work package that already did part of this work.
          4. The status against history[] and the comments. For example, a comment
             after the work package closed that reports the problem again.#{tree_check}

          opilot is the tool that runs this check. Comments by `inputs.opilot_user_href`,
          and comments that give opilot a command (`@opilot build`, …), are tool traffic,
          not requirements: do not report on them. A pull request in `inputs.opilot_prs`
          is a draft prototype. It does not change the status, so a status that ignores
          it is correct.

          Report only what the evidence shows. Do not report style, wording, or a
          missing detail that no comment asks for. Do not propose a fix. Do not write
          a GAP for an item that is already in `not_checked`. Report one problem ONE
          time, even when two checks show it: use the area that shows its cause, and
          put all the evidence in that one finding.

          This report is posted as #{audience}.

          #{HEALTH_CONTRACT}

          #{PLAIN_ENGLISH}
        PROMPT
      end
    end
  end
end
