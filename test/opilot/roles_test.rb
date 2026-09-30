require_relative "../test_helper"

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

    def test_every_persona_resolves_to_a_grant_server_js_allows
      grants = server_grants
      refute_empty grants
      Harness::ROLES.each_value do |p|
        [[false, false], [true, false], [false, true], [true, true]].each do |op, gh|
          assert_includes grants, p.tools(ctx(op: op, gh: gh)), "#{p.name} op=#{op} gh=#{gh}"
        end
      end
    end

    def test_mcp_tools_follow_the_flags_only_for_mcp_personas
      assert_equal "#{Harness::TOOLS_READ},op_query", Harness.role(:planner).tools(ctx(op: true))
      assert_equal Harness::TOOLS_READ, Harness.role(:wp_writer).tools(ctx(op: true, gh: true))
    end

    def test_llm_passes_the_personas_tools_and_model
      c = Caller.new(ctx)
      c.send(:llm, :scribe, "hi")
      assert_equal({ tools: Harness::TOOLS_READ, model: Harness::MODEL_LIGHT, session_file: nil, prompt: "hi" },
                   c.calls.last)
    end

    def test_llm_with_outfile_captures
      c = Caller.new(ctx)
      c.send(:llm, :planner, "plan", outfile: "/tmp/x", session_file: "s")
      assert_equal "/tmp/x", c.calls.last[:outfile]
    end

    def test_a_stateless_persona_refuses_a_session
      err = assert_raises(ArgumentError) { Caller.new(ctx).send(:llm, :auditor, "x", session_file: "s") }
      assert_match(/stateless/, err.message)
    end

    def test_unknown_persona_fails
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
