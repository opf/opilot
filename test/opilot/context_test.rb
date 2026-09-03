require_relative "../test_helper"

module OPilot
  class ContextTest < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = Context.build(@tmpdir)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    # ── the local-model guard ───────────────────────────────────────────────
    #
    # `./opilot appsignal` sends production error data to the model, so this
    # decides whether that is allowed. inference-gw answers with the address it pinned
    # at boot; the runner never resolves the URL itself.

    INFERENCE_GW = "http://inference-gw.test:47292".freeze

    def with_inference_gw_address(address)
      body = address.nil? ? "{}" : JSON.generate("host" => "h", "address" => address)
      stub_request(:get, "#{INFERENCE_GW}/upstream").to_return(status: 200, body: body)
      with_env("OPILOT_INFERENCE_GW_URL" => INFERENCE_GW, "OPILOT_GW_TOKEN" => "gw") { yield Context.build(@tmpdir) }
    end

    # Docker Desktop's host gateway is in 0.0.0.0/8 — reserved, but NOT matched
    # by IPAddr#private?. Refusing it would refuse Ollama on the developer's own
    # Mac, which is the setup the command exists for. Tailscale's 100.64/10 is
    # here for the same reason.
    def test_reserved_and_private_addresses_are_accepted
      %w[0.250.250.254 192.168.65.254 127.0.0.1 10.0.0.5 100.101.1.5 ::1].each do |address|
        with_inference_gw_address(address) { |ctx| assert ctx.inference_privacy.first, "#{address} is not a third party" }
      end
    end

    def test_public_addresses_are_refused
      # 104.18/172.67 are Cloudflare, which is what openrouter.ai resolves to.
      %w[104.18.2.1 172.67.1.1 8.8.8.8].each do |address|
        with_inference_gw_address(address) { |ctx| refute ctx.inference_privacy.first, "#{address} is a third party" }
      end
    end

    # It fails CLOSED: the caller is about to send user data somewhere.
    def test_it_fails_closed_when_inference_gw_cannot_answer
      with_inference_gw_address(nil) { |ctx| refute ctx.inference_privacy.first, "no address means no" }

      stub_request(:get, "#{INFERENCE_GW}/upstream").to_raise(SocketError.new("down"))
      with_env("OPILOT_INFERENCE_GW_URL" => INFERENCE_GW, "OPILOT_GW_TOKEN" => "gw") do
        refute Context.build(@tmpdir).inference_privacy.first, "an unreachable inference-gw means no"
      end
    end

    # No gateway token means opilot is not running through ./opilot, so there is
    # nothing to ask — and nothing to assume.
    def test_it_fails_closed_without_a_gateway_token
      with_env("OPILOT_INFERENCE_GW_URL" => INFERENCE_GW, "OPILOT_GW_TOKEN" => nil) do
        refute Context.build(@tmpdir).inference_privacy.first
      end
    end

    def test_op_url_drops_a_trailing_slash
      # Every consumer appends its own path, so a trailing slash in .env would
      # produce "https://host//api/v3/…" and "https://host//documents/118".
      with_env("OPENPROJECT_URL" => "https://op.example.com/") do
        assert_equal "https://op.example.com", Context.build(@tmpdir).op_url
      end
      with_env("OPENPROJECT_URL" => "https://op.example.com///") do
        assert_equal "https://op.example.com", Context.build(@tmpdir).op_url
      end
      with_env("OPENPROJECT_URL" => "https://op.example.com") do
        assert_equal "https://op.example.com", Context.build(@tmpdir).op_url
      end
      with_env("OPENPROJECT_URL" => nil) { assert_nil Context.build(@tmpdir).op_url }
    end

    def test_script_dir_set_from_argument
      assert_equal Pathname(@tmpdir), @ctx.script_dir
    end

    def test_state_dir_is_dotopilot_under_script_dir
      assert_equal Pathname(@tmpdir) / ".opilot", @ctx.state_dir
    end

    def test_state_container_is_fixed
      assert_equal "/state", @ctx.state_container
    end

    def test_default_repo_comes_from_the_registry
      # With no repos.json in the tmpdir, the registry falls back to a single
      # openproject entry; its checkout lives under .opilot/repos/<name>.
      assert_equal "openproject", @ctx.default_repo.name
      assert_equal @ctx.state_dir / "repos" / "openproject", @ctx.default_repo.worktree_host
      assert_equal "/repos/openproject", @ctx.default_repo.worktree_container
    end

    def test_load_config_raises_when_env_vars_missing
      saved = %w[OPENPROJECT_URL OPENPROJECT_TOKEN].map { |k| [k, ENV.delete(k)] }
      ctx = Context.build(@tmpdir)
      assert_raises(OPilot::FatalError) { ctx.load_config! }
    ensure
      saved.each { |k, v| ENV[k] = v if v }
    end

    def test_op_host_is_a_filesystem_safe_segment_from_the_url
      with_env("OPENPROJECT_URL" => "https://Community.OpenProject.org") do
        assert_equal "community.openproject.org", Context.build(@tmpdir).op_host
      end
      # A non-default port is folded in so two local instances don't collide.
      with_env("OPENPROJECT_URL" => "http://localhost:8080") do
        assert_equal "localhost_8080", Context.build(@tmpdir).op_host
      end
      # Standard ports are dropped; a blank URL falls back to a safe sentinel.
      with_env("OPENPROJECT_URL" => "https://op.example.com:443") do
        assert_equal "op.example.com", Context.build(@tmpdir).op_host
      end
      with_env("OPENPROJECT_URL" => nil) { assert_equal "unknown-host", Context.build(@tmpdir).op_host }
    end

    def test_the_contributor_token_comes_from_its_env_var
      with_env("GITHUB_CONTRIBUTOR_TOKEN" => "bot-tok") do
        assert_equal "bot-tok", Context.build(@tmpdir).contributor_token
      end
      with_env("GITHUB_CONTRIBUTOR_TOKEN" => nil) do
        assert_nil Context.build(@tmpdir).contributor_token
      end
    end

    def test_upstream_pr_tracking_is_off_unless_explicitly_enabled
      # The one gh-agent source that looks outside opilot's own PRs: it must
      # never turn itself on just because an agent is running.
      with_env("OPILOT_TRACK_UPSTREAM_PRS" => nil) do
        refute Context.build(@tmpdir).track_upstream_prs?
      end
      with_env("OPILOT_TRACK_UPSTREAM_PRS" => "") do
        refute Context.build(@tmpdir).track_upstream_prs?
      end
      %w[1 true yes on TRUE].each do |on|
        with_env("OPILOT_TRACK_UPSTREAM_PRS" => on) do
          assert Context.build(@tmpdir).track_upstream_prs?, "#{on.inspect} enables it"
        end
      end
      %w[0 false no off].each do |off|
        with_env("OPILOT_TRACK_UPSTREAM_PRS" => off) do
          refute Context.build(@tmpdir).track_upstream_prs?, "#{off.inspect} does not"
        end
      end
    end

    def test_op_mcp_defaults_on_and_is_turned_off_explicitly
      # Opposite polarity from track_upstream_prs? on purpose: an instance
      # with no Enterprise MCP server just answers "unavailable", so this
      # defaults ON rather than requiring every operator to opt in.
      with_env("OPILOT_OP_MCP" => nil) { assert Context.build(@tmpdir).op_mcp? }
      with_env("OPILOT_OP_MCP" => "") { assert Context.build(@tmpdir).op_mcp? }
      %w[1 true yes on TRUE].each do |on|
        with_env("OPILOT_OP_MCP" => on) do
          assert Context.build(@tmpdir).op_mcp?, "#{on.inspect} stays on"
        end
      end
      %w[0 false no off OFF].each do |off|
        with_env("OPILOT_OP_MCP" => off) do
          refute Context.build(@tmpdir).op_mcp?, "#{off.inspect} turns it off"
        end
      end
    end

    def test_gh_mcp_is_off_unless_explicitly_switched_on
      # The opposite default to op_mcp?, and deliberate: this one needs a GitHub
      # read token an operator has to create, so unset must mean off.
      with_env("OPILOT_GH_MCP" => nil)  { refute Context.build(@tmpdir).gh_mcp? }
      with_env("OPILOT_GH_MCP" => "")   { refute Context.build(@tmpdir).gh_mcp? }
      with_env("OPILOT_GH_MCP" => "0")  { refute Context.build(@tmpdir).gh_mcp? }
      with_env("OPILOT_GH_MCP" => "1")  { assert Context.build(@tmpdir).gh_mcp? }
      with_env("OPILOT_GH_MCP" => "true") { assert Context.build(@tmpdir).gh_mcp? }
    end

    def test_mcp_gw_url_is_nil_unless_set
      with_env("OPILOT_MCP_GW_URL" => nil) { assert_nil Context.build(@tmpdir).mcp_gw_url }
      with_env("OPILOT_MCP_GW_URL" => "  ") { assert_nil Context.build(@tmpdir).mcp_gw_url }
      with_env("OPILOT_MCP_GW_URL" => "http://mcp-gw:47293") do
        assert_equal "http://mcp-gw:47293", Context.build(@tmpdir).mcp_gw_url
      end
    end

    def test_a_blank_token_is_the_same_as_no_token
      # compose.yml passes the token as `TOKEN=${TOKEN:-}`, so inside the
      # container an unset token arrives as "" — which is TRUTHY, while every
      # consumer asks "is there a token?" as truthiness.
      with_env("GITHUB_CONTRIBUTOR_TOKEN" => "  ") do
        assert_nil Context.build(@tmpdir).contributor_token
      end
      with_env("GITHUB_CONTRIBUTOR_TOKEN" => " bot-tok ") do
        assert_equal "bot-tok", Context.build(@tmpdir).contributor_token, "and it is trimmed"
      end
    end

    def test_ci_max_attempts_defaults_to_five_and_is_floored_at_one
      with_env("OPILOT_CI_MAX_ATTEMPTS" => nil) { assert_equal 5, Context.build(@tmpdir).ci_max_attempts }
      with_env("OPILOT_CI_MAX_ATTEMPTS" => "3") { assert_equal 3, Context.build(@tmpdir).ci_max_attempts }
      with_env("OPILOT_CI_MAX_ATTEMPTS" => "0") { assert_equal 1, Context.build(@tmpdir).ci_max_attempts }
    end

    def test_ci_ignored_checks_defaults_to_saas_tests_and_is_overridable
      with_env("OPILOT_CI_IGNORE_CHECKS" => nil) { assert_equal ["saas tests"], Context.build(@tmpdir).ci_ignored_checks }
      with_env("OPILOT_CI_IGNORE_CHECKS" => "Foo, Bar") { assert_equal ["foo", "bar"], Context.build(@tmpdir).ci_ignored_checks }
      with_env("OPILOT_CI_IGNORE_CHECKS" => "") { assert_equal [], Context.build(@tmpdir).ci_ignored_checks }
    end

    private

    def with_env(vars)
      saved = vars.map { |k, _| [k, ENV[k]] }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end
end
