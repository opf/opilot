require_relative "../test_helper"

module Chomper
  class CLITest < Minitest::Test
    def test_wp_id_arg_strips_pasted_hash_prefix_and_whitespace
      cli = CLI.new(nil)
      assert_equal "59942", cli.send(:wp_id_arg, "#59942")
      assert_equal "59942", cli.send(:wp_id_arg, " #59942 ")
      assert_equal "59942", cli.send(:wp_id_arg, "59942")
      assert_equal "", cli.send(:wp_id_arg, nil)
    end

    def test_wp_id_arg_accepts_and_normalizes_semantic_ids
      cli = CLI.new(nil)
      assert_equal "PROJ-123", cli.send(:wp_id_arg, "PROJ-123")
      assert_equal "PROJ-123", cli.send(:wp_id_arg, "#PROJ-123")
      assert_equal "PROJ-123", cli.send(:wp_id_arg, "proj-123")
    end

    def test_pr_rejects_targets_that_are_neither_wp_ids_nor_pr_urls
      cli = CLI.new(nil)
      [[],                                                     # no targets
       ["not-a-target"],                                        # neither form
       ["https://github.com/opf/openproject/issues/5"],         # not a PR URL
       ["59942", "garbage"]].each do |targets|                  # one bad target spoils the call
        assert_raises(Chomper::FatalError) { capture_io { cli.send(:pr, targets) } }
      end
    end

    # --- help and dispatch ------------------------------------------------

    # Enough context for the paths that never reach the network. load_config!
    # raises unless `configured`, so a test can prove a command took the runner
    # path (which needs config) rather than the help path.
    CtxDouble = Struct.new(:pd_parent_type, :pd_child_type, :log_file, :configured, keyword_init: true) do
      def load_config!
        raise Chomper::FatalError, "Config not found" unless configured
      end
    end

    def ctx_double(**over)
      CtxDouble.new(pd_parent_type: "FEATURE", pd_child_type: "IMPLEMENTATION", **over)
    end

    def test_a_help_flag_is_honoured_after_the_command_too
      # `./chomper wp ship --help` would otherwise be parsed as a work-package id
      # and die on the id validator.
      %w[--help -h].each do |flag|
        out, = capture_io { CLI.new(ctx_double).run(["wp", "ship", flag]) }
        assert_includes out, "Usage: ./chomper wp <command>"
      end
      out, = capture_io { CLI.new(ctx_double).run(["status", "--help"]) }
      assert_includes out, "Usage: ./chomper <command>"
    end

    def test_the_agent_group_lists_its_commands_and_triggers
      out, = capture_io { CLI.new(ctx_double).run(["agent", "--help"]) }
      assert_includes out, "Usage: ./chomper agent [op | gh]"
      assert_includes out, "./chomper agent op"
      assert_includes out, "Triggers", "the commands are useless without what fires them"
    end

    def test_an_unknown_agent_subcommand_lists_the_group
      cli = CLI.new(ctx_double)
      out, err = capture_io { assert_raises(Chomper::FatalError) { cli.run(["agent", "both"]) } }
      assert_includes err, "unknown agent subcommand \"both\""
      assert_includes out, "Usage: ./chomper agent [op | gh]"
    end

    def test_the_pre_group_agent_names_still_run
      # Unlike the moved wp verbs, breaking these means a stopped agent — a
      # service unit or a shell history calls them. They must reach the runner
      # path (which fails here only because ctx_double has no config).
      ["op-agent", "gh-agent", %w[agent op], %w[agent gh]].each do |argv|
        cli = CLI.new(ctx_double)
        out, err = capture_io do
          error = assert_raises(Chomper::FatalError) { cli.run(Array(argv)) }
          assert_match(/Config not found/, error.message, "#{Array(argv).join(" ")} reached the runner")
        end
        refute_includes err, "Unknown argument"
        refute_includes out, "Usage:"
      end
    end

    def test_a_bare_wp_is_a_help_request_and_needs_no_config
      out, = capture_io { CLI.new(ctx_double).run(["wp"]) }
      assert_includes out, "Usage: ./chomper wp <command>"
      assert_includes out, "./chomper wp ship <id>..."
    end

    def test_an_unknown_wp_subcommand_lists_the_group
      cli = CLI.new(ctx_double)
      out, err = capture_io { assert_raises(Chomper::FatalError) { cli.run(["wp", "bogus"]) } }
      assert_includes err, "unknown wp subcommand \"bogus\""
      assert_includes out, "Usage: ./chomper wp <command>"
    end

    def test_the_top_level_help_is_a_map_and_leaves_detail_to_the_groups
      # It ran to 114 lines by inlining both groups plus the env and state docs.
      ui = UI.new(ctx_double)
      out, = capture_io { ui.usage }
      assert_operator out.lines.length, :<, 30, "the top-level help is a one-screen map"
      assert_includes out, "./chomper agent"
      assert_includes out, "./chomper wp <command>"
      assert_includes out, "./chomper pd <command>"
      refute_includes out, "op | gh", "one plain agent line; `agent --help` has the split"
      refute_includes out, "./chomper agent op", "the agent group lists its own commands"
      assert_includes out, "Triggers", "what agent mode acts on stays on the front page"
      refute_includes out, "./chomper wp ship <id>...", "the wp group lists its own commands"
      refute_includes out, "./chomper pd propose", "the pd group lists its own commands"
    end

    def test_pd_help_shows_the_pipeline_commands_not_the_top_level_ones
      out, = capture_io { CLI.new(ctx_double).run(["pd", "--help"]) }
      assert_includes out, "Usage: ./chomper pd <command>"
      refute_includes out, "Agent mode"
    end

    def test_a_bare_pd_is_a_help_request_and_needs_no_config
      # It must not fail with "Config not found" at someone asking what pd does.
      out, = capture_io { CLI.new(ctx_double).run(["pd"]) }
      assert_includes out, "Usage: ./chomper pd <command>"
      assert_includes out, "./chomper pd generate-wp <change-id>", "every implemented stage is listed"
    end

    def test_a_chat_message_may_contain_a_flag_without_becoming_a_help_request
      # chat's tail is free text, so --help in it belongs to the message.
      cli = CLI.new(ctx_double)
      out, = capture_io do
        assert_raises(Chomper::FatalError) { cli.run(["chat", "what does --help do?"]) }
      end
      refute_includes out, "Usage: ./chomper <command>"
    end

    def test_each_group_help_renders_its_one_command_list
      # Each list is written once (UI#wp_commands / UI#pd_commands) — the pd copy
      # used to be duplicated in PD::Runner and had drifted out of date.
      ui = UI.new(ctx_double)
      { ui.wp_commands => -> { CLI.new(ctx_double).run(["wp"]) },
        ui.pd_commands => -> { CLI.new(ctx_double).run(["pd"]) } }.each do |commands, show|
        out, = capture_io { show.call }
        commands.lines.map(&:strip).reject(&:empty?).each { |line| assert_includes out, line }
      end
    end

    def test_every_command_stamps_one_log_header_in_the_shared_format
      Dir.mktmpdir do |dir|
        log = Pathname(dir) / "chomp.log"
        ctx = ctx_double(log_file: log, configured: true)
        CLI.new(ctx).send(:session, "wp pr", ["#42"]) { nil }
        assert_match(/\A\n=== wp pr #42 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} ===\n\z/, log.read)
      end
    end

    def test_wp_id_pattern_validates_both_id_forms
      assert_match Helpers::WP_ID_PATTERN, "59942"
      assert_match Helpers::WP_ID_PATTERN, "PROJ-123"
      assert_match Helpers::WP_ID_PATTERN, "A1_B-7"
      refute_match Helpers::WP_ID_PATTERN, "proj-123", "route constraint is uppercase-only"
      refute_match Helpers::WP_ID_PATTERN, "PROJ-"
      refute_match Helpers::WP_ID_PATTERN, "123-PROJ"
      refute_match Helpers::WP_ID_PATTERN, "../escape"
      refute_match Helpers::WP_ID_PATTERN, ""
    end
  end
end
