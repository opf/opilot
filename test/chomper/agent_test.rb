require_relative "../test_helper"

module Chomper
  class AgentTest < Minitest::Test
    # ── fakes ──────────────────────────────────────────────────────────────────

    class FakeClaude
      attr_reader :runs, :captures, :run_sessions, :capture_sessions
      def initialize(plan: "## Plan\nDo the thing.\n", review: "### Verdict\nPROCEED",
                     chat: "Here's my take.", impl: "", pr: "# PR title\nbody")
        @plan, @review, @chat, @impl, @pr = plan, review, chat, impl, pr
        @runs = []; @captures = []; @run_sessions = []; @capture_sessions = []
      end

      def capture(prompt, tools: nil, model: nil, outfile:, session_file: nil)
        @captures << prompt
        @capture_sessions << session_file
        content = prompt.include?("REVIEWER") ? @review : @plan
        Pathname(outfile).write(content)
        content
      end

      def run(prompt, tools: nil, model: nil, session_file: nil)
        @runs << prompt
        @run_sessions << session_file
        return @chat if prompt.include?("You are chomper")
        return @pr   if prompt.include?("PR description")
        @impl
      end
    end

    # Mirrors the real Publish: open_pr writes pr_url.txt and returns the URL.
    class FakePublish
      def initialize(state_dir, pr:); @state_dir = state_dir; @pr = pr; end
      def open_pr(id, _subject, _branch)
        (@state_dir / "items" / id.to_s / "pr_url.txt").write(@pr)
        @pr
      end
    end

    class FakePull
      attr_reader :acted
      attr_accessor :related
      def initialize; @acted = []; @related = []; end
      def mark_acted(id, at); @acted << [id, at]; end
      def record_chomper_comment(*, **); end
      def related_work_packages(_id); @related; end
    end

    # A publisher whose push always fails, to exercise the error path.
    class BoomPublish
      def open_pr(*); raise "git push failed for branch fix/x"; end
    end

    class FakeCommit
      def sha; "abcdef1234567"; end
      def message; "fix: something"; end
    end

    class FakeLog
      def initialize(has) @has = has end
      def between(_a, _b); self; end
      def execute; @has ? [FakeCommit.new] : []; end
      def first; @has ? FakeCommit.new : nil; end
    end

    class FakeDiff
      def initialize(has_changes) @has_changes = has_changes end
      def entries; @has_changes ? [:change] : []; end
      def stats; { files: { "app/x.rb" => { insertions: 2, deletions: 1 } } }; end
    end

    # Minimal stand-in for the ruby-git worktree handle the Agent uses.
    class FakeWorktree
      attr_reader :checkouts, :commits, :configs
      def initialize(has_commits: false, has_changes: true)
        @has_commits = has_commits
        @has_changes = has_changes
        @checkouts = []; @commits = []; @configs = []
      end
      def revparse(_ref); "sha"; end                 # branch "exists" → checkout, no create
      def checkout(branch, **_opts); @checkouts << branch; end
      def config(key, value); @configs << [key, value]; end
      def log(*_args); FakeLog.new(@has_commits); end
      def add(**_opts); end
      def diff(*_args); FakeDiff.new(@has_changes); end
      def commit(msg); @commits << msg; @has_commits = true; end
    end

    # ── harness ────────────────────────────────────────────────────────────────

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = Struct.new(
        :script_dir, :state_dir, :op_url, :token, :worktree_container, :state_container,
        :repo_path, :allowed_emails, :log_file, :progress_file, :plan_review, :auto_plan_approval
      ) do
        def plan_review?; plan_review; end                 # opt-in agent self-review (off by default)
        def auto_plan_approval?; auto_plan_approval; end   # auto-approve plans (off by default)
      end.new(
        Pathname(@tmpdir), Pathname(@tmpdir) / ".chomper", "https://op.example.com", "tok",
        "/repo", "/state", Pathname(@tmpdir), [],
        Pathname(@tmpdir) / "chomp.log", Pathname(@tmpdir) / "progress.txt", false, false
      )
      (Pathname(@tmpdir) / ".chomper").mkpath

      @claude  = FakeClaude.new
      @publish = FakePublish.new(@ctx.state_dir, pr: "https://github.com/o/r/pull/7")
      @pull    = FakePull.new
      @agent   = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      @agent.instance_variable_set(:@worktree, FakeWorktree.new)

      # @chomper notes are posted to the activities endpoint.
      @notes = []
      stub_request(:post, %r{/work_packages/\d+/activities}).to_return do |req|
        @notes << JSON.parse(req.body).dig("comment", "raw")
        { status: 201, body: "{}" }
      end
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def intent(command, item_id: "42", subject: "Fix the bug", type: "bug", text: nil, user: nil, user_href: nil)
      Intent.new(item_id: item_id, subject: subject, type: type, command: command, text: text,
                 comment_at: "2024-02-01T00:00:00Z", user: user, user_href: user_href)
    end

    def plan_path(id = "42"); @ctx.state_dir / "items" / id / "plan.md"; end
    def pr_url_path(id = "42"); @ctx.state_dir / "items" / id / "pr_url.txt"; end

    # ── produce_plan ────────────────────────────────────────────────────────

    def test_produce_plan_saves_plan_and_returns_ok
      st = @agent.send(:state_for, "42", "Fix the bug")
      assert_equal :ok, @agent.send(:produce_plan, st, nil)
      assert plan_path.exist?
    end

    def test_produce_plan_needs_info_posts_questions_and_writes_no_plan
      @claude = FakeClaude.new(plan: "NEEDS_INFO\n### Questions for the reporter\n- How do I reproduce it?")
      @agent  = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      @agent.instance_variable_set(:@worktree, FakeWorktree.new)

      st = @agent.send(:state_for, "42", "Fix the bug")
      assert_equal :needs_info, @agent.send(:produce_plan, st, nil)
      refute plan_path.exist?
      assert(@notes.any? { |n| n.include?("How do I reproduce it?") })
    end

    def test_produce_plan_reject_posts_concerns_and_drops_plan
      @ctx.plan_review = true   # reviewer is opt-in
      @claude = FakeClaude.new(review: "### Issues found\nUnsafe.\n### Verdict\nREJECT")
      @agent  = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      @agent.instance_variable_set(:@worktree, FakeWorktree.new)

      st = @agent.send(:state_for, "42", "Fix the bug")
      assert_equal :rejected, @agent.send(:produce_plan, st, nil)
      refute plan_path.exist?
    end

    # ── ship ──────────────────────────────────────────────────────────────────

    def test_ship_reports_existing_pr_without_reimplementing
      st = @agent.send(:state_for, "42", "Fix the bug")
      pr_url_path.write("https://github.com/o/r/pull/1\n")

      @agent.send(:ship, st)
      assert_empty @claude.runs, "should not implement when already shipped"
      assert(@notes.any? { |n| n.include?("already shipped") })
    end

    def test_ship_implements_commits_and_opens_pr
      st = @agent.send(:state_for, "42", "Fix the bug")
      plan_path.write("## Plan\nDo it.\n")

      @agent.send(:ship, st)
      assert(@notes.any? { |n| n.include?("https://github.com/o/r/pull/7") })
      assert pr_url_path.exist?
    end

    def test_ship_skips_implementation_when_branch_already_has_commits
      st = @agent.send(:state_for, "42", "Fix the bug")
      plan_path.write("## Plan\nDo it.\n")
      @agent.instance_variable_set(:@worktree, FakeWorktree.new(has_commits: true))

      @agent.send(:ship, st)
      refute(@claude.runs.any? { |p| p.include?("APPROVED PLAN") }, "should not re-run implement")
      assert pr_url_path.exist?
    end

    def test_checkout_branch_tracks_the_pr_branch_not_dev
      st = @agent.send(:state_for, "42", "Fix the bug", "bug")
      @agent.send(:checkout_branch, st)

      configs = @agent.instance_variable_get(:@worktree).configs
      assert_includes configs, ["branch.#{st.branch}.remote", "origin"]
      assert_includes configs, ["branch.#{st.branch}.merge", "refs/heads/#{st.branch}"],
                      "the fix branch must track its own PR branch, never origin/dev"
    end

    # ── handlers / routing ────────────────────────────────────────────────────

    def test_handle_approve_without_plan_guards
      @agent.handle(intent(:approve))
      refute pr_url_path.exist?
      assert(@notes.any? { |n| n.include?("no plan yet") })
    end

    def test_handle_fix_skips_ship_when_needs_info
      @claude = FakeClaude.new(plan: "NEEDS_INFO\n### Questions for the reporter\n- repro?")
      @agent  = Agent.new(@ctx, pull: @pull, claude: @claude, publish: @publish)
      @agent.instance_variable_set(:@worktree, FakeWorktree.new)

      @agent.handle(intent(:fix))
      refute pr_url_path.exist?, "must not ship when info is missing"
    end

    def test_handle_fix_plans_and_ships
      @agent.handle(intent(:fix))
      assert plan_path.exist?
      assert pr_url_path.exist?
      assert(@notes.any? { |n| n.include?("https://github.com/o/r/pull/7") })
    end

    def test_handle_fix_skips_the_reviewer
      @agent.handle(intent(:fix))
      refute(@claude.captures.any? { |p| p.include?("REVIEWER") }, "fix should not run the reviewer")
    end

    def test_handle_plan_runs_the_reviewer_when_opted_in
      @ctx.plan_review = true
      @agent.handle(intent(:plan))
      assert(@claude.captures.any? { |p| p.include?("REVIEWER") }, "plan should run the reviewer when opted in")
    end

    def test_handle_plan_skips_the_reviewer_by_default
      @agent.handle(intent(:plan))
      refute(@claude.captures.any? { |p| p.include?("REVIEWER") },
             "plan should not run the reviewer unless CHOMPER_PLAN_REVIEW is set")
    end

    def test_handle_fix_threads_one_session_through_plan_implement_and_pr
      @agent.handle(intent(:fix))
      session = @ctx.state_dir / "items" / "42" / "session_id"
      assert_equal [session], @claude.capture_sessions.uniq, "plan must use the per-WP session"
      assert_equal [session], @claude.run_sessions.uniq, "implement and PR description must resume the planning session"
    end

    def test_handle_plan_keeps_the_reviewer_session_free
      @ctx.plan_review = true
      @agent.handle(intent(:plan))
      session = @ctx.state_dir / "items" / "42" / "session_id"
      assert_equal [session, nil], @claude.capture_sessions, "the reviewer must not inherit the writer's session"
    end

    def test_handle_plan_posts_the_plan_text_as_a_comment
      @agent.handle(intent(:plan))
      note = @notes.find { |n| n.include?("Do the thing.") }
      assert note, "the plan content should be posted to the WP"
      assert_includes note, "@chomper approve"
    end

    def test_handle_plan_auto_approves_and_ships_when_env_set
      @ctx.auto_plan_approval = true
      @agent.handle(intent(:plan))
      assert pr_url_path.exist?, "AUTO_PLAN_APPROVAL should implement the plan without waiting for approve"
      assert(@notes.any? { |n| n.include?("implementing it now") })
      assert(@notes.any? { |n| n.include?("https://github.com/o/r/pull/7") })
      refute(@notes.any? { |n| n.include?("@chomper approve") },
             "auto-approval shouldn't ask the user to approve")
    end

    def test_handle_chat_posts_reply_and_changes_no_files
      @agent.handle(intent(:chat, text: "what about tests?"))
      refute plan_path.exist?
      refute pr_url_path.exist?
      assert_includes @notes, "Here's my take."
    end

    # ── related work packages ─────────────────────────────────────────────────

    def related_path(id = "42"); @ctx.state_dir / "items" / id / "related.json"; end

    def test_handle_plan_writes_related_index_and_injects_it
      @pull.related = [{ "id" => "200", "relation" => "relates", "subject" => "Other", "status" => "New" }]
      @agent.handle(intent(:plan))

      assert related_path.exist?, "the related index should be written"
      index = JSON.parse(related_path.read)
      assert_equal "/state/items/200/item.json", index.first["item_path"]

      plan_prompt = @claude.captures.find { |p| p.include?("PRODUCT REPO") }
      assert_includes plan_prompt, "RELATED:"
      assert_includes plan_prompt, "/state/items/42/related.json"
    end

    def test_handle_chat_injects_related_context
      @pull.related = [{ "id" => "50", "relation" => "parent", "subject" => "Epic", "status" => "New" }]
      @agent.handle(intent(:chat, text: "how does this relate to the epic?"))

      chat_prompt = @claude.runs.find { |p| p.include?("You are chomper") }
      assert_includes chat_prompt, "RELATED:"
    end

    def test_no_related_means_no_index_and_no_related_line
      @agent.handle(intent(:plan))   # FakePull.related defaults to []
      refute related_path.exist?
      plan_prompt = @claude.captures.find { |p| p.include?("PRODUCT REPO") }
      refute_includes plan_prompt, "RELATED:"
    end

    def test_handle_and_ack_marks_and_reports_on_error
      agent = Agent.new(@ctx, pull: @pull, claude: @claude, publish: BoomPublish.new)
      agent.instance_variable_set(:@worktree, FakeWorktree.new)
      plan_path.dirname.mkpath
      plan_path.write("## Plan\nDo it.\n")   # approve will reach the failing push

      agent.send(:handle_and_ack, intent(:approve, user: "Jane", user_href: "/api/v3/users/2"))

      # Acked despite the failure → no infinite re-try on the next poll.
      assert_equal [["42", "2024-02-01T00:00:00Z"]], @pull.acted
      assert(@notes.any? { |n| n.include?("hit an error") }, "should report the failure on the WP")
      refute pr_url_path.exist?
    end

    def test_replies_mention_the_requesting_user
      @agent.handle(intent(:approve, user: "Jane Doe", user_href: "/api/v3/users/2"))
      note = @notes.last
      assert_includes note, %q(<mention class="mention" data-id="2" data-type="user" data-text="Jane Doe">@Jane Doe</mention>)
      assert_includes note, "no plan yet"
    end
  end
end
