require_relative "../test_helper"

module OPilot
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

    def test_refresh_rejects_targets_that_are_neither_wp_ids_nor_pr_urls
      cli = CLI.new(nil)
      [[],                                                     # no targets
       ["not-a-target"],                                        # neither form
       ["https://github.com/opf/openproject/issues/5"],         # not a PR URL
       ["59942", "garbage"]].each do |targets|                  # one bad target spoils the call
        assert_raises(OPilot::FatalError) { capture_io { cli.send(:refresh, targets) } }
      end
    end

    # --- help and dispatch ------------------------------------------------

    # Enough context for the paths that never reach the network. load_config!
    # raises unless `configured`, so a test can prove a command took the runner
    # path (which needs config) rather than the help path.
    CtxDouble = Struct.new(:pd_parent_type, :pd_child_type, :log_file, :configured,
                           :op_url, :token, keyword_init: true) do
      def load_config!
        raise OPilot::FatalError, "Config not found" unless configured
      end

      # `op` loads only the OpenProject half, so it must be defined here too —
      # attributes alone would make an op dispatch test fail with NoMethodError
      # instead of proving it reached the runner.
      def load_openproject_config!
        raise OPilot::FatalError, "Config not found" unless configured
      end
    end

    def ctx_double(**over)
      CtxDouble.new(pd_parent_type: "FEATURE", pd_child_type: "IMPLEMENTATION", **over)
    end

    def test_a_help_flag_is_honoured_after_the_command_too
      # `./opilot dev build --help` would otherwise be parsed as a work-package id
      # and die on the id validator.
      %w[--help -h].each do |flag|
        out, = capture_io { CLI.new(ctx_double).run(["dev", "build", flag]) }
        assert_includes out, "Usage: ./opilot dev <command>"
      end
      out, = capture_io { CLI.new(ctx_double).run(["reset", "--help"]) }
      assert_includes out, "Usage: ./opilot <command>"
    end

    def test_the_agent_group_lists_its_commands_and_triggers
      out, = capture_io { CLI.new(ctx_double).run(["agent", "--help"]) }
      assert_includes out, "Usage: ./opilot agent [op | gh]"
      assert_includes out, "./opilot agent op"
      assert_includes out, "Triggers", "the commands are useless without what fires them"
    end

    def test_an_unknown_agent_subcommand_lists_the_group
      cli = CLI.new(ctx_double)
      out, err = capture_io { assert_raises(OPilot::FatalError) { cli.run(["agent", "both"]) } }
      assert_includes err, "unknown agent subcommand \"both\""
      assert_includes out, "Usage: ./opilot agent [op | gh]"
    end

    def test_the_pre_group_agent_names_still_run
      # Unlike the renamed dev verbs, breaking these means a stopped agent — a
      # service unit or a shell history calls them. They must reach the runner
      # path (which fails here only because ctx_double has no config).
      ["op-agent", "gh-agent", %w[agent op], %w[agent gh]].each do |argv|
        cli = CLI.new(ctx_double)
        out, err = capture_io do
          error = assert_raises(OPilot::FatalError) { cli.run(Array(argv)) }
          assert_match(/Config not found/, error.message, "#{Array(argv).join(" ")} reached the runner")
        end
        refute_includes err, "Unknown argument"
        refute_includes out, "Usage:"
      end
    end

    def test_a_bare_dev_is_a_help_request_and_needs_no_config
      out, = capture_io { CLI.new(ctx_double).run(["dev"]) }
      assert_includes out, "Usage: ./opilot dev <command>"
      assert_includes out, "./opilot dev build <id>..."
    end

    def test_an_unknown_dev_subcommand_lists_the_group
      cli = CLI.new(ctx_double)
      out, err = capture_io { assert_raises(OPilot::FatalError) { cli.run(["dev", "bogus"]) } }
      assert_includes err, "unknown dev subcommand \"bogus\""
      assert_includes out, "Usage: ./opilot dev <command>"
    end

    def test_build_and_fix_both_reach_the_publishing_path
      # The same pair `@opilot` takes on a work package, so one operation has one
      # name wherever it is typed.
      %w[build fix].each do |verb|
        cli = CLI.new(ctx_double)
        capture_io do
          error = assert_raises(OPilot::FatalError) { cli.run(["dev", verb, "42"]) }
          assert_match(/Config not found/, error.message, "`dev #{verb}` reached the runner")
        end
      end
    end

    def test_a_bare_op_is_a_help_request_and_needs_no_config
      out, = capture_io { CLI.new(ctx_double).run(["op"]) }
      assert_includes out, "Usage: ./opilot op <resource> <action>"
      assert_includes out, "./opilot op wp get <id>"
    end

    def test_op_help_answers_for_its_own_group
      out, = capture_io { CLI.new(ctx_double).run(["op", "wp", "get", "--help"]) }
      assert_includes out, "Usage: ./opilot op <resource> <action>"
      refute_includes out, "Agent mode", "the group answers, not the whole screen"
    end

    def test_op_reaches_the_runner_rather_than_the_unknown_command_arm
      cli = CLI.new(ctx_double)
      out, err = capture_io do
        error = assert_raises(OPilot::FatalError) { cli.run(["op", "wp", "get", "42"]) }
        assert_match(/Config not found/, error.message, "it got as far as loading config")
      end
      refute_includes err, "Unknown argument"
      refute_includes out, "Usage:"
    end

    def test_op_never_stamps_a_log_header
      # Its stdout is JSON for a pipe, and an inspection read is not part of
      # opilot's audit trail — so unlike every other command it skips #session.
      #
      # `configured: true` is what makes this test mean anything: #session writes
      # its header only AFTER load_config! succeeds, so an unconfigured double
      # would produce no header whichever path `op` took.
      Dir.mktmpdir do |dir|
        log = Pathname(dir) / "chomp.log"
        ctx = ctx_double(log_file: log, configured: true, op_url: "https://op.test", token: "tok")
        stub_request(:get, "https://op.test/api/v3/users/me").to_return(status: 200, body: "{}")

        capture_io { CLI.new(ctx).run(["op", "me"]) }

        refute log.exist?, "the command ran to completion and still stamped no header"
      end
    end

    def test_the_top_level_help_is_a_map_and_leaves_detail_to_the_groups
      # It ran to 114 lines by inlining both groups plus the env and state docs.
      ui = UI.new(ctx_double)
      out, = capture_io { ui.usage }
      assert_operator out.lines.length, :<, 30, "the top-level help is a one-screen map"
      assert_includes out, "./opilot agent"
      assert_includes out, "./opilot dev <command>"
      assert_includes out, "./opilot pd <command>"
      refute_includes out, "op | gh", "one plain agent line; `agent --help` has the split"
      refute_includes out, "./opilot agent op", "the agent group lists its own commands"
      assert_includes out, "Triggers", "what agent mode acts on stays on the front page"
      refute_includes out, "./opilot dev build <id>...", "the dev group lists its own commands"
      refute_includes out, "./opilot pd propose", "the pd group lists its own commands"
    end

    def test_pd_help_shows_the_pipeline_commands_not_the_top_level_ones
      out, = capture_io { CLI.new(ctx_double).run(["pd", "--help"]) }
      assert_includes out, "Usage: ./opilot pd <command>"
      refute_includes out, "Agent mode"
    end

    def test_a_bare_pd_is_a_help_request_and_needs_no_config
      # It must not fail with "Config not found" at someone asking what pd does.
      out, = capture_io { CLI.new(ctx_double).run(["pd"]) }
      assert_includes out, "Usage: ./opilot pd <command>"
      assert_includes out, "./opilot pd generate-wp <change-id>", "every implemented stage is listed"
    end

    def test_a_chat_message_may_contain_a_flag_without_becoming_a_help_request
      # chat's tail is free text, so --help in it belongs to the message.
      cli = CLI.new(ctx_double)
      out, = capture_io do
        assert_raises(OPilot::FatalError) { cli.run(["chat", "what does --help do?"]) }
      end
      refute_includes out, "Usage: ./opilot <command>"
    end

    def test_each_group_help_renders_its_one_command_list
      # Each list is written once (UI#dev_commands / UI#pd_commands) — the pd copy
      # used to be duplicated in PD::Runner and had drifted out of date.
      ui = UI.new(ctx_double)
      { ui.dev_commands => -> { CLI.new(ctx_double).run(["dev"]) },
        ui.pd_commands => -> { CLI.new(ctx_double).run(["pd"]) } }.each do |commands, show|
        out, = capture_io { show.call }
        commands.lines.map(&:strip).reject(&:empty?).each { |line| assert_includes out, line }
      end
    end

    def test_every_command_stamps_one_log_header_in_the_shared_format
      Dir.mktmpdir do |dir|
        log = Pathname(dir) / "chomp.log"
        ctx = ctx_double(log_file: log, configured: true)
        CLI.new(ctx).send(:session, "dev refresh", ["#42"]) { nil }
        assert_match(/\A\n=== dev refresh #42 \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2} ===\n\z/, log.read)
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
