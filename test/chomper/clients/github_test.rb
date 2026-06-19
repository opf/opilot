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

      def test_author_identity_uses_the_bot_github_noreply_email
        stub_request(:get, "https://api.github.com/user").to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: JSON.generate("login" => "chomper-bot", "id" => 4242, "name" => "Chomper Bot")
        )
        name, email = GitHub.new("token").author_identity
        assert_equal "Chomper Bot", name
        assert_equal "4242+chomper-bot@users.noreply.github.com", email
      end

      def test_create_draft_pr_enables_maintainer_edits
        stub = stub_request(:post, "https://api.github.com/repos/opf/openproject/pulls")
               .with(body: hash_including("draft" => true, "maintainer_can_modify" => true))
               .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate("html_url" => "https://github.com/opf/openproject/pull/9"))

        url = GitHub.new("token").create_draft_pr(
          "opf/openproject", base: "dev", head: "chomper-bot:bug/42-x", title: "T", body: "B"
        )
        assert_equal "https://github.com/opf/openproject/pull/9", url
        assert_requested(stub)
      end

      def test_react_routes_issue_and_review_comments_to_their_endpoints
        issue  = stub_request(:post, "https://api.github.com/repos/o/r/issues/comments/11/reactions")
                 .with(body: hash_including("content" => "eyes")).to_return(status: 201, body: "{}")
        review = stub_request(:post, "https://api.github.com/repos/o/r/pulls/comments/22/reactions")
                 .with(body: hash_including("content" => "eyes")).to_return(status: 201, body: "{}")

        gh = GitHub.new("token")
        gh.react("o/r", 11, kind: :issue)
        gh.react("o/r", 22, kind: :review)

        assert_requested(issue)
        assert_requested(review)
      end

      def test_react_swallows_errors_so_it_never_blocks_handling
        stub_request(:post, "https://api.github.com/repos/o/r/issues/comments/11/reactions")
          .to_return(status: 403, body: "{}")
        assert_nil GitHub.new("token").react("o/r", 11, kind: :issue)
      end
    end
  end
end
