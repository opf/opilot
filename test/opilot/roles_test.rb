require_relative "../test_helper"
require "tmpdir"

module OPilot
  class RolesTest < Minitest::Test
    ROOT = Pathname(__dir__) / "../.."

    class Caller
      include Helpers
      attr_reader :calls

      def initialize(ctx)
        @ctx = ctx
        @calls = []
        calls = @calls
        @harness = Object.new
        @harness.define_singleton_method(:run) { |prompt, **opts| calls << opts.merge(prompt: prompt); "ok" }
        @harness.define_singleton_method(:capture) { |prompt, **opts| calls << opts.merge(prompt: prompt); "ok" }
      end
    end

    def ctx(op: false, gh: false)
      Struct.new(:op_mcp?, :gh_mcp?).new(op, gh)
    end

    def server_grants
      (ROOT / "server.js").read[/ALLOWED_TOOL_GRANTS = new Set\(\[(.*?)\]\)/m, 1].scan(/'([^']+)'/).flatten
    end

    def test_every_role_resolves_to_a_grant_server_js_allows
      grants = server_grants
      refute_empty grants
      Harness::ROLES.each_value do |p|
        [[false, false], [true, false], [false, true], [true, true]].each do |op, gh|
          assert_includes grants, p.tools(ctx(op: op, gh: gh)), "#{p.name} op=#{op} gh=#{gh}"
        end
      end
    end

    def test_mcp_tools_follow_the_flags_only_for_mcp_roles
      assert_equal "#{Harness::TOOLS_READ},op_query", Harness.role(:planner).tools(ctx(op: true))
      assert_equal Harness::TOOLS_READ, Harness.role(:wp_writer).tools(ctx(op: true, gh: true))
    end

    def test_llm_passes_the_role_tools_and_model
      c = Caller.new(ctx)
      c.send(:llm, :scribe, "hi")
      assert_equal({ role: :scribe, tools: Harness::TOOLS_READ, model: Harness::MODEL_LIGHT, session_file: nil, prompt: "hi" },
                   c.calls.last)
    end

    def test_llm_with_outfile_captures
      c = Caller.new(ctx)
      c.send(:llm, :planner, "plan", outfile: "/tmp/x", session_file: "s")
      assert_equal "/tmp/x", c.calls.last[:outfile]
    end

    def test_a_stateless_role_refuses_a_session
      err = assert_raises(ArgumentError) { Caller.new(ctx).send(:llm, :auditor, "x", session_file: "s") }
      assert_match(/stateless/, err.message)
    end

    # The table the role files replaced, pinned so a role file edit is a deliberate test edit.
    EXPECTED = {
      planner:      [Harness::TOOLS_READ, true,  Harness::MODEL_HEAVY, :session],
      advisor:      [Harness::TOOLS_READ, true,  Harness::MODEL_HEAVY, :session],
      wp_writer:    [Harness::TOOLS_READ, false, Harness::MODEL_HEAVY, :session],
      triager:      [Harness::TOOLS_READ, true,  Harness::MODEL_HEAVY, :none],
      auditor:      [Harness::TOOLS_READ, true,  Harness::MODEL_HEAVY, :none],
      implementer:  [Harness::TOOLS_IMPL, false, Harness::MODEL_HEAVY, :session],
      spec_writer:  [Harness::TOOLS_IMPL, false, Harness::MODEL_HEAVY, :session],
      pr_author:    [Harness::TOOLS_IMPL, true,  Harness::MODEL_HEAVY, :session],
      pr_refresher: [Harness::TOOLS_IMPL, false, Harness::MODEL_HEAVY, :session],
      pr_advisor:   [Harness::TOOLS_READ, false, Harness::MODEL_HEAVY, :session],
      scribe:       [Harness::TOOLS_READ, false, Harness::MODEL_LIGHT, :none],
    }.freeze

    def test_role_files_hold_the_expected_tuples
      actual = Harness::ROLES.transform_values { |r| [r.base, r.mcp, r.model, r.memory] }
      assert_equal EXPECTED, actual
      Harness::ROLES.each_value do |r|
        refute_empty r.charter, r.name
        refute_match(/<!--|Used by/, r.charter, r.name)
      end
    end

    def test_every_call_site_names_a_known_role
      used = Dir[ROOT / "lib/**/*.rb"].flat_map { |f| File.read(f).scan(/\bllm\(\s*:(\w+)/).flatten }
      refute_empty used
      assert_empty used.map(&:to_sym).uniq - Harness::ROLES.keys
    end

    def write_role(dir, text)
      path = Pathname(dir) / "x.yml"
      path.write(text)
      path
    end

    def test_a_bad_role_file_fails_to_load
      Dir.mktmpdir do |dir|
        good = "tools: read\nmcp: false\nmodel: heavy\nmemory: none\ncharter: |\n  Does x.\n"
        role = Harness.load_role(write_role(dir, good))
        assert_equal [:x, "Does x."], [role.name, role.charter]
        [good.sub("read", "admin"),                            # unknown grant
         good.sub("mcp: false\n", ""),                         # missing key
         good.sub("memory: none", "memory: none\nextra: 1"),  # unknown key
         good.sub("charter: |\n  Does x.\n", ""),           # no charter
         good.sub("  Does x.", ""),                          # empty charter
         "just text\n"].each do |bad|
          assert_raises(ArgumentError, bad) { Harness.load_role(write_role(dir, bad)) }
        end
      end
    end

    def role_modules
      Prompts.constants.map { |c| Prompts.const_get(c) }
             .select { |m| m.is_a?(Module) && m.const_defined?(:ROLE, false) }
    end

    def test_every_role_has_one_prompt_module
      assert_equal Harness::ROLES.keys.sort, role_modules.map { |m| m::ROLE }.sort
    end

    def test_a_prompt_sent_under_another_role_raises
      prompt = Prompts::Scribe.commit_subject(diff: "d")
      assert_equal :scribe, prompt.role
      c = Caller.new(ctx)
      c.send(:llm, :scribe, prompt)
      err = assert_raises(ArgumentError) { c.send(:llm, :planner, prompt, session_file: "s") }
      assert_match(/scribe prompt sent as planner/, err.message)
      c.send(:llm, :planner, "a bare follow-up message", session_file: "s")
    end

    def test_unknown_role_fails
      assert_raises(KeyError) { Harness.role(:nobody) }
    end

    # Keeps the role table the one place a grant or model is chosen.
    def test_no_call_site_bypasses_llm
      files = Dir[ROOT / "lib/**/*.rb"]
      assert_operator files.size, :>, 20
      direct = File.readlines(ROOT / "lib/opilot/helpers.rb").grep(/@harness\.(run|capture)\b/)
      assert_equal 1, direct.size, "helpers.rb calls the harness only from #llm"
      offenders = files.flat_map do |f|
        next [] if f.end_with?("/helpers.rb", "/harness.rb", "/roles.rb")
        File.readlines(f).each_with_index.filter_map do |line, i|
          "#{f}:#{i + 1}" if line.match?(/@harness\.(run|capture)\b|Harness::TOOLS_/)
        end
      end
      assert_empty offenders
    end
  end
end
