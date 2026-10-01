require_relative "../../test_helper"

module OPilot
  class HealthParseTest < Minitest::Test
    def block(*lines)
      "Thinking first.\nBEGIN HEALTH\n#{lines.join("\n")}\nEND HEALTH\n"
    end

    def test_reads_findings_and_gaps
      answer = Helpers.parse_health(block(
        "FINDING: high | comments | The scope grew. | Ana, 2026-09-01T10:00:00Z",
        "GAP: mockup.png | the model cannot see pictures"
      ))
      assert_equal [{ "severity" => "high", "area" => "comments", "text" => "The scope grew.",
                      "evidence" => "Ana, 2026-09-01T10:00:00Z" }], answer["findings"]
      assert_equal [{ "what" => "mockup.png", "why" => "the model cannot see pictures" }], answer["gaps"]
    end

    def test_no_findings_is_a_readable_clean_answer
      assert_equal({ "findings" => [], "gaps" => [] }, Helpers.parse_health(block("NO FINDINGS")))
    end

    def test_a_cut_off_answer_is_nil
      assert_nil Helpers.parse_health("BEGIN HEALTH\nFINDING: high | comments | x | y\n")
      assert_nil Helpers.parse_health("No block at all.")
    end

    def test_a_finding_without_evidence_or_with_an_unknown_area_is_dropped
      answer = Helpers.parse_health(block(
        "FINDING: high | comments | No evidence here. |",
        "FINDING: high | vibes | Unknown area. | #42",
        "FINDING: LOW | Status | Kept. | #42"
      ))
      assert_equal ["Kept."], answer["findings"].map { |f| f["text"] }
      assert_equal "low", answer["findings"].first["severity"]
    end

    def test_markers_inside_a_fence_are_text
      body = "```\nBEGIN HEALTH\nFINDING: high | comments | quoted | #1\nEND HEALTH\n```\n"
      assert_nil Helpers.parse_health(body)
    end

    def test_the_last_complete_block_wins
      body = block("FINDING: low | status | rehearsal | #1") + block("NO FINDINGS")
      assert_equal [], Helpers.parse_health(body)["findings"]
    end

    def test_findings_are_capped
      lines = Array.new(20) { |i| "FINDING: low | status | Finding #{i}. | ##{i}" }
      assert_equal Prompts::Auditor::HEALTH_MAX_FINDINGS, Helpers.parse_health(block(*lines))["findings"].length
    end
  end

  class HealthCheckTest < Minitest::Test
    include TestFixtures

    STATUSES = {
      "New" => { "closed" => false, "default" => true },
      "Developed" => { "closed" => false, "default" => false },
      "Closed" => { "closed" => true, "default" => false }
    }.freeze
    NOW = Time.utc(2026, 9, 30)

    def setup
      @tmpdir = Dir.mktmpdir
      @ctx = build_ctx(@tmpdir)
      @check = OpenProject::HealthCheck.new(@ctx, pull: nil, harness: nil, api: Object.new)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
      super
    end

    def item(**over)
      { "id" => "42", "status" => "New", "created_at" => "2026-09-01T00:00:00Z",
        "description_changed_at" => "2026-09-01T00:00:00Z", "comments" => [], "history" => [] }
        .merge(over.transform_keys(&:to_s))
    end

    def facts(it, related: [], statuses: STATUSES, prs: [[], 200], commits: {}, tree: nil)
      @check.facts_for(it, related, statuses, prs, commits, tree: tree, now: NOW)
    end

    def texts(f) = f["findings"].map { |x| x["text"] }

    def test_a_closed_wp_with_an_open_child_or_blocker_is_a_finding
      related = [{ "id" => "7", "relation" => "child", "status" => "New" },
                 { "id" => "8", "relation" => "blocked", "status" => "Developed" },
                 { "id" => "9", "relation" => "relates", "status" => "New" }]
      f = facts(item(status: "Closed"), related: related)
      assert_equal ["This work package is closed, but its child #7 is still open.",
                    "This work package is closed, but #8 (blocked) is still open."], texts(f)
    end

    def test_an_open_wp_whose_children_all_closed_is_a_finding
      related = [{ "id" => "7", "relation" => "child", "status" => "Closed" }]
      assert_equal ["All children are closed, but this work package is still open."], texts(facts(item, related: related))
    end

    def test_a_merged_pr_counts_only_on_the_default_status
      prs = [[{ "url" => "https://github.com/o/r/pull/1", "merged" => true, "state" => "closed" }], 200]
      assert_equal 1, facts(item(status: "New"), prs: prs)["findings"].length
      assert_empty facts(item(status: "Developed"), prs: prs)["findings"], "Developed is open and has merged PRs"
    end

    def test_an_unreadable_pr_list_is_not_checked
      f = facts(item, prs: [nil, 403])
      assert_includes f["not_checked"], "Linked pull requests could not be read (HTTP 403)."
    end

    def test_commits_count_only_on_the_default_status
      commits = { "openproject" => [{ "sha" => "abc", "subject" => "[#42] Fix" }] }
      assert_equal ["Commits name this work package, but the status is still the initial one."],
                   texts(facts(item, commits: commits))
      assert_empty facts(item(status: "Developed"), commits: commits)["findings"]
    end

    def test_an_unreadable_status_list_skips_the_status_rules
      f = facts(item(status: "Closed"), related: [{ "id" => "7", "relation" => "child", "status" => "New" }], statuses: nil)
      assert_empty f["findings"]
      assert_includes f["not_checked"], "The status list could not be read, so no status rule ran."
    end

    def test_an_open_quiet_wp_is_stale
      f = facts(item(created_at: "2026-06-01T00:00:00Z"))
      assert_match(/nothing changed for 121 days/, texts(f).first)
    end

    def test_a_picture_added_after_the_description_is_a_finding_unless_it_is_in_the_description
      pictures = [{ "name" => "new.png", "where" => "comment 5", "created_at" => "2026-09-10T00:00:00Z" },
                  { "name" => "inline.png", "where" => "description", "created_at" => "2026-09-10T00:00:00Z" },
                  { "name" => "old.png", "where" => "attached", "created_at" => "2026-08-01T00:00:00Z" }]
      assert_equal ["The picture \"new.png\" was added after the last description edit."],
                   texts(facts(item(pictures: pictures)))
    end

    def test_unread_activities_run_no_timestamp_rule
      pictures = [{ "name" => "new.png", "where" => "attached", "created_at" => "2026-09-10T00:00:00Z" }]
      f = facts(item(history: nil, description_changed_at: nil, created_at: "2026-01-01T00:00:00Z", pictures: pictures))
      assert_empty f["findings"], "neither stale nor a design finding from missing data"
      assert(f["not_checked"].any? { |n| n.start_with?("The activities could not be read") })
    end

    # ── descendants ─────────────────────────────────────────────────────────

    def node(id, parent, status, updated_at: "2026-09-20T00:00:00Z")
      { "id" => id, "parent" => parent, "status" => status, "updated_at" => updated_at }
    end

    def tree(*nodes) = { "nodes" => nodes, "truncated" => false, "code" => 200 }

    def test_a_closed_wp_with_an_open_grandchild_is_a_finding
      t = tree(node("7", "42", "Closed"), node("8", "7", "New"))
      f = facts(item(status: "Closed"), tree: t)
      assert_equal ["This work package is closed, but 1 descendant(s) are still open.",
                    "Descendant #7 is closed, but a work package under it is still open."], texts(f)
    end

    def test_the_tree_replaces_the_direct_child_rule
      related = [{ "id" => "7", "relation" => "child", "status" => "New" }]
      f = facts(item(status: "Closed"), related: related, tree: tree(node("7", "42", "New")))
      assert_equal 1, f["findings"].length, "one finding for #7, not one from each rule"
    end

    def test_an_open_wp_whose_whole_subtree_is_closed_is_a_finding
      t = tree(node("7", "42", "Closed"), node("8", "7", "Closed"))
      assert_equal ["All 2 descendants are closed, but this work package is still open."], texts(facts(item, tree: t))
    end

    def test_open_descendants_that_did_not_change_are_counted
      t = tree(node("7", "42", "Developed", updated_at: "2026-01-01T00:00:00Z"), node("8", "42", "New"))
      assert_equal ["1 open descendant(s) did not change for 60 days."], texts(facts(item, tree: t))
    end

    def test_an_unreadable_or_cut_subtree_is_not_checked
      f = facts(item, tree: { "nodes" => nil, "truncated" => false, "code" => 403 })
      assert(f["not_checked"].any? { |n| n.start_with?("The descendants could not be read (HTTP 403)") })
      f = facts(item, tree: tree(node("7", "42", "New")).merge("truncated" => true))
      assert(f["not_checked"].any? { |n| n.include?("more than #{OpenProject::HealthCheck::MAX_DESCENDANTS}") })
    end

    def test_descendants_pages_through_the_ancestor_filter
      json = { "Content-Type" => "application/json" }
      stub_request(:get, %r{/api/v3/work_packages/42\z}).to_return(
        status: 200, headers: json, body: { "id" => 42, "displayId" => "TT-42" }.to_json
      )
      el = ->(id, parent) { { "id" => id, "displayId" => "TT-#{id}", "subject" => "S#{id}",
                              "_links" => { "parent" => { "href" => "/api/v3/work_packages/#{parent}" },
                                            "status" => { "href" => "/api/v3/statuses/1", "title" => "New" } } } }
      stub_request(:get, %r{/api/v3/work_packages\?.*ancestor.*offset=1}).to_return(
        status: 200, headers: json, body: { "total" => 2, "_embedded" => { "elements" => [el.(7, 42)] } }.to_json
      )
      stub_request(:get, %r{/api/v3/work_packages\?.*ancestor.*offset=2}).to_return(
        status: 200, headers: json, body: { "total" => 2, "_embedded" => { "elements" => [el.(8, 7)] } }.to_json
      )
      check = OpenProject::HealthCheck.new(@ctx, pull: nil, harness: nil)
      nodes = check.descendants("42")["nodes"]
      assert_equal [["TT-7", "TT-42", 1, "New"], ["TT-8", "TT-7", 2, "New"]],
                   nodes.map { |n| n.values_at("id", "parent", "depth", "status") }
    end

    def test_skipped_attachments_are_not_checked
      f = facts(item(pictures_skipped: [{ "name" => "flow.svg", "where" => "attached", "reason" => "not a picture (image/svg+xml)" }]))
      assert_includes f["not_checked"], "Attachment \"flow.svg\" (attached): not a picture (image/svg+xml)."
    end

    def test_commit_filter_does_not_match_a_longer_id
      wt = Class.new do
        def log(*) = self
        def object(*) = self
        def grep(*) = self
        def execute
          [TestFixtures::FakeCommit.new(sha: "a" * 40, message: "[#59942] Other"),
           TestFixtures::FakeCommit.new(sha: "b" * 40, message: "[#5994] This one")]
        end
      end.new
      @check.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = wt })
      @check.define_singleton_method(:fetch_base_if_stale) { |*, **| Time.utc(2026, 1, 1) }
      found = @check.commits("5994")
      assert_equal ["2026-01-01T00:00:00Z"], @check.instance_variable_get(:@commits_as_of).values.uniq
      assert_equal [["b" * 12]], found.values.map { |list| list.map { |c| c["sha"] } }
    end

    def test_commits_report_an_unreadable_clone_and_read_the_rest
      @check.define_singleton_method(:worktree) { |repo| repo.name == "openproject" ? raise("no clone") : super(repo) }
      @check.instance_variable_set(:@worktrees, Hash.new { |h, k| h[k] = Class.new { def log(*) = self; def object(*) = self; def grep(*) = self; def execute = [] }.new })
      @check.define_singleton_method(:fetch_base_if_stale) { |*, **| nil }
      found = @check.commits("5994")
      assert_nil found["openproject"]
      assert(found.except("openproject").values.all? { |v| v == [] })
    end

    def test_commit_pattern_reads_the_forms_a_work_package_is_named_in
      numeric = OpenProject::HealthCheck.commit_pattern("5994")
      ["[#5994] Fix", "Refs OP#5994", "Merge pull request #1 from opf/bug/5994-login",
       "See https://community.openproject.org/wp/5994"].each { |m| assert_match numeric, m }
      ["[#59942] Other", "bug/59942-x", "&#5994;"].each { |m| refute_match numeric, m }
      assert_empty "Merge pull request #5994 from opf/x (#5994)".gsub(OpenProject::HealthCheck::PR_NUMBER, "").scan(numeric)

      semantic = OpenProject::HealthCheck.commit_pattern("COMMS-123")
      assert_match semantic, "Merge pull request #9 from opf/bug/comms-123-toast"
      refute_match semantic, "bug/comms-1234-x"
      refute_match semantic, "xcomms-123"
      assert_equal "[cC][oO][mM][mM][sS]-123", OpenProject::HealthCheck.commit_prefilter("COMMS-123")
    end

    def test_report_orders_by_severity_and_lists_what_was_not_checked
      f = { "findings" => [{ "severity" => "low", "area" => "status", "text" => "Stale.", "evidence" => "x" }],
            "not_checked" => ["Attachment \"a.svg\": not a picture."] }
      answer = { "findings" => [{ "severity" => "high", "area" => "comments", "text" => "Scope grew.", "evidence" => "Ana" }],
                 "gaps" => [{ "what" => "b.png", "why" => "unreadable" }] }
      text = @check.report(f, answer, item)
      assert_equal <<~TEXT.strip, text
        **Health check: 2 findings** (1 high, 1 low)

        **High**
        - Scope grew. (Ana)

        **Low**
        - Stale. (x)

        **Not checked**
        - Attachment "a.svg": not a picture.
        - b.png: unreadable
      TEXT
    end

    # From a real run: the model repeated a fact line as a GAP despite the prompt.
    def test_a_gap_that_repeats_a_not_checked_line_is_dropped
      f = { "findings" => [], "not_checked" => ["Linked pull requests could not be read (HTTP 403)."] }
      answer = { "findings" => [], "gaps" => [
        { "what" => "Linked pull requests", "why" => "The runner already lists this in not_checked (HTTP 403)." },
        { "what" => "mockup.png", "why" => "unreadable" }
      ] }
      text = @check.report(f, answer, item)
      assert_equal 1, text.scan("Linked pull requests").length
      assert_includes text, "- mockup.png: unreadable"
    end

    def test_a_public_report_hides_a_finding_that_cites_an_internal_comment
      it = item(comments: [{ "created_at" => "2026-09-02T08:15:00Z", "internal" => true }])
      answer = { "findings" => [{ "severity" => "high", "area" => "comments", "text" => "Secret.",
                                  "evidence" => "Bo, 2026-09-02T08:15" }], "gaps" => [] }
      text = @check.report({ "findings" => [], "not_checked" => [] }, answer, it, internal: false)
      refute_includes text, "Secret."
      assert_includes text, "1 finding(s) cite an internal comment"
      assert_includes @check.report({ "findings" => [], "not_checked" => [] }, answer, it, internal: true), "Secret."
    end

    # ── the whole run, with fakes at every edge ─────────────────────────────

    class FakePull
      def initialize(ctx, item); @ctx = ctx; @item = item; end
      def fetch_single_item(_id)
        dir = Helpers.item_dir(@ctx, @item["id"])
        dir.mkpath
        (dir / "item.json").write(JSON.generate(@item))
        @item
      end
      def related_work_packages(_id, mirror: true); []; end
    end

    class ScriptedHarness
      attr_reader :prompts
      def initialize(*answers); @answers = answers; @prompts = []; end
      def run(prompt, tools: nil, **)
        @prompts << [prompt, tools]
        @answers[@prompts.length - 1] || @answers.last
      end
    end

    def run_check(harness)
      stub_request(:get, %r{/api/v3/statuses}).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { "_embedded" => { "elements" => [{ "name" => "New", "isClosed" => false, "isDefault" => true }] } }.to_json
      )
      stub_request(:get, %r{/work_packages/42/github_pull_requests}).to_return(status: 403, body: "{}")
      stub_request(:get, %r{/api/v3/work_packages/42\z}).to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: { "id" => 42 }.to_json
      )
      stub_request(:get, %r{/api/v3/work_packages\?.*ancestor}).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { "total" => 0, "_embedded" => { "elements" => [] } }.to_json
      )
      check = OpenProject::HealthCheck.new(@ctx, pull: FakePull.new(@ctx, item(subject: "Login")), harness: harness)
      check.define_singleton_method(:commits) { |_id| {} }
      check.run("42", focus: "the toast")
    end

    def test_run_writes_the_facts_and_posts_the_composed_report
      harness = ScriptedHarness.new("BEGIN HEALTH\nNO FINDINGS\nEND HEALTH")
      text = run_check(harness)
      assert_match(/\A\*\*Health check: no findings\.\*\*/, text)
      assert_includes text, "Linked pull requests could not be read (HTTP 403)."
      prompt, tools = harness.prompts.first
      assert_includes prompt, "/health.json"
      assert_includes prompt, "look especially at: the toast"
      assert_includes prompt, "RELATED: none", "no relations must not read as 'not loaded'"
      assert_includes prompt, "DESCENDANTS: none"
      assert_equal Harness::TOOLS_READ, tools.split(",").first(5).join(",")
      assert (Helpers.item_dir(@ctx, "42") / "health.json").exist?
    end

    def test_run_retries_once_then_reports_the_failure
      harness = ScriptedHarness.new("garbage", "still garbage")
      assert_match(/did not finish/, run_check(harness))
      assert_equal 2, harness.prompts.length
    end
  end
end
