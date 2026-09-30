module OPilot
  module Prompts
    module Triager
      extend Sections

      # Write ONE work package from ONE AppSignal exception incident
      # (`./opilot appsignal fix`; read-only tools, the runner does the POST).
      #
      # It states create_wp's BEGIN/END WORK PACKAGE contract again rather than
      # sharing a constant with it: the same Helpers.parse_work_packages reads both
      # outputs, but the surrounding rules differ enough (one block, not several;
      # no LINK line, because there is no work package to link to; a backtrace as
      # the source instead of a thread) that a shared block would need a
      # conditional per paragraph. The MARKER LINES rule is the part that must not
      # drift — it is enforced by Helpers::WP_BEGIN/WP_END and by
      # Helpers.wp_format_miss, which both prompts share.
      #
      # Exactly one block, and that is not a cap to be argued with: one incident is
      # one bug. A crash appearing in three places is still one fault, and its plan
      # is where the shape of the fix belongs.
      #
      # NEEDS_INFO when the backtrace names no code in any repo — a stack trace
      # entirely inside a gem or the framework is somebody else's bug, and a work
      # package that cannot be deleted is the wrong way to find that out.
      def self.appsignal_wp(incident:, number:, app:, repos:, types:, format_note: nil)
        listing = repos.map { |r| "  - #{r[:name]}  (#{r[:path]})  — #{r[:description]}" }.join("\n")
        tagged(<<~PROMPT)
          #{charter}

          This is AppSignal incident ##{number} on "#{app}".
          Turn this production error into ONE work package a developer can pick up.
          The runner creates it in OpenProject and then plans the fix from it.

          INCIDENT: #{incident}  (JSON. Read the whole file first. Fields:
          exceptionName, exceptionMessage, actionNames, namespace, count;
          `backtrace[]` with path/line/method; and `request` — the action, the
          HTTP headers, the tags, and `request.payload`, which is the actual
          request body that triggered this error.)

          AVAILABLE REPOS — the code this error comes from is in one of these, each
          checked out at the path shown. Read the backtrace, then read the code it
          names.
          #{listing}

          FIRST, find the fault. Walk `backtrace[]` to the deepest frame that is in
          one of these repos, read that code, and work out what actually went
          wrong. Do not stop at the exception name — "NoMethodError on nil" is a
          symptom, and the work package is worth nothing without the cause.

          READ `request.payload` AGAINST THAT CODE. It is the input that produced
          the error, and for a validation or parsing failure it usually IS the
          answer — which field was missing, which value was the wrong shape. Quote
          the part that matters. A backtrace says where a check failed; the payload
          says why.
          #{format_note_line(format_note)}
          END YOUR OUTPUT with a line containing exactly `ANSWER:`, and put the
          answer after it. Only what follows the last `ANSWER:` line is used;
          everything before it is discarded, so any thinking you need goes there —
          but keep it to a few lines. You have a hard output limit: a run that
          spends it deliberating produces NOTHING.

          After `ANSWER:`, answer with EITHER

          (a) the single word NEEDS_INFO, then what is missing — when the backtrace
          names no code in any repo above, when it is entirely inside a gem or the
          framework, or when the incident carries too little to identify a fault.
          Do NOT guess. A work package cannot be deleted, so a wrong one stays
          forever.

          (b) or exactly ONE block, in EXACTLY this shape:

              BEGIN WORK PACKAGE
              SUBJECT: <one line, under 120 characters, no ticket id>
              TYPE: <one of: #{types}>

              <the description>
              END WORK PACKAGE

          Write ONE block. One incident is one bug, even when it fires in several
          places.

          THE MARKER LINES: both are needed, each alone on its own line, spelled
          exactly. A block with no `END WORK PACKAGE` line is read as a cut-off
          answer and the WHOLE answer is thrown away. If the description quotes a
          line that looks like a marker, put the quote in a fenced code block.

          THE DESCRIPTION:
          - Open with what breaks for a user, in one sentence. Not the exception
            class — what a person saw.
          - Then the fault: name the file and line, and say what the code does that
            is wrong. Quote the few relevant lines in a fenced code block.
          - Then the backtrace's top frames, in a fenced code block. Not all of it.
          - Say what you do NOT know, named as an open question. You are reading one
            error, not a reproduction.
          - Do not propose the fix in detail — the plan does that next, and a
            description that prescribes one narrows it too early. One sentence on
            the likely direction is enough.
          - Write no headings above `##`, and add no title line — the subject is the title.
          - Do not write "@opilot" anywhere.

          #{PLAIN_ENGLISH}
        PROMPT
      end
    end
  end
end
