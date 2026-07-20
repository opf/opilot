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

      def test_create_draft_pr_can_disable_maintainer_edits_for_same_repo
        stub = stub_request(:post, "https://api.github.com/repos/opf/openproject/pulls")
               .with(body: hash_including("draft" => true, "maintainer_can_modify" => false))
               .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate("html_url" => "https://github.com/opf/openproject/pull/9"))

        GitHub.new("token").create_draft_pr(
          "opf/openproject", base: "dev", head: "opf:bug/42-x", title: "T", body: "B",
          maintainer_can_modify: false
        )
        assert_requested(stub)
      end

      def test_sync_fork_branch_posts_merge_upstream_with_the_branch
        stub = stub_request(:post, "https://api.github.com/repos/me/openproject/merge-upstream")
               .with(body: hash_including("branch" => "dev"))
               .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                          body: JSON.generate("merge_type" => "fast-forward"))

        assert GitHub.new("token").sync_fork_branch("me/openproject", "dev")
        assert_requested(stub)
      end

      def test_sync_fork_branch_swallows_errors_so_a_diverged_fork_never_aborts
        # A branch that can't fast-forward (409) or a fork with no parent must
        # leave publishing to carry on — the diff just shows some base drift.
        stub_request(:post, "https://api.github.com/repos/me/openproject/merge-upstream")
          .to_return(status: 409, body: "{}")
        refute GitHub.new("token").sync_fork_branch("me/openproject", "dev")
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

      def test_search_prs_retries_a_dropped_connection_then_succeeds
        # A dropped connection mid-poll surfaces as Faraday::ConnectionFailed —
        # not an Octokit::Error — and used to crash the whole agent loop. The
        # client must retry it and recover.
        stub = stub_request(:get, %r{https://api\.github\.com/search/issues})
               .to_raise(Faraday::ConnectionFailed.new("end of file reached"))
               .then.to_return(status: 200, headers: { "Content-Type" => "application/json" },
                               body: JSON.generate("items" => [{ "number" => 5 }]))

        items = GitHub.new("token").search_prs("repo:o/r is:pr is:open")
        assert_equal [5], items.map(&:number)
        assert_requested(stub, times: 2)
      end

      def test_search_prs_degrades_to_empty_when_retries_exhausted
        # Persistent connection failure: after exhausting retries it must return
        # [] rather than raise, so one bad poll never breaks the loop.
        stub_request(:get, %r{https://api\.github\.com/search/issues})
          .to_raise(Faraday::ConnectionFailed.new("end of file reached"))
        assert_equal [], GitHub.new("token").search_prs("repo:o/r is:pr is:open")
      end

      def test_pull_request_retries_a_transient_server_error
        stub = stub_request(:get, "https://api.github.com/repos/o/r/pulls/7")
               .to_return(status: 502, body: "{}")
               .then.to_return(status: 200, headers: { "Content-Type" => "application/json" },
                               body: JSON.generate("number" => 7, "title" => "T"))

        pr = GitHub.new("token").pull_request("o/r", 7)
        assert_equal 7, pr.number
        assert_requested(stub, times: 2)
      end
    end
  end
end
