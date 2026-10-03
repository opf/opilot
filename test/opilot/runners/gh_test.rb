require_relative "../../test_helper"
require "tmpdir"

module OPilot
  class GhRunnerTest < Minitest::Test
    include TestFixtures

    FakeGitHub = Struct.new(:prs) do
      def open_prs = prs
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = build_ctx(@tmpdir, host: "test.host", contributor_token: "ghtok")
      @pr_dir = @ctx.state_dir / "work_packages" / "test.host" / "42" / "repos" / "openproject"
      @pr_dir.mkpath
      (@pr_dir / "pr_url.txt").write("https://github.com/old-name/r/pull/7\n")
      (@pr_dir / "pr.json").write(JSON.generate("url" => "https://github.com/new-name/r/pull/7"))
    end

    def entry(url, ci: nil)
      { "url" => url, "updated_at" => "2026-06-18T18:00:00Z", "head_sha" => "abc", "ci" => ci }
    end

    def run_gh(prs, *args)
      capture_io { Runners::Gh.new(@ctx, github: FakeGitHub.new(prs)).run(args) }
    end

    def test_pr_list_prints_json_with_the_tracking_dir
      out, err = run_gh([entry("https://github.com/new-name/r/pull/7", ci: :failed),
                         entry("https://github.com/o/r/pull/9")], "pr", "list")
      rows = JSON.parse(out)
      assert_equal "work_packages/test.host/42/repos/openproject", rows[0]["tracked"],
                   "matched by pr.json's URL after a rename"
      assert_equal ["new-name/r", 7, "failed"], rows[0].values_at("repo", "number", "ci")
      assert_nil rows[1]["tracked"]
      assert_empty err
    end

    def test_a_failed_query_is_an_error_not_an_empty_list
      out, err = capture_io do
        assert_raises(OPilot::FatalError) { Runners::Gh.new(@ctx, github: FakeGitHub.new(nil)).run(%w[pr list]) }
      end
      assert_empty out
      assert_match(/open-PR query failed/, err)
    end

    def test_an_unknown_action_names_the_allowed_ones
      _, err = capture_io do
        assert_raises(OPilot::FatalError) { Runners::Gh.new(@ctx, github: FakeGitHub.new([])).run(%w[pr merge]) }
      end
      assert_match(/unknown pr action "merge"/, err)
      assert_match(/Expected one of: list/, err)
    end
  end
end
