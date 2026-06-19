require_relative "../test_helper"

module Chomper
  class GhPullTest < Minitest::Test
    User          = Struct.new(:login)
    Head          = Struct.new(:ref, :sha)
    PR            = Struct.new(:state, :updated_at, :html_url, :title, :head, keyword_init: true)
    IssueC        = Struct.new(:id, :body, :user, :created_at, keyword_init: true)
    ReviewC       = Struct.new(:id, :body, :user, :created_at, :in_reply_to_id, :path, :line, :diff_hunk, keyword_init: true)
    ReviewSummary = Struct.new(:id, :body, :user, :state, :submitted_at, keyword_init: true)

    class FakeGitHub
      attr_reader :comment_fetches
      def initialize(pr:, issue: [], review: [], reviews: [])
        @pr = pr; @issue = issue; @review = review; @reviews = reviews; @comment_fetches = 0
      end
      def pull_request(_repo, _num);   @pr;      end
      def issue_comments(_repo, _num); @comment_fetches += 1; @issue; end
      def review_comments(_repo, _num); @review;  end
      def reviews(_repo, _num);         @reviews; end
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = Struct.new(:state_dir, :allowed_gh_users, :github_token, :log_file).new(
        Pathname(@tmpdir) / ".chomper", ["thykel"], "ghtok", Pathname(@tmpdir) / "chomp.log"
      )
      @dir = @ctx.state_dir / "items" / "42"
      @dir.mkpath
      (@dir / "pr_url.txt").write("https://github.com/o/r/pull/7\n")
      (@dir / "item.json").write(JSON.generate("subject" => "Fix the bug", "type" => "bug"))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def pr(state: "open", updated_at: "2026-06-18T18:00:00Z", title: "PR title", ref: "bug/42-fix-the-bug")
      PR.new(state: state, updated_at: Time.parse(updated_at),
             html_url: "https://github.com/o/r/pull/7", title: title, head: Head.new(ref, "sha123"))
    end

    def issue_c(id:, body:, login:, at:)
      IssueC.new(id: id, body: body, user: User.new(login), created_at: Time.parse(at))
    end

    def review_c(id:, body:, login:, at:, in_reply_to: nil, path: nil, line: nil, diff_hunk: nil)
      ReviewC.new(id: id, body: body, user: User.new(login), created_at: Time.parse(at),
                  in_reply_to_id: in_reply_to, path: path, line: line, diff_hunk: diff_hunk)
    end

    def review_summary(id:, body:, login:, state:, at:)
      ReviewSummary.new(id: id, body: body, user: User.new(login), state: state, submitted_at: Time.parse(at))
    end

    def pull(issue: [], review: [], reviews: [], pr_obj: pr)
      @github = FakeGitHub.new(pr: pr_obj, issue: issue, review: review, reviews: reviews)
      GhPull.new(@ctx, github: @github)
    end

    def test_returns_intent_for_a_chomper_comment
      gh = pull(issue: [issue_c(id: 1, body: "@chomper please guard nil", login: "thykel", at: "2026-06-18T18:05:00Z")])
      intents = gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, intents.length
      i = intents.first
      assert_equal "42", i.item_id
      assert_equal "o/r", i.repo
      assert_equal 7, i.pr_number
      assert_equal :issue, i.kind
      assert_equal "thykel", i.user_login
    end

    def test_uses_the_real_pr_head_ref_for_the_branch
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")],
                pr_obj: pr(ref: "renamed/branch-after-edit"))
      assert_equal "renamed/branch-after-edit", gh.poll_intents("2000-01-01T00:00:00Z").first.branch
    end

    def test_review_reply_carries_kind_and_parent
      gh = pull(review: [review_c(id: 5, body: "@chomper fix this", login: "thykel",
                                  at: "2026-06-18T18:05:00Z", in_reply_to: 999, path: "app/x.rb", line: 12)])
      i = gh.poll_intents("2000-01-01T00:00:00Z").first
      assert_equal :review, i.kind
      assert_equal 5, i.comment_id
      assert_equal 999, i.in_reply_to
    end

    def test_skips_closed_or_merged_prs
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")],
                pr_obj: pr(state: "closed"))
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    def test_ignores_comments_without_mention
      gh = pull(issue: [issue_c(id: 1, body: "looks good to me", login: "thykel", at: "2026-06-18T18:05:00Z")])
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    def test_allowlist_rejects_other_users_and_advances_cutoff
      gh = pull(issue: [issue_c(id: 9, body: "@chomper do it", login: "rando", at: "2026-06-18T18:05:00Z")])
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
      state = JSON.parse((@dir / "gh_pr.json").read)
      assert_equal "2026-06-18T18:05:00Z", state["last_acted_comment_at"]
    end

    def test_scan_from_floor_excludes_older_comments
      gh = pull(issue: [issue_c(id: 1, body: "@chomper old one", login: "thykel", at: "2024-01-01T00:00:00Z")])
      assert_empty gh.poll_intents("2024-06-01T00:00:00Z")
    end

    def test_skips_chompers_own_recorded_replies
      gh = pull(issue: [issue_c(id: 1, body: "@chomper hi", login: "thykel", at: "2026-06-18T18:05:00Z")])
      gh.record_chomper_comment("42", 1)
      assert_empty gh.poll_intents("2000-01-01T00:00:00Z")
    end

    # ── content cache ────────────────────────────────────────────────────────

    def test_caches_full_pr_content_including_copilot_review
      gh = pull(
        issue:   [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")],
        review:  [review_c(id: 2, body: "This nil isn't guarded.", login: "copilot-pull-request-reviewer[bot]",
                           at: "2026-06-18T17:00:00Z", path: "app/x.rb", line: 9, diff_hunk: "@@ -1 +1 @@")],
        reviews: [review_summary(id: 3, body: "A few issues to address.", login: "copilot-pull-request-reviewer[bot]",
                                 state: "COMMENTED", at: "2026-06-18T17:00:00Z")]
      )
      gh.poll_intents("2000-01-01T00:00:00Z")

      cache = JSON.parse((@dir / "pr.json").read)
      assert_equal "bug/42-fix-the-bug", cache["head_ref"]
      assert(cache["comments"].any? { |c| c["author"].include?("copilot") && c["diff_hunk"] },
             "Copilot's inline finding should be cached with its diff hunk")
      assert(cache["reviews"].any? { |r| r["author"].include?("copilot") && r["body"].include?("issues") },
             "Copilot's review summary should be cached")
    end

    def test_reuses_cache_while_pr_updated_at_is_unchanged
      # First poll fetches comments and writes pr.json.
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")])
      gh.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.comment_fetches

      # Second poll, same PR updated_at but a NEW comment available: the cache is
      # reused, so the comment streams are NOT re-fetched and nothing new surfaces.
      gh2 = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z"),
                         issue_c(id: 2, body: "@chomper again", login: "thykel", at: "2026-06-18T18:06:00Z")])
      gh2.record_chomper_comment("42", 1)            # id 1 already handled
      intents = gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 0, @github.comment_fetches, "unchanged updated_at must reuse pr.json, not re-fetch"
      assert_empty intents
    end

    def test_refetches_when_pr_updated_at_changes
      gh = pull(issue: [issue_c(id: 1, body: "@chomper go", login: "thykel", at: "2026-06-18T18:05:00Z")])
      gh.poll_intents("2000-01-01T00:00:00Z")

      gh2 = pull(issue: [issue_c(id: 2, body: "@chomper again", login: "thykel", at: "2026-06-18T18:30:00Z")],
                 pr_obj: pr(updated_at: "2026-06-18T18:30:00Z"))
      gh2.record_chomper_comment("42", 1)
      intents = gh2.poll_intents("2000-01-01T00:00:00Z")
      assert_equal 1, @github.comment_fetches, "a changed updated_at must re-fetch the comment streams"
      assert_equal [2], intents.map(&:comment_id)
    end

    def test_mark_acted_advances_to_the_latest
      gh = pull
      gh.mark_acted("42", "2026-06-18T18:00:00Z")
      gh.mark_acted("42", "2024-01-01T00:00:00Z") # older — must not regress
      state = JSON.parse((@dir / "gh_pr.json").read)
      assert_equal "2026-06-18T18:00:00Z", state["last_acted_comment_at"]
    end

    def test_only_watches_dirs_with_a_shipped_pr
      planned = @ctx.state_dir / "items" / "99"
      planned.mkpath
      (planned / "plan.md").write("## Plan") # no pr_url.txt → not watched
      gh = pull
      assert_equal ["42"], gh.shipped_item_dirs.map { |d| d.basename.to_s }
    end
  end
end
