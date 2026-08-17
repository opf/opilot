require_relative "../../test_helper"

module OPilot
  module PD
    class TasksFileTest < Minitest::Test
      TASKS = <<~MD
        # Recurring meetings

        ## RRule parsing (#59943)
        - [x] Parse RFC 5545 recurrence rules
        - [ ] Reject unsupported frequencies

        ## Occurrence materialisation
        - [ ] Expand a rule into occurrences
      MD

      def test_parses_sections_with_and_without_ids
        sections = TasksFile.parse(TASKS)
        assert_equal ["RRule parsing", "Occurrence materialisation"], sections.map(&:title)
        assert_equal "59943", sections[0].wp_id
        assert_nil sections[1].wp_id, "an unbound section has no id until generate-wp creates one"
        assert_equal 2, sections[0].items.length
        assert_equal [true, false], sections[0].items.map { |i| i[:done] }
      end

      def test_ignores_headings_inside_fenced_code_blocks
        # A `##` in an example block is illustrative markdown, not a section.
        # Treating it as one would create a work package nothing can delete.
        text = <<~MD
          ## Real section

          ```markdown
          ## Not a section (#999)
          - [ ] not an item
          ```

          ~~~
          ## Also not a section
          ~~~

          ## Second real section
        MD
        sections = TasksFile.parse(text)
        assert_equal ["Real section", "Second real section"], sections.map(&:title)
        refute_includes TasksFile.wp_ids(text), "999"
        assert_empty sections[0].items, "checkboxes inside the fence are not items either"
      end

      def test_wp_ids_accepts_semantic_identifiers
        assert_equal %w[PROJ-42], TasksFile.wp_ids("## A section (#PROJ-42)\n")
      end

      def test_bind_id_writes_the_id_into_the_heading
        out = TasksFile.bind_id(TASKS, "Occurrence materialisation", 59_944)
        assert_includes out, "## Occurrence materialisation (#59944)"
        assert_equal %w[59943 59944], TasksFile.wp_ids(out)
      end

      def test_bind_id_never_rewrites_an_existing_binding
        # The id is the only link to a work package that may have accumulated
        # comments and history — rebinding would silently orphan it.
        out = TasksFile.bind_id(TASKS, "RRule parsing", 60_000)
        assert_includes out, "## RRule parsing (#59943)"
        refute_includes out, "60000"
      end

      def test_bind_id_leaves_other_sections_untouched
        out = TasksFile.bind_id(TASKS, "Occurrence materialisation", 59_944)
        assert_includes out, "- [x] Parse RFC 5545 recurrence rules"
        assert_equal TASKS.lines.length, out.lines.length
      end

      def test_set_section_done_ticks_only_the_named_section
        out = TasksFile.set_section_done(TASKS, "Occurrence materialisation")
        assert_includes out, "- [x] Expand a rule into occurrences"
        assert_includes out, "- [ ] Reject unsupported frequencies",
                        "the other section's checkboxes are untouched"
      end

      def test_set_section_done_can_untick
        ticked = TasksFile.set_section_done(TASKS, "RRule parsing")
        assert_includes TasksFile.set_section_done(ticked, "RRule parsing", done: false),
                        "- [ ] Parse RFC 5545 recurrence rules"
      end

      def test_round_trips_unknown_content_unchanged
        assert_equal TASKS, TasksFile.set_section_done(TASKS, "No such section")
        assert_equal TASKS, TasksFile.bind_id(TASKS, "No such section", 1)
      end
    end
  end
end
