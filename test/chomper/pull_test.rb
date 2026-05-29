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
      result, cached = @pull.send(:fetch_work_package_item, WP)
      assert_equal "42", result["id"]
      assert_equal Backlog::STATE_PENDING, result["state"]
      assert cached
    end

    def test_re_fetches_when_updated_at_differs
      item_dir = Pathname(@tmpdir) / "items" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-01T00:00:00Z" }))

      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      result, cached = @pull.send(:fetch_work_package_item, WP)
      assert_equal "42", result["id"]
      refute cached
      on_disk = JSON.parse((item_dir / "item.json").read)
      assert_equal "2024-01-02T00:00:00Z", on_disk["updated_at"]
    end

    def test_fetches_and_writes_when_no_item_json_exists
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      _, cached = @pull.send(:fetch_work_package_item, WP)
      assert (Pathname(@tmpdir) / "items" / "42" / "item.json").exist?
      refute cached
    end
  end
end
