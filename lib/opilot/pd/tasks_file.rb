module OPilot
  module PD
    # Parsing and rewriting of an OpenSpec change's tasks.md.
    #
    # The file is the binding between the spec tree and OpenProject: each
    # top-level section becomes one IMPLEMENTATION work package, and the id is
    # written back inline as `(#1204)` in the heading. Inline is deliberate — it
    # shows up in diffs, survives agent edits to surrounding prose, and makes the
    # tree reconcilable with a single grep.
    #
    #   ## Dose logging UI (#1204)
    #   - [ ] Form component with validation
    #   - [ ] Empty and error states
    module TasksFile
      module_function

      # A top-level section: its heading text, the work-package id bound to it
      # (nil until generate-wp creates one), and its checklist items.
      Section = Struct.new(:title, :wp_id, :items, :line, keyword_init: true)

      # `## Title` or `## Title (#id)`, where the id is numeric or semantic —
      # matching Helpers::WP_ID_PATTERN, since instances in semantic-identifier
      # mode produce "PROJ-42" rather than "42".
      HEADING = /\A\#\#[ \t]+(?<title>.+?)(?:[ \t]*\(\#(?<id>\d+|[A-Z][A-Z0-9_]*-\d+)\))?[ \t]*\z/
      CHECKBOX = /\A[ \t]*[-*][ \t]+\[(?<done>[ xX])\][ \t]+(?<text>.*)\z/

      # Parse top-level sections out of tasks.md text.
      #
      # Fenced code blocks are blanked first: a `## Something` inside a ``` fence
      # is illustrative markdown, not a section, and treating it as one would
      # create a garbage work package that a human then has to clean up. Since
      # nothing here can delete a WP, a false positive is expensive — so the
      # parser errs toward missing a section rather than inventing one.
      def parse(text)
        sections = []
        each_live_line(text) do |line, idx|
          if (m = HEADING.match(line))
            sections << Section.new(title: m[:title].strip, wp_id: m[:id], items: [], line: idx)
          elsif (m = CHECKBOX.match(line)) && sections.any?
            sections.last.items << { text: m[:text].strip, done: m[:done].downcase == "x" }
          end
        end
        sections
      end

      # Every work-package id currently bound in this text.
      def wp_ids(text)
        parse(text).filter_map(&:wp_id)
      end

      # Bind `wp_id` to the section titled `title`, rewriting its heading in place
      # and returning the new text. A section that already carries an id is left
      # alone — the binding is created once and never rewritten, because the id is
      # the only link back to a work package that may have accumulated comments
      # and history.
      def bind_id(text, title, wp_id)
        rewrite_heading(text, title) do |m|
          next nil if m[:id]
          "## #{m[:title].strip} (##{wp_id})"
        end
      end

      # Tick (or untick) every checkbox in the section titled `title`. The harness
      # owns these edits, never the agent — see the plan's §6 on why concurrent
      # runs must not both be writing this file.
      def set_section_done(text, title, done: true)
        in_target = false
        map_live_lines(text) do |line|
          if (m = HEADING.match(line))
            in_target = m[:title].strip == title
            next line
          end
          next line unless in_target
          m = CHECKBOX.match(line)
          next line unless m
          line.sub(/\[[ xX]\]/, done ? "[x]" : "[ ]")
        end
      end

      # --- internals -------------------------------------------------------

      FENCE = /\A[ \t]*(?<fence>`{3,}|~{3,})/

      # The single fence-tracking pass both public helpers below are built on.
      # Yields [raw_line, chomped_line, index, live], where `live` is false for a
      # fence marker or anything inside one.
      def scan(text)
        fence = nil
        text.to_s.lines.each_with_index do |raw, idx|
          line = raw.chomp
          if (m = FENCE.match(line))
            fence = if fence.nil? then m[:fence][0]
                    elsif m[:fence].start_with?(fence) then nil
                    else fence
                    end
            next yield(raw, line, idx, false)
          end
          yield raw, line, idx, fence.nil?
        end
      end

      # Yield [line, index] for every line that is NOT inside a fenced code block.
      def each_live_line(text)
        scan(text) { |_raw, line, idx, live| yield(line, idx) if live }
      end

      # Rebuild the text, passing each non-fenced line through the block. Lines
      # inside fences pass through untouched.
      def map_live_lines(text)
        out = +""
        scan(text) do |raw, line, _idx, live|
          out << (live ? "#{yield(line)}#{raw[line.length..] || ""}" : raw)
        end
        out
      end

      def rewrite_heading(text, title)
        map_live_lines(text) do |line|
          m = HEADING.match(line)
          next line unless m && m[:title].strip == title
          yield(m) || line
        end
      end
    end
  end
end
