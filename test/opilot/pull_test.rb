require_relative "../test_helper"

module OPilot
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

    def test_parse_command_build_with_feedback
      assert_equal [:ship, "be careful"], @pull.send(:parse_command, "@opilot build be careful")
    end

    def test_parse_command_build_without_feedback
      assert_equal [:ship, ""], @pull.send(:parse_command, "@opilot build")
    end

    # One alias, and only one.
    def test_parse_command_fix_is_the_alias
      assert_equal [:ship, "be careful"], @pull.send(:parse_command, "@opilot fix be careful")
    end

    # The words the build command replaced are no longer commands. They are
    # answered as chat, where the reply names the real one.
    def test_parse_command_retired_words_are_chat
      %w[ship prototype pr implement plan approve].each do |word|
        command, = @pull.send(:parse_command, "@opilot #{word} be careful")
        assert_equal :chat, command, "expected `@opilot #{word}` to be chat, not a command"
      end
    end

    # A word that merely starts with a command word is not the command (\b, not a
    # prefix match) — "building" is a sentence.
    def test_parse_command_build_needs_a_word_boundary
      assert_equal [:chat, "building on the last comment"],
                   @pull.send(:parse_command, "@opilot building on the last comment")
    end

    def test_parse_command_free_text_is_chat
      assert_equal [:chat, "what about tests?"],
                   @pull.send(:parse_command, "@opilot what about tests?")
    end

    # ── create wp ─────────────────────────────────────────────────────────────

    def test_parse_command_create_wp_carries_the_request
      assert_equal [:create_wp, "for Rosanna's suggestion"],
                   @pull.send(:parse_command, "@opilot create wp for Rosanna's suggestion")
    end

    def test_parse_command_create_work_package_is_the_long_form
      assert_equal [:create_wp, "for the toast idea"],
                   @pull.send(:parse_command, "@opilot create work package for the toast idea")
    end

    def test_parse_command_create_wp_without_a_request
      assert_equal [:create_wp, ""], @pull.send(:parse_command, "@opilot create wp")
    end

    # The noun is what makes it the command: `create` alone could mean a branch,
    # a PR, or a comment, so it stays chat.
    def test_parse_command_create_alone_is_chat
      command, = @pull.send(:parse_command, "@opilot create a branch for this")
      assert_equal :chat, command
    end

    # \b, not a prefix match — as with `build`/"building".
    def test_parse_command_create_wp_needs_a_word_boundary
      command, = @pull.send(:parse_command, "@opilot create wps for each of these")
      assert_equal :chat, command
    end

    def test_parse_command_create_wp_is_case_insensitive_with_mention_markup
      assert_equal [:create_wp, "for Rosanna"], @pull.send(:parse_command, "#{MENTION} Create WP for Rosanna")
    end

    # ── chat lenses ───────────────────────────────────────────────────────────

    def test_parse_command_grill_is_a_chat_with_the_lens_instruction
      command, text = @pull.send(:parse_command, "@opilot grill")
      assert_equal :chat, command
      assert_equal Prompts::LENSES["grill"], text
    end

    def test_parse_command_lens_folds_trailing_text_into_a_focus_hint
      command, text = @pull.send(:parse_command, "@opilot summarize the permissions discussion")
      assert_equal :chat, command
      assert text.start_with?(Prompts::LENSES["summarize"])
      assert_includes text, "Focus especially on: the permissions discussion"
    end

    def test_parse_command_lens_is_case_insensitive_and_handles_mention_markup
      command, text = @pull.send(:parse_command, "#{MENTION} GRILL")
      assert_equal :chat, command
      assert_equal Prompts::LENSES["grill"], text
    end

    # OpenProject wraps the handle in CKEditor mention markup.
    MENTION = %q(<mention class="mention" data-id="557" data-type="user" data-text="🤖">@OPilot 🤖</mention>)

    def test_parse_command_handles_mention_markup_build
      assert_equal [:ship, ""], @pull.send(:parse_command, "#{MENTION} build")
    end

    def test_parse_command_handles_mention_markup_build_with_feedback
      assert_equal [:ship, "be careful"], @pull.send(:parse_command, "#{MENTION} build be careful")
    end

    def test_parse_command_handles_mention_markup_chat
      assert_equal [:chat, "what now?"], @pull.send(:parse_command, "#{MENTION} what now?")
    end

    def test_parse_command_handles_emoji_only_mention
      emoji_mention = %q(<mention class="mention" data-id="557" data-type="user" data-text="🤖">🤖</mention>)
      assert_equal [:ship, ""], @pull.send(:parse_command, "#{emoji_mention} build")
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
      ctx = Struct.new(:op_url, :state_dir, :state_container, :token) { def op_host; "example.com"; end }
                  .new("https://example.com", Pathname(@tmpdir), "/state", "tok")
      @pull = Pull.new(ctx)
      # Every refreshed item.json mirrors the WP's pictures (ItemPictures), so
      # the fresh path always asks for the attachment collection.
      stub_request(:get, %r{/work_packages/[\w-]+/attachments\z})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_skips_api_calls_when_item_json_is_current
      item_dir = Pathname(@tmpdir) / "work_packages" / "example.com" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate(
        { "updated_at" => "2024-01-02T00:00:00Z", "item_version" => Pull::ITEM_VERSION }))

      # WebMock raises if any HTTP call is made — no stubs registered
      cached, comments = @pull.send(:fetch_work_package_item, WP)
      assert cached
      assert_equal [], comments
    end

    def test_cached_item_returns_stored_comments
      stored_comments = [{ "user" => "Alice", "text" => "Reproduced on 14.3", "reactions" => { "thumbsup" => 2 } }]
      item_dir = Pathname(@tmpdir) / "work_packages" / "example.com" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate(
        { "updated_at" => "2024-01-02T00:00:00Z", "item_version" => Pull::ITEM_VERSION,
          "comments" => stored_comments }))

      _, comments = @pull.send(:fetch_work_package_item, WP)
      assert_equal stored_comments, comments
    end

    def test_re_fetches_when_updated_at_differs
      item_dir = Pathname(@tmpdir) / "work_packages" / "example.com" / "42"
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

    # item.json is rebuilt from the API whenever the work package changes, so
    # opilot's own bookkeeping has to survive the rebuild. Both refusal markers
    # promise ONE comment per work package, ever — dropped on a refresh, that
    # becomes one comment per change, which a commenter can cause at will.
    def test_a_refresh_keeps_opilots_own_bookkeeping
      item_dir = Pathname(@tmpdir) / "work_packages" / "example.com" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate(
        "updated_at"                 => "2024-01-01T00:00:00Z",
        "subject"                    => "an old mirror of the subject",
        "last_acted_comment_at"      => "2024-01-01T10:00:00Z",
        "refusal_noted_at"           => "2024-01-01T11:00:00Z",
        "create_wp_refusal_noted_at" => "2024-01-01T12:00:00Z"
      ))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      @pull.send(:fetch_work_package_item, WP)

      on_disk = JSON.parse((item_dir / "item.json").read)
      Pull::CARRIED_KEYS.each do |key|
        refute_nil on_disk[key], "#{key} must survive a refresh"
      end
      assert_equal "Fix login bug", on_disk["subject"], "while the API mirror itself is rebuilt"
    end

    # The mirror's shape changes over time (pictures[] was the first addition).
    # Without a version beside updated_at, a work package opilot has already seen
    # keeps the old shape until somebody edits it — which for a quiet work
    # package is never.
    def test_re_fetches_an_item_written_on_an_older_shape
      item_dir = Pathname(@tmpdir) / "work_packages" / "example.com" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate({ "updated_at" => "2024-01-02T00:00:00Z" }))

      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      cached, = @pull.send(:fetch_work_package_item, WP)

      refute cached, "the same updated_at, but not the same shape"
      on_disk = JSON.parse((item_dir / "item.json").read)
      assert_equal Pull::ITEM_VERSION, on_disk["item_version"]
      assert_equal [], on_disk["pictures"]
    end

    # An attachment read that failed leaves the mirror incomplete, and
    # updated_at cannot notice: the work package itself did not change.
    def test_re_fetches_while_the_picture_mirror_is_incomplete
      item_dir = Pathname(@tmpdir) / "work_packages" / "example.com" / "42"
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate(
        { "updated_at" => "2024-01-02T00:00:00Z", "item_version" => Pull::ITEM_VERSION,
          "pictures" => [], "pictures_pending" => true }))

      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      cached, = @pull.send(:fetch_work_package_item, WP)

      refute cached
      on_disk = JSON.parse((item_dir / "item.json").read)
      refute on_disk["pictures_pending"], "the retry finished it"
    end

    # A refresh during an outage must not lose the pictures the last complete
    # run mirrored — the files are still on disk, and only this index names them.
    def test_a_failed_attachment_read_keeps_the_previous_picture_index
      item_dir = Pathname(@tmpdir) / "work_packages" / "example.com" / "42"
      item_dir.mkpath
      known = [{ "id" => "7", "file" => "/state/work_packages/example.com/42/pictures/7-shot.png" }]
      (item_dir / "item.json").write(JSON.generate(
        { "updated_at" => "2024-01-01T00:00:00Z", "item_version" => Pull::ITEM_VERSION,
          "pictures" => known }))

      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/attachments")
        .to_return(status: 503, body: "{}")

      @pull.send(:fetch_work_package_item, WP)

      on_disk = JSON.parse((item_dir / "item.json").read)
      assert_equal known, on_disk["pictures"]
      assert on_disk["pictures_pending"]
    end

    # The mirror rewrites a picture's URL in the comments it returns, so the two
    # branches have to hand back the same text.
    def test_returns_the_mirrored_comments
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [
          { "id" => 9, "createdAt" => "2024-01-02T00:00:00Z",
            "comment" => { "raw" => "look: ![](/api/v3/attachments/7/content)" },
            "_links" => { "user" => { "href" => "/api/v3/users/2", "title" => "Bob" } } }
        ] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/attachments")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [
          { "id" => 7, "fileName" => "shot.png", "contentType" => "image/png", "fileSize" => 3,
            "_links" => { "downloadLocation" => { "href" => "/api/v3/attachments/7/content" } } }
        ] } }))
      stub_request(:get, "https://example.com/api/v3/attachments/7/content")
        .to_return(status: 200, body: "png")

      _, comments = @pull.send(:fetch_work_package_item, WP)

      assert_equal "look: ![](/state/work_packages/example.com/42/pictures/7-shot.png)",
                   comments.first["text"]
    end

    def test_fetches_and_writes_when_no_item_json_exists
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/42/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      cached, comments = @pull.send(:fetch_work_package_item, WP)
      assert (Pathname(@tmpdir) / "work_packages" / "example.com" / "42" / "item.json").exist?
      refute cached
      assert_equal [], comments
    end
  end

  class PullPollIntentsTest < Minitest::Test
    def wp(id, updated_at)
      { "id" => id, "subject" => "Bug ##{id}", "updatedAt" => updated_at, "createdAt" => "2024-01-01T00:00:00Z" }
    end

    def page_response(wps, total:)
      JSON.generate({ "count" => wps.length, "total" => total, "_embedded" => { "elements" => wps } })
    end

    # Seed a cached item.json so fetch_work_package_item returns its comments
    # without any activities HTTP call.
    def seed_item(id, updated_at, comments, extra: {})
      dir = Pathname(@tmpdir) / "work_packages" / "example.com" / id.to_s
      dir.mkpath
      (dir / "item.json").write(JSON.generate(
        { "updated_at" => updated_at, "item_version" => Pull::ITEM_VERSION,
          "comments" => comments }.merge(extra)
      ))
    end

    # Collect the comment bodies opilot posts during a poll (the refusal note is
    # the only one Pull itself posts; every other note comes from the Agent).
    def capture_notes
      notes = []
      stub_request(:post, %r{/work_packages/\d+/activities}).to_return do |req|
        notes << JSON.parse(req.body).dig("comment", "raw")
        { status: 201, body: "{}" }
      end
      notes
    end

    def build_pull(allowed_op_user_ids = [])
      ctx = Struct.new(:op_url, :state_dir, :state_container, :token, :allowed_op_user_ids) do
        def op_host; "example.com"; end
      end.new("https://example.com", Pathname(@tmpdir), "/state", "tok", allowed_op_user_ids)
      Pull.new(ctx)
    end

    def setup
      @tmpdir = Dir.mktmpdir
      @pull   = build_pull
      # The per-instance WP dir holds op_agent_scan.json; tests that seed that
      # file write it directly, so make sure its parent exists.
      (Pathname(@tmpdir) / "work_packages" / "example.com").mkpath
      # /users/me identifies opilot as user 1 with display name "OPilot" — the
      # id lets an OP-native @-mention be recognised by data-id, the name is
      # the poll's own search term (see #mention_filter_json).
      # Every refreshed item.json mirrors the WP's pictures (ItemPictures), so
      # the fresh path always asks for the attachment collection.
      stub_request(:get, %r{/work_packages/[\w-]+/attachments\z})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/users/me")
        .to_return(status: 200, body: JSON.generate(
          { "_links" => { "self" => { "href" => "/api/v3/users/1" } }, "name" => "OPilot" }))
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
      assert_equal [], @pull.poll_intents(nil)
    end

    def test_url_includes_sort_by_param
      stub_request(:get, /sortBy=/).to_return(status: 200, body: page_response([], total: 0))
      @pull.poll_intents(nil)
    end

    # Scanning a parent project should also cover its child projects' WPs.
    def test_url_includes_subprojects_param
      stub_request(:get, /includeSubprojects=true/).to_return(status: 200, body: page_response([], total: 0))
      @pull.poll_intents(nil)
    end

    def test_stops_paging_at_first_wp_below_scan_floor
      # Sorted updatedAt desc: WP 1 is above the floor, WP 2 below it. WP 2's
      # activities are deliberately left unstubbed — if the poll tried to fetch
      # it, WebMock would raise. So a clean run proves we stopped at the floor.
      scan_from_at = "2024-02-01T00:00:00Z"
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response(
        [wp(1, "2024-03-01T00:00:00Z"), wp(2, "2024-01-01T00:00:00Z")], total: 2))
      stub_request(:get, %r{/work_packages/1/activities\z})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, %r{/work_packages/1/activities_emoji_reactions\z})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))

      assert_equal [], @pull.poll_intents(scan_from_at)
      assert_equal 1, @pull.scanned_count   # only WP 1 examined; stopped at WP 2
    end

    MENTION = %q(<mention class="mention" data-id="1" data-type="user" data-text="🤖">@OPilot 🤖</mention>)

    # An OP-native @-mention (made via the editor's picker) whose rendered handle
    # is a bare emoji — it carries opilot's data-id but no "@opilot" text.
    ID_MENTION = %q(<mention class="mention" data-id="1" data-type="user" data-text="🤖">🤖</mention>)

    def test_emits_intent_for_opilot_comment
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} build watch the edges" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(nil)
      assert_equal 1, intents.length
      assert_equal 1, @pull.scanned_count
      assert_equal 0, @pull.changed_count   # seeded item.json is current → cached
      assert_equal "1",                   intents[0].item_id
      assert_equal :ship,                 intents[0].command
      assert_equal "watch the edges",     intents[0].text
      assert_equal "2024-02-01T00:00:00Z", intents[0].comment_at
    end

    def test_drops_trigger_from_non_allowlisted_user
      # Comment author is user id 2 (from user_href); allowlist only permits 1.
      @pull = build_pull(["1"])
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Mallory", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} fix it" }
      ])
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      notes = capture_notes

      assert_equal [], @pull.poll_intents(nil)
      # marked acted so it is not re-evaluated next poll
      on_disk = JSON.parse((Pathname(@tmpdir) / "work_packages" / "example.com" / "1" / "item.json").read)
      assert_equal "2024-02-01T00:00:00Z", on_disk["last_acted_comment_at"]
      # …and the commenter is told once, rather than left with silence
      assert_equal 1, notes.length
      assert_includes notes.first, "allowlist"
      assert_includes notes.first, "Mallory"
      assert on_disk["refusal_noted_at"], "the refusal must be marked so it is said only once"
    end

    def test_refusal_note_is_posted_only_once_per_work_package
      @pull = build_pull(["1"])
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Mallory", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} fix it" }
      ], extra: { "refusal_noted_at" => "2024-01-03T00:00:00Z" })
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      notes = capture_notes

      assert_equal [], @pull.poll_intents(nil)
      assert_empty notes, "a second rejected trigger must not add another comment"
    end

    def test_emits_trigger_from_allowlisted_user_id
      # Comment author is user id 2 (from user_href), which the allowlist permits.
      @pull = build_pull(["2"])
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} fix it" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(nil)
      assert_equal 1, intents.length
      assert_equal "1", intents[0].item_id
    end

    # opilot is user 1 on this instance (the /users/me stub in #setup), so a
    # comment authored by user 1 is one opilot wrote. It must never be read back
    # as a trigger, however loudly its text asks — opilot's own comments quote
    # the command word all the time (#post_options tells the reader to reply
    # "@opilot build 1").
    def test_ignores_a_comment_opilot_wrote_itself
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "OPilot", "user_href" => "/api/v3/users/1",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "Reply `@opilot build 1` to build option 1." }
      ])
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(nil)
    end

    # The case the old one-deep id guard missed. A handler that posts TWO
    # comments (#post_approach_note, then the pull-request links) recorded only
    # the second id, and both sit above the cutoff, because opilot always
    # replies after the trigger it answers. The author guard covers every one of
    # them, no matter how many there are.
    def test_ignores_every_opilot_comment_not_just_the_last
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{MENTION} build" },
        { "id" => "10", "user" => "OPilot", "user_href" => "/api/v3/users/1",
          "created_at" => "2024-02-01T00:01:00Z", "text" => "I will implement this. Reply `@opilot build 2` to change it." },
        { "id" => "11", "user" => "OPilot", "user_href" => "/api/v3/users/1",
          "created_at" => "2024-02-01T00:02:00Z", "text" => "Here is your prototype: https://example.invalid/pr/1" }
      ], extra: { "last_acted_comment_at" => "2024-02-01T00:00:00Z" })
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(nil)
    end

    # A comment from a real user is still a trigger when opilot's own replies
    # sit around it — the guard must exclude opilot, not silence the thread.
    def test_still_triggers_on_a_user_comment_after_an_opilot_reply
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "10", "user" => "OPilot", "user_href" => "/api/v3/users/1",
          "created_at" => "2024-02-01T00:01:00Z", "text" => "Reply `@opilot build 1` to build option 1." },
        { "id" => "11", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:02:00Z", "text" => "#{MENTION} build 1" }
      ])
      stub_request(:patch, %r{/activities/11/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(nil)
      assert_equal 1, intents.length
      assert_equal :ship, intents[0].command
      assert_equal "1",   intents[0].text
    end

    def test_emits_intent_for_plain_text_opilot_call
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "@OPilot build watch the edges" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(nil)
      assert_equal 1, intents.length
      assert_equal :ship, intents[0].command
    end

    def test_ignores_work_packages_without_a_trigger
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "just a normal comment" }
      ])
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(nil)
    end

    def test_emits_intent_for_op_native_mention_without_literal_handle
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{ID_MENTION} build watch the edges" }
      ])
      stub_request(:patch, %r{/activities/9/emoji_reactions}).to_return(status: 200, body: "{}")
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))

      intents = @pull.poll_intents(nil)
      assert_equal 1, intents.length
      assert_equal :ship,              intents[0].command
      assert_equal "watch the edges",  intents[0].text
    end

    def test_ignores_op_native_mention_of_a_different_user
      other = %q(<mention class="mention" data-id="2" data-type="user" data-text="Alice">@Alice</mention>)
      seed_item(1, "2024-01-02T00:00:00Z", [
        { "id" => "9", "user" => "Bob", "user_href" => "/api/v3/users/2",
          "created_at" => "2024-02-01T00:00:00Z", "text" => "#{other} please take a look" }
      ])
      stub_request(:get, /offset=1/).to_return(status: 200, body: page_response([wp(1, "2024-01-02T00:00:00Z")], total: 1))
      assert_equal [], @pull.poll_intents(nil)
    end

    def test_opilot_mentioned_recognises_op_native_mention_by_id
      assert @pull.send(:opilot_mentioned?, ID_MENTION)
      assert @pull.send(:opilot_mentioned?, "@opilot build")
      refute @pull.send(:opilot_mentioned?, %q(<mention data-id="2">@Alice</mention> hi))
      refute @pull.send(:opilot_mentioned?, "just a normal comment")
    end

    # The poll's own query: one `comment` clause (`~`, contains) keyed on
    # opilot's real OpenProject display name (stubbed as "OPilot" in #setup).
    def test_mention_filter_json_scopes_on_the_bot_display_name
      clauses = JSON.parse(@pull.send(:mention_filter_json))
      assert_equal [{ "comment" => { "operator" => "~", "values" => ["OPilot"] } }], clauses
    end

    # There is no project-scope fallback left underneath the search, so a
    # failed identity lookup must stop the poll rather than send a
    # malformed/empty filter value — and it must fail before ever touching the
    # work-packages endpoint.
    def test_poll_intents_raises_when_the_bot_identity_cannot_be_resolved
      stub_request(:get, "https://example.com/api/v3/users/me").to_return(status: 500, body: "{}")
      assert_raises(OPilot::FatalError) { @pull.poll_intents(nil) }
    end

    # The user id is required too, not only the display name: without it
    # #own_comment? silently stops recognising opilot's own comments, and opilot
    # can read its own text back as a trigger. A response carrying a name but no
    # self link must therefore fail as loudly as no response at all.
    def test_poll_intents_raises_when_only_the_bot_user_id_is_missing
      stub_request(:get, "https://example.com/api/v3/users/me")
        .to_return(status: 200, body: JSON.generate({ "name" => "OPilot" }))
      error = assert_raises(OPilot::FatalError) { @pull.poll_intents(nil) }
      # The "no <half>" clause names which half is missing; the sentence after it
      # explains what both halves are for, so only the clause is asserted here.
      assert_includes error.message, "no user id."
      refute_includes error.message, "no display name"
    end
  end

  class PullRelatedTest < Minitest::Test
    def setup
      @tmpdir = Dir.mktmpdir
      ctx = Struct.new(:op_url, :state_dir, :state_container, :token, :allowed_op_user_ids) { def op_host; "example.com"; end }
                  .new("https://example.com", Pathname(@tmpdir), "/state", "tok", [])
      @pull = Pull.new(ctx)
      # Every refreshed item.json mirrors the WP's pictures (ItemPictures), so
      # the fresh path always asks for the attachment collection.
      stub_request(:get, %r{/work_packages/[\w-]+/attachments\z})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def wp_body(id, status: "New", links: {})
      {
        "id" => id, "subject" => "WP #{id}",
        "createdAt" => "2024-01-01T00:00:00Z", "updatedAt" => "2024-01-02T00:00:00Z",
        "_embedded" => { "status" => { "name" => status }, "type" => { "name" => "Bug" } },
        "_links" => links
      }
    end

    # Stub the three GETs fetch_single_item makes for one WP.
    def stub_full_wp(id, status: "New", code: 200)
      stub_request(:get, "https://example.com/api/v3/work_packages/#{id}")
        .to_return(status: code, body: code == 200 ? JSON.generate(wp_body(id, status: status)) : "{}")
      return unless code == 200
      stub_request(:get, "https://example.com/api/v3/work_packages/#{id}/activities")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
      stub_request(:get, "https://example.com/api/v3/work_packages/#{id}/activities_emoji_reactions")
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => [] } }))
    end

    def rel(from:, to:, type:, reverse:)
      { "type" => type, "reverseType" => reverse,
        "_links" => { "from" => { "href" => "/api/v3/work_packages/#{from}" },
                      "to"   => { "href" => "/api/v3/work_packages/#{to}" } } }
    end

    def stub_relations(*rels)
      stub_request(:get, %r{/api/v3/relations})
        .to_return(status: 200, body: JSON.generate({ "_embedded" => { "elements" => rels } }))
    end

    # Stub the pinged WP (id 100) with the given _links; never fetched as a related item.
    def stub_pinged(links)
      stub_request(:get, "https://example.com/api/v3/work_packages/100")
        .to_return(status: 200, body: JSON.generate(wp_body(100, links: links)))
    end

    def test_gathers_relations_and_hierarchy_with_correct_labels
      stub_pinged("parent"   => { "href" => "/api/v3/work_packages/50" },
                  "children" => [{ "href" => "/api/v3/work_packages/60" }])
      stub_relations(
        rel(from: 100, to: 200, type: "relates", reverse: "relates"),  # pinged is `from` → type
        rel(from: 300, to: 100, type: "blocks",  reverse: "blocked")   # pinged is `to`   → reverseType
      )
      [200, 300, 50, 60].each { |id| stub_full_wp(id) }

      refs  = @pull.related_work_packages("100")
      by_id = refs.to_h { |r| [r["id"], r["relation"]] }
      assert_equal "relates", by_id["200"]
      assert_equal "blocked", by_id["300"]
      assert_equal "parent",  by_id["50"]
      assert_equal "child",   by_id["60"]
      assert (Pathname(@tmpdir) / "work_packages" / "example.com" / "200" / "item.json").exist?, "related WPs are cached to disk"
      assert_equal "New", refs.find { |r| r["id"] == "200" }["status"]
    end

    def test_unreachable_related_wps_are_skipped_without_leaking
      stub_pinged("children" => [{ "href" => "/api/v3/work_packages/60" },
                                 { "href" => "/api/v3/work_packages/70" }])
      stub_relations(rel(from: 100, to: 200, type: "relates", reverse: "relates"))
      stub_full_wp(60)                 # reachable
      stub_full_wp(70, code: 403)      # forbidden
      stub_full_wp(200, code: 404)     # not found

      refs = @pull.related_work_packages("100")
      ids  = refs.map { |r| r["id"] }
      assert_equal ["60"], ids, "only the reachable child survives"
      refute (Pathname(@tmpdir) / "work_packages" / "example.com" / "70" / "item.json").exist?
    end

    def test_relations_endpoint_failure_still_yields_hierarchy
      stub_pinged("parent" => { "href" => "/api/v3/work_packages/50" })
      stub_request(:get, %r{/api/v3/relations}).to_return(status: 403, body: "{}")
      stub_full_wp(50)

      refs = @pull.related_work_packages("100")
      assert_equal [["50", "parent"]], refs.map { |r| [r["id"], r["relation"]] }
    end

    def test_returns_empty_when_pinged_wp_unfetchable
      stub_request(:get, "https://example.com/api/v3/work_packages/100").to_return(status: 404, body: "{}")
      assert_equal [], @pull.related_work_packages("100")
    end

    def test_caps_related_work_packages_and_logs
      children = (1..20).map { |n| { "href" => "/api/v3/work_packages/#{n}" } }
      stub_pinged("children" => children)
      stub_relations
      (1..20).each { |id| stub_full_wp(id) }

      refs = nil
      out, = capture_io { refs = @pull.related_work_packages("100") }
      assert_equal Pull::MAX_RELATED, refs.length
      assert_match(/using the first #{Pull::MAX_RELATED}/, out)
    end
  end
end
