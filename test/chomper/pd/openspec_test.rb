require_relative "../../test_helper"
require "tmpdir"

module Chomper
  module PD
    class OpenSpecTest < Minitest::Test
      # Captures the argv Open3 would have run and plays back a scripted result,
      # so the wrapper's contract is tested without the CLI on PATH.
      Status = Struct.new(:success) do
        def success?
          success
        end
      end

      def setup
        @tmpdir = Pathname(Dir.mktmpdir)
        @calls  = []
      end

      def teardown
        FileUtils.rm_rf(@tmpdir)
      end

      # Swap Open3.capture3 for the duration of the block. Hand-rolled rather than
      # Minitest's #stub, which moved out of the core gem in Minitest 6.
      def swap_capture3(replacement)
        original = Open3.method(:capture3)
        redefine_capture3(replacement)
        yield
      ensure
        redefine_capture3(original)
      end

      def redefine_capture3(impl)
        warn_level = $VERBOSE
        $VERBOSE = nil # a deliberate redefinition; the warning is just noise here
        Open3.singleton_class.send(:define_method, :capture3, impl)
      ensure
        $VERBOSE = warn_level
      end

      def with_open3(out: "", err: "", success: true)
        calls = @calls
        swap_capture3(lambda { |*args, **opts|
          calls << { args: args, chdir: opts[:chdir] }
          [out, err, Status.new(success)]
        }) { yield Chomper::PD::OpenSpec.new(@tmpdir) }
      end

      def test_validate_asks_for_strict_json_and_runs_in_the_root
        with_open3(out: '{"items":[]}') { |os| os.validate("add-recurring-meetings") }
        call = @calls.first
        assert_equal "openspec", call[:args].first
        assert_includes call[:args], "validate"
        assert_includes call[:args], "add-recurring-meetings"
        assert_includes call[:args], "--strict"
        assert_includes call[:args], "--json"
        assert_includes call[:args], "--no-interactive"
        assert_equal @tmpdir.to_s, call[:chdir]
      end

      def test_validate_passes_an_argv_array_so_a_change_id_cannot_inject
        # change ids reach here from operator input; never through a shell.
        with_open3 { |os| os.validate("x; rm -rf /") }
        assert_includes @calls.first[:args], "x; rm -rf /"
        refute @calls.first[:args].any? { |a| a.include?("&&") }
      end

      def test_init_disables_tool_integration
        # `--tools none` is what keeps openspec init from writing an AGENTS.md
        # over the real one a product clone already has.
        with_open3 { |os| os.init! }
        assert_includes @calls.first[:args], "--tools"
        assert_includes @calls.first[:args], "none"
      end

      def test_result_reports_success_and_parses_json
        with_open3(out: '{"summary":{"totals":{"failed":0}}}') do |os|
          result = os.validate("c")
          assert result.ok?
          assert_equal 0, result.json.dig("summary", "totals", "failed")
        end
      end

      def test_result_json_is_nil_on_unparseable_output
        with_open3(out: "not json") { |os| assert_nil os.validate("c").json }
      end

      def test_message_prefers_stderr
        with_open3(out: "stdout text", err: "the real error", success: false) do |os|
          assert_equal "the real error", os.validate("c").message
        end
        with_open3(out: "stdout text", err: "  ") do |os|
          assert_equal "stdout text", os.validate("c").message
        end
      end

      def test_failures_extracts_per_item_issues_for_the_reprompt
        json = JSON.generate(
          "items" => [
            { "name" => "add-x", "passed" => false,
              "issues" => [{ "message" => "requirement 'Skip an occurrence' has no scenarios" }] },
            { "name" => "add-y", "passed" => true, "issues" => [] }
          ]
        )
        with_open3(out: json, success: false) do |os|
          text = Chomper::PD::OpenSpec.failures(os.validate("add-x"))
          assert_includes text, "add-x: requirement 'Skip an occurrence' has no scenarios"
          refute_includes text, "add-y"
        end
      end

      def test_failures_falls_back_to_raw_output_when_the_shape_is_unexpected
        # A CLI change must degrade to "show Claude the output", never to silence.
        with_open3(out: "totally different", err: "boom", success: false) do |os|
          assert_equal "boom", Chomper::PD::OpenSpec.failures(os.validate("c"))
        end
      end

      # --- artifact instructions -------------------------------------------

      def test_instructions_asks_the_cli_for_one_artifact_of_a_change
        with_open3(out: "<artifact/>") { |os| os.instructions("proposal", change_id: "add-x") }
        args = @calls.first[:args]
        assert_equal %w[openspec instructions proposal --change add-x], args
      end

      def test_instructions_for_all_covers_every_artifact_in_dependency_order
        text = with_open3(out: "<artifact>x</artifact>") do |os|
          os.instructions_for_all("add-x")
        end
        requested = @calls.map { |c| c[:args][2] } # ["openspec", "instructions", <artifact>, …]
        assert_equal %w[proposal specs design tasks], requested,
                     "proposal unlocks specs and design, so it has to come first"
        assert_equal 4, text.scan("<artifact>").length
      end

      def test_instructions_for_all_rewrites_paths_for_the_reader
        # The CLI resolves absolute paths against where IT ran (the runner); the
        # agent reading them sees the same files at /repos/<name>.
        out = "<output>\nWrite to: /host/clone/openspec/changes/add-x/proposal.md\n</output>"
        text = with_open3(out: out) do |os|
          os.instructions_for_all("add-x") { |c| c.gsub("/host/clone", "/repos/openproject") }
        end
        assert_includes text, "/repos/openproject/openspec/changes/add-x/proposal.md"
        refute_includes text, "/host/clone"
      end

      def test_unmet_dependency_warnings_are_dropped
        # Nothing exists yet in a single pass, so "Missing: proposal" is noise.
        out = <<~TEXT
          <artifact id="specs">
          <warning>
          This artifact has unmet dependencies.
          Missing: proposal
          </warning>
          <instruction>Write the deltas.</instruction>
          </artifact>
        TEXT
        text = with_open3(out: out) { |os| os.instructions_for_all("add-x") }
        refute_includes text, "unmet dependencies"
        refute_includes text, "<warning>"
        assert_includes text, "Write the deltas.", "the actual instruction survives"
      end

      def test_instructions_for_all_skips_artifacts_the_cli_could_not_produce
        text = with_open3(out: "nope", success: false) { |os| os.instructions_for_all("add-x") }
        assert_empty text, "a failed lookup yields nothing rather than garbage in the prompt"
      end

      def test_a_missing_cli_is_reported_as_a_failed_result_not_an_exception
        swap_capture3(->(*_a, **_o) { raise Errno::ENOENT, "openspec" }) do
          result = Chomper::PD::OpenSpec.new(@tmpdir).validate("c")
          refute result.ok?
          assert_match(/rebuild the runner image/, result.message)
        end
      end
    end
  end
end
