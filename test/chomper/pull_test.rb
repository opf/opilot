require_relative "../test_helper"

module Chomper
  class PullTest < Minitest::Test
    def setup
      ctx = Struct.new(:op_url, :token).new("https://example.com", nil)
      @pull = Pull.new(ctx)
    end

    WP = {
      "id"          => 42,
      "subject"     => "Fix login bug",
      "createdAt"   => "2024-01-01T00:00:00Z",
      "updatedAt"   => "2024-01-02T00:00:00Z",
      "description" => { "raw" => "Something is broken" },
      "_embedded"   => {
        "status"   => { "name" => "New" },
        "priority" => { "name" => "High" },
        "assignee" => { "name" => "Alice" },
        "author"   => { "name" => "Bob" },
        "version"  => { "name" => "17.5.0" },
        "category" => { "name" => "Core" }
      }
    }.freeze

    def test_build_full_item_maps_id_as_string
      item = @pull.send(:build_full_item, WP, [])
      assert_equal "42", item["id"]
    end

    def test_build_full_item_prefers_semantic_display_id
      wp = WP.merge("displayId" => "PROJ-42")
      item = @pull.send(:build_full_item, wp, [])
      assert_equal "PROJ-42", item["id"]
      assert_equal "https://example.com/work_packages/PROJ-42", item["url"]
    end

    def test_build_full_item_falls_back_to_id_when_display_id_is_null
      wp = WP.merge("displayId" => nil)   # render_nil: true on older items
      item = @pull.send(:build_full_item, wp, [])
      assert_equal "42", item["id"]
    end

    def test_build_full_item_maps_subject
      item = @pull.send(:build_full_item, WP, [])
      assert_equal "Fix login bug", item["subject"]
    end

    def test_build_full_item_maps_embedded_fields
      item = @pull.send(:build_full_item, WP, [])
      assert_equal "New",    item["status"]
      assert_equal "High",   item["priority"]
      assert_equal "Alice",  item["assignee"]
      assert_equal "Bob",    item["author"]
      assert_equal "17.5.0", item["version"]
      assert_equal "Core",   item["category"]
    end

    def test_build_full_item_has_no_state_field
      item = @pull.send(:build_full_item, WP, [])
      refute item.key?("state")
    end

    def test_build_full_item_nil_assignee_becomes_unassigned
      wp = WP.merge("_embedded" => WP["_embedded"].merge("assignee" => nil))
      item = @pull.send(:build_full_item, wp, [])
      assert_equal "unassigned", item["assignee"]
    end

    def test_build_full_item_empty_description_becomes_empty_string
      wp = WP.merge("description" => nil)
      item = @pull.send(:build_full_item, wp, [])
      assert_equal "", item["description"]
    end

    def test_build_full_item_attaches_comments
      comments = [{ "user" => "Alice", "text" => "Hello" }]
      item = @pull.send(:build_full_item, WP, comments)
      assert_equal comments, item["comments"]
    end

    def test_build_full_item_url_uses_op_url
      item = @pull.send(:build_full_item, WP, [])
      assert_equal "https://example.com/work_packages/42", item["url"]
    end

    def test_build_comments_filters_blank_comment_text
      activities = [
        { "id" => 1, "comment" => { "raw" => "" },    "_embedded" => { "user" => { "name" => "A" } }, "createdAt" => "t" },
        { "id" => 2, "comment" => { "raw" => "Hi" },  "_embedded" => { "user" => { "name" => "B" } }, "createdAt" => "t" },
        { "id" => 3, "comment" => { "raw" => "   " }, "_embedded" => { "user" => { "name" => "C" } }, "createdAt" => "t" },
      ]
      result = @pull.send(:build_comments, activities, [])
      assert_equal 1, result.length
      assert_equal "B", result[0]["user"]
    end

    def test_build_comments_attaches_reactions_by_activity_id
      activities = [
        { "id" => 5, "comment" => { "raw" => "Text" }, "_embedded" => { "user" => { "name" => "A" } }, "createdAt" => "t" }
      ]
      reactions = [
        { "reaction" => "thumbsup", "reactionsCount" => 3,
          "_links" => { "reactable" => { "href" => "/api/v3/activities/5" } } }
      ]
      result = @pull.send(:build_comments, activities, reactions)
      assert_equal({ "thumbsup" => 3 }, result[0]["reactions"])
    end

    def test_build_comments_no_activities_returns_empty
      assert_equal [], @pull.send(:build_comments, [], [])
    end

    # ── parse_command ─────────────────────────────────────────────────────────

    def test_parse_command_plan_without_feedback
      assert_equal [:plan, ""], @pull.send(:parse_command, "@chomper plan")
    end

    def test_parse_command_plan_with_feedback
      assert_equal [:plan, "also handle nil input"],
                   @pull.send(:parse_command, "@chomper plan also handle nil input")
    end

    def test_parse_command_fix_with_feedback
      assert_equal [:fix, "be careful"], @pull.send(:parse_command, "@chomper fix be careful")
    end

    def test_parse_command_approve
      assert_equal [:approve, nil], @pull.send(:parse_command, "@chomper approve")
    end

    def test_parse_command_free_text_is_chat
      assert_equal [:chat, "what about tests?"],
                   @pull.send(:parse_command, "@chomper what about tests?")
    end

    # OpenProject wraps the handle in CKEditor mention markup.
    MENTION = %q(<mention class="mention" data-id="557" data-type="user" data-text="🤖">@Chomper 🤖</mention>)

    def test_parse_command_handles_mention_markup_approve
      assert_equal [:approve, nil], @pull.send(:parse_command, "#{MENTION} approve")
    end

    def test_parse_command_handles_mention_markup_fix_with_feedback
      assert_equal [:fix, "be careful"], @pull.send(:parse_command, "#{MENTION} fix be careful")
    end

    def test_parse_command_handles_mention_markup_chat
      assert_equal [:chat, "what now?"], @pull.send(:parse_command, "#{MENTION} what now?")
    end

    def test_parse_command_handles_emoji_only_mention
      emoji_mention = %q(<mention class="mention" data-id="557" data-type="user" data-text="🤖">🤖</mention>)
      assert_equal [:plan, ""], @pull.send(:parse_command, "#{emoji_mention} plan")
    end
  end

  class PullCacheTest < Minitest::Test
    WP = {
      "id"        => 42,
      "subject"   => "Fix login bug",
      "createdAt" => "2024-01-01T00:00:00Z",
      "updatedAt" => "2024-01-02T00:00:00Z",
      "_embedded" => {
        "status"   => { "name" => "New" },
        "priority" => { "name" => "High" },
        "assignee" => { "name" => "Alice" },
        "author"   => { "name" => "Bob" },
        "version"  => { "name" => "17.5.0" },
        "category" => { "name" => "Core" }
      }
    }.freeze

    def setup
      @tmpdir = Dir.mktmpdir
      ctx = Struct.new(:op_url, :state_dir, :token).new("https://example.com", Pathname(@tmpdir), "tok")
      @pull = Pull.new(ctx)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_skips_api_calls_when_item_json_is_current
      item_dir = Pathname(@tmpdir) / "items" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-02T00:00:00Z" }))

      # WebMock raises if any HTTP call is made — no stubs registered
      cached, comments = @pull.send(:fetch_work_package_item, WP)
      assert cached
      assert_equal [], comments
    end

    def test_cached_item_returns_stored_comments
      stored_comments = [{ "user" => "Alice", "text" => "Reproduced on 14.3", "reactions" => { "thumbsup" => 2 } }]
      item_dir = Pathname(@tmpdir) / "items" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-02T00:00:00Z", "comments" => stored_comments }))

      _, comments = @pull.send(:fetch_work_package_item, WP)
      assert_equal stored_comments, comments
    end

    def test_re_fetches_when_updated_at_differs
      item_dir = Pathname(@tmpdir) / "items" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-01T00:00:00Z" }))

      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      cached, comments = @pull.send(:fetch_work_package_item, WP)
      refute cached
      assert_equal [], comments
      on_disk = JSON.parse((item_dir / "item.json").read)
      assert_equal "2024-01-02T00:00:00Z", on_disk["updated_at"]
    end

    def test_fetches_and_writes_when_no_item_json_exists
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      cached, comments = @pull.send(:fetch_work_package_item, WP)
      assert (Pathname(@tmpdir) / "items" / "42" / "item.json").exist?
      refute cached
      assert_equal [], comments
    end
  end

  class PullPollIntentsTest < Minitest::Test
    FILTERS = FilterSet.new(
      project_ids: ["123"],
      type_ids:    ["1"],
      status_ids:  ["2"],
      version_ids: []
    )

    def wp(id, updated_at)
      { "id" => id, "subject" => "Bug ##{id}", "updatedAt" => updated_at, "createdAt" => "2024-01-01T00:00:00Z" }
    end

    def page_response(wps, total:)
      JSON.generate({ "count" => wps.length, "total" => total, "_embedded" => { "elements" => wps } })
    end

    # Seed a cached item.json so fetch_work_package_item returns its comments
    # without any activities HTTP call.
    def seed_item(id, updated_at, comments)
      dir = Pathname(@tmpdir) / "items" / id.to_s
      dir.mkpath
      (dir / "item.json").write(JSON.generate({ "updated_at" => updated_at, "comments" => comments }))
    end

    def build_pull(allowed_emails = [])
      ctx = Struct.new(:op_url, :state_dir, :token, :allowed_emails)
                  .new("https://example.com", Pathname(@tmpdir), "tok", allowed_emails)
      Pull.new(ctx)
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @pull   = build_pull
      # /users/me identifies chomper as user 1, so an OP-native @-mention by
      # data-id is recognised as a trigger.
      stub_request(:get, "https://example.com/api/v3/users/me")
        .to_return(status: 200, body: JSON.generate({ "_links" => { "self" => { "href" => "/api/v3/users/1" } } }))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_fetch_single_item_returns_item_data
      seed_item(1, "2024-01-02T00:00:00Z", [])
      stub_request(:get, %r{/api/v3/work_packages/1\z})
        .to_return(status: 200, body: JSON.generate(wp(1, "2024-01-02T00:00:00Z")))
      item = @pull.fetch_single_item("1")
      assert_equal "2024-01-02T00:00:00Z", item["updated_at"]
    end

    def test_fetch_single_item_nil_when_wp_not_found
      stub_request(:get, %r{/api/v3/work_packages/404\z}).to_return(status: 404, body: "{}")
      assert_nil @pull.fetch_single_item("404")
    end

    def test_returns_empty_when_no_work_packages
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([], total: 0))
      assert_equal [], @pull.poll_intents(FILTERS)
    end

    def test_url_includes_sort_by_param
      stub_request(:get, /sortBy=/).to_return(status: 200, body: page_response([], total: 0))
      @pull.poll_intents(FILTERS)
    end

    def test_stops_paging_at_first_wp_below_scan_floor
      # Sorted updatedAt desc: WP 1 is above the floor, WP 2 below it. WP 2's
      # activities are deliberately left unstubbed — if the poll tried to fetch
      # it, WebMock would raise. So a clean run proves we stopped at the floor.
      filters = FilterSet.new(project_ids: ["123"], type_ids: ["1"],
                              status_ids: ["2"], version_ids: [],
                              scan_from_at: "2024-02-01T00:00:00Z")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response(
        [wp(1, "2024-03-01T00:00:00Z"), wp(2, "2024-01-01T00:00:00Z")], total: 2))
      stub_request(:get, %r{/work_packages/1/activities\z})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, %r{/work_packages/1/activities_emoji_reactions\z})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      assert_equal [], @pull.poll_intents(filters)
      assert_equal 1, @pull.scanned_count   # only WP 1 examined; stopped at WP 2
    end

    MENTION = %q(<mention class="mention" data-id="1" data-type="user" data-text="🤖">@Chomper 🤖</mention>)

    # An OP-native @-mention (made via the editor's picker) whose rendered handle
    # is a bare emoji — it carries chomper's data-id but no "@chomper" text.
    ID_MENTION = %q(<mention class="mention" data-id="1" data-type="user" data-text="🤖">🤖</mention>)

    def test_emits_intent_for_chomper_comment
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} plan watch the edges" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(FILTERS)
      assert_equal 1, intents.length
      assert_equal 1, @pull.scanned_count
      assert_equal 0, @pull.changed_count   # seeded item.json is current → cached
      assert_equal "1",                   intents[0].item_id
      assert_equal :plan,                 intents[0].command
      assert_equal "watch the edges",     intents[0].text
      assert_equal "2024-02-01T00:00:00Z", intents[0].comment_at
    end

    def test_drops_trigger_from_non_allowlisted_user
      @pull = build_pull(["allowed@example.com"])
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Mallory", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} fix it" }
      ])
      stub_request(:get, "https://example.com/api/v3/users/2")
        .to_return(status: 200, body: JSON.generate({ "email" => "mallory@example.com" }))
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      assert_equal [], @pull.poll_intents(FILTERS)
      # marked acted so it is not re-evaluated next poll
      on_disk = JSON.parse((Pathname(@tmpdir) / "items" / "1" / "item.json").read)
      assert_equal "2024-02-01T00:00:00Z", on_disk["last_acted_comment_at"]
    end

    def test_ignores_comment_recorded_as_chomper_reply
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Tom", "user_href" => "/api/v3/users/1",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "@chomper plan" }
      ])
      # Mark comment 9 as a chomper-generated reply.
      item_path = Pathname(@tmpdir) / "items" / "1" / "item.json"
      data = JSON.parse(item_path.read)
      data["last_chomper_comment_id"] = "9"
      item_path.write(JSON.generate(data))

      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(FILTERS)
    end

    def test_record_chomper_comment_persists_id
      seed_item(1, "2024-01-02T00:00:00Z", [])
      @pull.record_chomper_comment("1", "42")
      data = JSON.parse((Pathname(@tmpdir) / "items" / "1" / "item.json").read)
      assert_equal "42", data["last_chomper_comment_id"]
    end

    def test_record_chomper_comment_survives_item_refresh
      seed_item(1, "2024-01-02T00:00:00Z", [])
      @pull.record_chomper_comment("1", "42")
      # Simulate a re-fetch that rewrites item.json (updated_at changes).
      stub_request(:get, "https://example.com/api/v3/work_packages/1/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/1/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stale_wp = wp(1, "2024-01-02T00:00:00Z").merge("updatedAt" => "2024-03-01T00:00:00Z")
      @pull.send(:fetch_work_package_item, stale_wp)
      data = JSON.parse((Pathname(@tmpdir) / "items" / "1" / "item.json").read)
      assert_equal "42", data["last_chomper_comment_id"]
    end

    def test_emits_intent_for_plain_text_chomper_call
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "@Chomper plan watch the edges" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(FILTERS)
      assert_equal 1, intents.length
      assert_equal :plan, intents[0].command
    end

    def test_ignores_work_packages_without_a_trigger
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "just a normal comment" }
      ])
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(FILTERS)
    end

    def test_emits_intent_for_op_native_mention_without_literal_handle
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{ID_MENTION} plan watch the edges" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(FILTERS)
      assert_equal 1, intents.length
      assert_equal :plan,              intents[0].command
      assert_equal "watch the edges",  intents[0].text
    end

    def test_ignores_op_native_mention_of_a_different_user
      other = %q(<mention class="mention" data-id="2" data-type="user" data-text="Alice">@Alice</mention>)
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{other} please take a look" }
      ])
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(FILTERS)
    end

    def test_chomper_mentioned_recognises_op_native_mention_by_id
      assert @pull.send(:chomper_mentioned?, ID_MENTION)
      assert @pull.send(:chomper_mentioned?, "@chomper plan")
      refute @pull.send(:chomper_mentioned?, %q(<mention data-id="2">@Alice</mention> hi))
      refute @pull.send(:chomper_mentioned?, "just a normal comment")
    end

    def test_first_module_title_takes_first_of_multiple
      wp = { "_links" => { "customField5" => [
        { "title" => "Costs" }, { "title" => "Meetings" }
      ] } }
      assert_equal "Costs", @pull.send(:first_module_title, wp, "customField5")
    end

    def test_first_module_title_single_link
      wp = { "_links" => { "customField5" => [{ "title" => "Wiki" }] } }
      assert_equal "Wiki", @pull.send(:first_module_title, wp, "customField5")
    end

    def test_first_module_title_single_hash_link
      wp = { "_links" => { "customField5" => { "title" => "Wiki" } } }
      assert_equal "Wiki", @pull.send(:first_module_title, wp, "customField5")
    end

    def test_first_module_title_missing_field_is_empty
      assert_equal "", @pull.send(:first_module_title, { "_links" => {} }, "customField5")
    end

    def test_first_module_title_skips_nil_titles
      wp = { "_links" => { "customField5" => [
        { "title" => nil }, { "title" => "Backlogs" }
      ] } }
      assert_equal "Backlogs", @pull.send(:first_module_title, wp, "customField5")
    end

    def test_saved_backlog_filters_returns_saved_set_without_prompting
      named = FilterSet.new(project_ids: ["123"], project_idents: ["my-project"],
                            project_names: ["My Project"],
                            type_ids: ["1"], status_ids: ["2"],
                            version_ids: [], type_names: "bug", status_names: "new")
      @pull.send(:save_agent_filters, named)
      filters = nil
      # $stdin untouched: a reuse prompt would raise on read.
      capture_io { filters = @pull.saved_backlog_filters }
      assert_equal ["123"], filters.project_ids
      assert_equal ["1"],   filters.type_ids
    end

    def test_saved_backlog_filters_nil_when_nothing_saved
      assert_nil @pull.saved_backlog_filters
    end

    def test_filters_json_scopes_to_all_selected_projects
      filters = FilterSet.new(project_ids: ["10", "20"], type_ids: ["1"],
                              status_ids: ["2"], version_ids: [])
      clauses = JSON.parse(@pull.send(:filters_json, filters))
      project = clauses.find { |c| c.key?("project_id") }
      refute_nil project, "the query must carry a project_id filter"
      assert_equal "=",          project.dig("project_id", "operator")
      assert_equal ["10", "20"], project.dig("project_id", "values")
    end

    def test_read_saved_filters_upgrades_legacy_single_project
      # Pre-multi-project file: one identifier under "project_id". It must be
      # resolved to a numeric id (the project_id filter coerces values with to_i)
      # while keeping the semantic identifier for display.
      (Pathname(@tmpdir) / "op_agent_filters.json").write(JSON.generate(
        "project_id" => "TTP2", "project_name" => "Trial",
        "type_ids" => ["1"], "status_ids" => ["2"], "version_ids" => [],
        "type_names" => "bug", "status_names" => "new"
      ))
      stub_request(:get, "https://example.com/api/v3/projects/TTP2")
        .to_return(status: 200, body: JSON.generate({ "id" => 42, "identifier" => "ttp2", "name" => "Trial" }))

      filters = @pull.send(:read_saved_filters)
      assert_equal ["42"],    filters.project_ids
      assert_equal ["ttp2"],  filters.project_idents
      assert_equal ["Trial"], filters.project_names
    end

    def test_read_saved_filters_upgrades_multi_project_file_without_idents
      # A file written after multi-project support but before project_idents:
      # has project_ids but no project_idents. Each id is resolved to its
      # identifier on read so the display shows the semantic id.
      (Pathname(@tmpdir) / "op_agent_filters.json").write(JSON.generate(
        "project_ids" => ["1182"], "project_names" => ["Chomper testing area"],
        "type_ids" => ["7"], "status_ids" => ["1"], "version_ids" => [],
        "type_names" => "bug", "status_names" => "new"
      ))
      stub_request(:get, "https://example.com/api/v3/projects/1182")
        .to_return(status: 200, body: JSON.generate({ "id" => 1182, "identifier" => "chomper-testing", "name" => "Chomper testing area" }))

      filters = @pull.send(:read_saved_filters)
      assert_equal ["1182"],            filters.project_ids
      assert_equal ["chomper-testing"], filters.project_idents
    end

    def test_describe_filters_prefers_semantic_identifier
      filters = FilterSet.new(project_ids: ["1182"], project_idents: ["chomper-testing"],
                              project_names: ["Chomper testing area"], type_names: "bug",
                              status_names: "new")
      assert_includes @pull.send(:describe_filters, filters), "chomper-testing — Chomper testing area"
      refute_includes @pull.send(:describe_filters, filters), "1182"
    end

    def test_save_and_reload_agent_filters
      @pull.send(:save_agent_filters, FILTERS)
      path = Pathname(@tmpdir) / "op_agent_filters.json"
      assert path.exist?
      data = JSON.parse(path.read)
      assert_equal FILTERS.project_ids, data["project_ids"]
      assert_equal FILTERS.type_ids,    data["type_ids"]
      assert_equal FILTERS.status_ids,  data["status_ids"]
      assert_equal FILTERS.version_ids, data["version_ids"]
    end
  end
end
