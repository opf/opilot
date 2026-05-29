require_relative "../test_helper"

module Chomper
  class PullTest < Minitest::Test
    def setup
      ctx = Struct.new(:op_url).new("https://example.com")
      @pull = Pull.new(ctx, nil)
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

    def test_build_full_item_has_no_scoring_fields
      item = @pull.send(:build_full_item, WP, [])
      refute item.key?("locality_group")
      refute item.key?("complexity")
      refute item.key?("files_touched")
      refute item.key?("ai_category")
    end

    def test_build_backlog_entry_contains_pointer_and_scoring_fields
      item = @pull.send(:build_backlog_entry, WP)
      assert_equal %w[ai_category complexity files_touched id locality_group state subject url],
                   item.keys.sort
    end

    def test_build_backlog_entry_defaults_state_to_pending
      item = @pull.send(:build_backlog_entry, WP)
      assert_equal Backlog::STATE_PENDING, item["state"]
    end

    def test_build_backlog_entry_has_no_metadata_fields
      item = @pull.send(:build_backlog_entry, WP)
      refute item.key?("description")
      refute item.key?("comments")
      refute item.key?("status")
      refute item.key?("assignee")
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

    def test_build_comments_empty_reactions_for_unmatched_activity
      activities = [
        { "id" => 9, "comment" => { "raw" => "Hi" }, "_embedded" => { "user" => { "name" => "A" } }, "createdAt" => "t" }
      ]
      result = @pull.send(:build_comments, activities, [])
      assert_equal({}, result[0]["reactions"])
    end

    def test_build_comments_no_activities_returns_empty
      assert_equal [], @pull.send(:build_comments, [], [])
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
      @pull = Pull.new(ctx, nil)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_skips_api_calls_when_item_json_is_current
      item_dir = Pathname(@tmpdir) / "items" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-02T00:00:00Z" }))

      # WebMock raises if any HTTP call is made — no stubs registered
      result, cached, comments = @pull.send(:fetch_work_package_item, WP)
      assert_equal "42", result["id"]
      assert_equal Backlog::STATE_PENDING, result["state"]
      assert cached
      assert_equal [], comments
    end

    def test_cached_item_returns_stored_comments
      stored_comments = [{ "user" => "Alice", "text" => "Reproduced on 14.3", "reactions" => { "thumbsup" => 2 } }]
      item_dir = Pathname(@tmpdir) / "items" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-02T00:00:00Z", "comments" => stored_comments }))

      _, _, comments = @pull.send(:fetch_work_package_item, WP)
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

      result, cached, comments = @pull.send(:fetch_work_package_item, WP)
      assert_equal "42", result["id"]
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

      _, cached, comments = @pull.send(:fetch_work_package_item, WP)
      assert (Pathname(@tmpdir) / "items" / "42" / "item.json").exist?
      refute cached
      assert_equal [], comments
    end
  end

  class PullAgentPollTest < Minitest::Test
    FILTERS = FilterSet.new(
      project_id:  "my-project",
      type_ids:    ["1"],
      status_ids:  ["2"],
      version_ids: []
    )

    def wp(id, updated_at)
      {
        "id"        => id,
        "subject"   => "Bug ##{id}",
        "updatedAt" => updated_at,
        "createdAt" => "2024-01-01T00:00:00Z",
        "_embedded" => {
          "status"   => { "name" => "New" },
          "priority" => { "name" => "Normal" },
          "assignee" => nil,
          "author"   => { "name" => "Alice" },
          "version"  => nil,
          "category" => nil
        }
      }
    end

    def page_response(wps, total:)
      JSON.generate({
        "count"     => wps.length,
        "total"     => total,
        "_embedded" => { "elements" => wps }
      })
    end

    def stub_activities(id)
      stub_request(:get, "https://example.com/api/v3/work_packages/#{id}/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/#{id}/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
    end

    def setup
      @tmpdir  = Dir.mktmpdir
      ctx      = Struct.new(:op_url, :state_dir, :token).new("https://example.com", Pathname(@tmpdir), "tok")
      @backlog = Backlog.new(Pathname(@tmpdir) / "backlog.json")
      @pull    = Pull.new(ctx, @backlog)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_url_includes_sort_by_param
      # Stub only matches URLs containing sortBy= — WebMock raises if it's absent
      stub_request(:get, /sortBy=/).to_return(
        status: 200,
        body: page_response([], total: 0)
      )
      @pull.run_agent_poll(FILTERS)
    end

    def test_stops_early_when_all_cached
      w1 = wp(1, "2024-01-02T00:00:00Z")
      w2 = wp(2, "2024-01-01T00:00:00Z")
      [w1, w2].each do |w|
        dir = Pathname(@tmpdir) / "items" / w["id"].to_s
        dir.mkpath
        (dir / "item.json").write(JSON.generate({ "updated_at" => w["updatedAt"] }))
      end

      stub_request(:get, /offset=1/).to_return(
        status: 200,
        body: page_response([w1, w2], total: 100)
      )
      # No stub for page 2 — WebMock raises if it's requested

      @pull.run_agent_poll(FILTERS)
    end

    def test_continues_when_page_has_uncached_item
      w1 = wp(1, "2024-01-03T00:00:00Z")  # uncached
      w2 = wp(2, "2024-01-02T00:00:00Z")  # cached

      dir = Pathname(@tmpdir) / "items" / "2"
      dir.mkpath
      (dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-02T00:00:00Z" }))

      stub_activities(1)

      w3 = wp(3, "2024-01-01T12:00:00Z")  # cached
      w4 = wp(4, "2024-01-01T00:00:00Z")  # cached
      [w3, w4].each do |w|
        dir = Pathname(@tmpdir) / "items" / w["id"].to_s
        dir.mkpath
        (dir / "item.json").write(JSON.generate({ "updated_at" => w["updatedAt"] }))
      end

      stub_request(:get, /offset=1/).to_return(
        status: 200,
        body: page_response([w1, w2], total: 4)
      )
      stub_request(:get, /offset=2/).to_return(
        status: 200,
        body: page_response([w3, w4], total: 4)
      )
      # No stub for page 3 — would raise if fetched

      @pull.run_agent_poll(FILTERS)

      assert_requested :get, /offset=2/
    end

    def test_skips_merge_when_no_items_match
      stub_request(:get, /offset=1/).to_return(
        status: 200,
        body: JSON.generate({ "count" => 0, "total" => 0, "_embedded" => { "elements" => [] } })
      )

      @pull.run_agent_poll(FILTERS)

      refute (Pathname(@tmpdir) / "backlog.json").exist?
    end

    def test_save_and_load_agent_filters
      @pull.send(:save_agent_filters, FILTERS)
      assert (Pathname(@tmpdir) / "agent_filters.json").exist?

      loaded = @pull.load_or_prompt_agent_filters
      assert_equal FILTERS.project_id,  loaded.project_id
      assert_equal FILTERS.type_ids,    loaded.type_ids
      assert_equal FILTERS.status_ids,  loaded.status_ids
      assert_equal FILTERS.version_ids, loaded.version_ids
    end
  end
end
