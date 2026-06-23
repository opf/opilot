require_relative "../test_helper"

module Chomper
  class RepoTest < Minitest::Test
    def setup
      @tmpdir    = Pathname(Dir.mktmpdir)
      @state_dir = @tmpdir / ".chomper"
      @state_dir.mkpath
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def write_repos(doc)
      (@tmpdir / "repos.json").write(JSON.generate(doc))
    end

    def build
      Registry.build(script_dir: @tmpdir, state_dir: @state_dir)
    end

    def test_loads_repos_and_resolves_paths
      write_repos(
        "summary" => "route here",
        "repos" => [
          { "name" => "openproject", "upstream" => "opf/openproject", "base" => "dev", "shared_repo_path" => "../openproject" },
          { "name" => "ckeditor", "upstream" => "opf/commonmark-ckeditor-build", "base" => "main", "shared_repo_path" => false }
        ]
      )
      reg = build
      assert_equal "route here", reg.summary
      assert_equal %w[openproject ckeditor], reg.all.map(&:name)

      op = reg["openproject"]
      assert_equal "dev", op.base
      assert_equal @state_dir / "repos" / "openproject", op.worktree_host
      assert_equal "/repos/openproject", op.worktree_container
      assert_equal (@tmpdir / "../openproject").expand_path, op.shared_repo_path
      assert op.linked?

      ck = reg["ckeditor"]
      assert_nil ck.shared_repo_path
      refute ck.linked?, "shared_repo_path:false means a standalone clone"
    end

    def test_default_is_first_entry
      write_repos("repos" => [
        { "name" => "a", "upstream" => "opf/a" },
        { "name" => "b", "upstream" => "opf/b" }
      ])
      assert_equal "a", build.default.name
    end

    def test_base_defaults_to_main_when_omitted
      write_repos("repos" => [{ "name" => "a", "upstream" => "opf/a" }])
      assert_equal "main", build["a"].base
    end

    def test_by_upstream_is_case_insensitive_and_falls_back_to_default
      write_repos("repos" => [
        { "name" => "op", "upstream" => "opf/openproject", "base" => "dev" },
        { "name" => "ck", "upstream" => "opf/commonmark-ckeditor-build" }
      ])
      reg = build
      assert_equal "ck", reg.by_upstream("OPF/commonmark-ckeditor-build").name
      assert_equal "op", reg.by_upstream("someone/unknown").name, "unknown upstream → default"
    end

    def test_protected_bases_collects_every_base
      write_repos("repos" => [
        { "name" => "op", "upstream" => "opf/openproject", "base" => "dev" },
        { "name" => "ck", "upstream" => "opf/ck", "base" => "main" }
      ])
      assert_equal Set["dev", "main"], build.protected_bases
    end

    def test_fallback_to_op_repo_path_when_no_repos_json
      reg = Registry.build(script_dir: @tmpdir, state_dir: @state_dir, op_repo_path: "/some/op")
      assert_equal 1, reg.all.length
      op = reg.default
      assert_equal "openproject", op.name
      assert_equal "dev", op.base
      assert_equal "opf/openproject", op.upstream
      assert_equal Pathname("/some/op"), op.shared_repo_path
    end

    def test_rejects_duplicate_names
      write_repos("repos" => [
        { "name" => "x", "upstream" => "opf/x" },
        { "name" => "x", "upstream" => "opf/y" }
      ])
      assert_raises(Registry::Error) { build }
    end

    def test_rejects_entry_without_upstream
      write_repos("repos" => [{ "name" => "x" }])
      assert_raises(Registry::Error) { build }
    end
  end
end
