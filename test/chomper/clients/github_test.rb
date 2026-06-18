require_relative "../../test_helper"

module Chomper
  module Clients
    class GitHubTest < Minitest::Test
      def test_protected_branch_matches_dev_and_release
        assert GitHub.protected_branch?("dev")
        assert GitHub.protected_branch?("release")
        assert GitHub.protected_branch?("release/13.0")
        assert GitHub.protected_branch?("release-candidate")
      end

      def test_protected_branch_allows_fix_branches
        refute GitHub.protected_branch?("bug/42-fix-thing")
        refute GitHub.protected_branch?("develop")
        refute GitHub.protected_branch?("feature/release-notes")
      end

      def test_push_branch_refuses_protected_branch_without_invoking_git
        gh = GitHub.new("token")
        # Fail loudly if the guard lets us reach the actual push.
        gh.define_singleton_method(:system) { |*| flunk("git push must not run for a protected branch") }

        err = assert_raises(RuntimeError) do
          gh.push_branch("owner/repo", branch: "dev", worktree_path: Pathname("/tmp"))
        end
        assert_match(/protected branch/, err.message)
      end
    end
  end
end
