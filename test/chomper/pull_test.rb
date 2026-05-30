require_relative "../test_helper"

module Chomper
  class PullTest < Minitest::Test
    def setup
      ctx = Struct.new(:op_url).new("https://example.com")
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
      project_id:  "my-project",
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
      # /users/me drives own-comment filtering; chomper is user 1.
      stub_request(:get, "https://example.com/api/v3/users/me")
        .to_return(status: 200, body: JSON.generate({ "_links" => { "self" => { "href" => "/api/v3/users/1" } } }))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_returns_empty_when_no_work_packages
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([], total: 0))
      assert_equal [], @pull.poll_intents(FILTERS)
    end

    def test_url_includes_sort_by_param
      stub_request(:get, /sortBy=/).to_return(status: 200, body: page_response([], total: 0))
      @pull.poll_intents(FILTERS)
    end

    # chomper is user 1 (per the /users/me stub); a trigger is a mention of it.
    MENTION = %q(<mention class="mention" data-id="1" data-type="user" data-text="🤖">@Chomper 🤖</mention>)

    def test_emits_intent_for_chomper_comment
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} plan watch the edges" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(FILTERS)
      assert_equal 1, intents.length
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

    def test_ignores_work_packages_without_a_trigger
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "just a normal comment" }
      ])
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(FILTERS)
    end

    def test_save_and_reload_agent_filters
      @pull.send(:save_agent_filters, FILTERS)
      path = Pathname(@tmpdir) / "agent_filters.json"
      assert path.exist?
      data = JSON.parse(path.read)
      assert_equal FILTERS.project_id,  data["project_id"]
      assert_equal FILTERS.type_ids,    data["type_ids"]
      assert_equal FILTERS.status_ids,  data["status_ids"]
      assert_equal FILTERS.version_ids, data["version_ids"]
    end
  end
end
