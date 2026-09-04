require_relative "../test_helper"
require "tmpdir"

module OPilot
  class ItemPicturesTest < Minitest::Test
    # Stands in for Clients::OpenProject. `attached` is the work package's own
    # attachment collection; `standalone` is what only a by-id read answers for
    # — a picture pasted into a comment, which the collection never carries.
    class FakeOP
      attr_reader :downloads, :by_id_reads

      def initialize(attached: [], standalone: {}, collection_code: 200,
                     by_id_code: 404, download_code: 404)
        @attached        = attached
        @standalone      = standalone
        @collection_code = collection_code
        @by_id_code      = by_id_code      # when the id is not known
        @download_code   = download_code   # when the bytes are not there
        @downloads       = []
        @by_id_reads     = []
      end

      def work_package_attachments(_wp_id)
        return [@collection_code, nil] unless @collection_code == 200
        [200, { "_embedded" => { "elements" => @attached } }]
      end

      def attachment(id)
        @by_id_reads << id.to_s
        meta = @standalone[id.to_s]
        meta ? [200, meta] : [@by_id_code, nil]
      end

      def download_attachment(url)
        @downloads << url
        bytes = (@attached + @standalone.values)
                .find { |a| a.dig("_links", "downloadLocation", "href") == url }
                &.fetch("__bytes", nil)
        bytes ? [200, bytes] : [@download_code, nil]
      end
    end

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @ctx    = Context.build(@tmpdir)
      @dir    = @tmpdir / ".opilot" / "work_packages" / "op.test" / "42"
      @dir.mkpath
    end

    def teardown
      FileUtils.remove_entry(@tmpdir)
    end

    def attachment(id, name: "shot.png", type: "image/png", bytes: "\x89PNG-data",
                   href: nil, size: nil)
      { "id" => id, "fileName" => name, "contentType" => type,
        "fileSize" => size || bytes.to_s.bytesize,
        "_links" => { "downloadLocation" => { "href" => href || "https://op.test/dl/#{id}" } },
        "__bytes" => bytes }
    end

    def item(description: "", comments: [])
      { "id" => "42", "description" => description, "comments" => comments }
    end

    def mirror(item, api)
      ItemPictures.mirror(item, dir: @dir, api: api, ctx: @ctx)
    end

    def ref(id)
      "/api/v3/attachments/#{id}/content"
    end

    # --- the download -------------------------------------------------------

    def test_a_picture_in_the_description_is_written_next_to_the_item
      api = FakeOP.new(attached: [attachment("7")])
      out = mirror(item(description: "before\n![](#{ref(7)})\nafter"), api)

      assert_equal 1, out["pictures"].length
      picture = out["pictures"].first
      assert_equal "/state/work_packages/op.test/42/pictures/7-shot.png", picture["file"],
                   "the path the LLM reads is the container path, not the host one"
      assert_equal "description", picture["where"]
      assert_equal "\x89PNG-data".b, (@dir / "pictures" / "7-shot.png").binread
    end

    def test_the_inline_reference_is_rewritten_to_the_local_file
      # The half that makes a picture readable rather than merely present: the
      # harness has no egress, so the URL is dead either way.
      api = FakeOP.new(attached: [attachment("7")])
      out = mirror(item(description: "see ![](#{ref(7)}) here"), api)

      assert_equal "see ![](/state/work_packages/op.test/42/pictures/7-shot.png) here",
                   out["description"]
    end

    def test_an_absolute_picture_url_is_rewritten_whole
      # The editor writes the bare path, but people paste full URLs. Rewriting
      # only the path would leave "https://op.test" in front of a local file.
      api = FakeOP.new(attached: [attachment("7")])
      out = mirror(item(description: "![](https://op.test#{ref(7)})"), api)

      assert_equal "![](/state/work_packages/op.test/42/pictures/7-shot.png)", out["description"]
      assert_equal 1, out["pictures"].length
    end

    def test_a_reference_in_a_comment_is_rewritten_too
      api = FakeOP.new(standalone: { "9" => attachment("9", name: "err.png") })
      out = mirror(item(comments: [{ "id" => "5", "text" => "look: ![](#{ref(9)})" }]), api)

      assert_equal "look: ![](/state/work_packages/op.test/42/pictures/9-err.png)",
                   out["comments"].first["text"]
      assert_equal "comment 5", out["pictures"].first["where"]
    end

    def test_a_comments_picture_is_read_by_id_because_the_collection_lacks_it
      # OpenProject claims a pasted comment image for the COMMENT, so the work
      # package's own collection never carries it.
      api = FakeOP.new(standalone: { "9" => attachment("9") })
      out = mirror(item(comments: [{ "id" => "5", "text" => "![](#{ref(9)})" }]), api)

      assert_equal ["9"], api.by_id_reads
      assert_equal 1, out["pictures"].length
    end

    def test_a_picture_already_in_the_collection_costs_no_by_id_read
      api = FakeOP.new(attached: [attachment("7")])
      mirror(item(description: "![](#{ref(7)})"), api)

      assert_empty api.by_id_reads, "the collection already answered"
    end

    def test_an_attachment_nobody_inlined_is_mirrored_as_attached
      api = FakeOP.new(attached: [attachment("7")])
      out = mirror(item(description: "no picture here"), api)

      assert_equal "attached", out["pictures"].first["where"]
      assert_equal "no picture here", out["description"], "nothing to rewrite"
    end

    def test_a_relative_download_location_is_passed_through_untouched
      # The client resolves it against the instance base; this only checks the
      # mirror hands over what the API said, rather than building a URL.
      api = FakeOP.new(attached: [attachment("7", href: ref(7))])
      mirror(item(description: "![](#{ref(7)})"), api)

      assert_equal [ref(7)], api.downloads
    end

    # --- what is not a picture ----------------------------------------------

    def test_a_non_image_attachment_is_recorded_rather_than_downloaded
      api = FakeOP.new(attached: [attachment("7", name: "log.txt", type: "text/plain")])
      out = mirror(item, api)

      assert_empty out["pictures"]
      assert_empty api.downloads
      assert_equal "log.txt", out["pictures_skipped"].first["name"]
      assert_match "not a picture", out["pictures_skipped"].first["reason"]
    end

    def test_an_svg_is_not_a_picture_to_pi
      api = FakeOP.new(attached: [attachment("7", name: "d.svg", type: "image/svg+xml")])
      out = mirror(item, api)

      assert_empty out["pictures"], "pi reads markup as text, not as an image"
      assert_equal 1, out["pictures_skipped"].length
    end

    def test_a_content_type_with_parameters_still_matches
      api = FakeOP.new(attached: [attachment("7", type: "image/png; charset=binary")])
      out = mirror(item, api)

      assert_equal 1, out["pictures"].length
    end

    def test_an_oversized_picture_is_skipped_before_it_is_downloaded
      api = FakeOP.new(attached: [attachment("7", size: ItemPictures::MAX_BYTES + 1)])
      out = mirror(item(description: "![](#{ref(7)})"), api)

      assert_empty out["pictures"]
      assert_empty api.downloads, "the API reports the size, so nothing is transferred"
      assert_match "larger than", out["pictures_skipped"].first["reason"]
      assert_equal "![](#{ref(7)})", out["description"], "a dead URL still says a picture is there"
    end

    # Lower the whole-work-package budget for one example, rather than making a
    # fixture big enough to hit the real 40MB.
    def with_total_budget(bytes)
      old = ItemPictures::MAX_TOTAL
      ItemPictures.send(:remove_const, :MAX_TOTAL)
      ItemPictures.const_set(:MAX_TOTAL, bytes)
      yield
    ensure
      ItemPictures.send(:remove_const, :MAX_TOTAL)
      ItemPictures.const_set(:MAX_TOTAL, old)
    end

    def test_the_per_work_package_budget_stops_the_rest
      api = FakeOP.new(attached: [attachment("1", bytes: "0" * 10),
                                  attachment("2", bytes: "0" * 10)])
      out = with_total_budget(15) { mirror(item, api) }

      assert_equal ["1"], out["pictures"].map { |p| p["id"] }
      assert_match "budget", out["pictures_skipped"].first["reason"]
    end

    def test_past_the_count_cap_the_rest_are_not_looked_at
      many = (1..(ItemPictures::MAX_COUNT + 3)).map { |i| attachment(i.to_s) }
      out  = mirror(item, FakeOP.new(attached: many))

      assert_equal ItemPictures::MAX_COUNT, out["pictures"].length
      assert_match(/3 more/, out["pictures_skipped"].last["name"])
    end

    def test_a_failed_download_is_reported_and_nothing_else_breaks
      api = FakeOP.new(attached: [attachment("7", bytes: nil), attachment("8")])
      # 404: the bytes are gone for good, so this is not retried
      out = mirror(item, api)

      assert_equal ["8"], out["pictures"].map { |p| p["id"] }
      assert_match "download failed", out["pictures_skipped"].first["reason"]
    end

    def test_an_unreadable_attachment_is_reported_by_id
      api = FakeOP.new   # neither collection nor by-id knows 9
      out = mirror(item(comments: [{ "id" => "5", "text" => "![](#{ref(9)})" }]), api)

      assert_empty out["pictures"]
      assert_equal "attachment 9", out["pictures_skipped"].first["name"]
    end

    def test_a_work_package_with_no_attachments_gets_an_empty_index
      out = mirror(item(description: "plain text"), FakeOP.new)

      assert_equal [], out["pictures"]
      refute out.key?("pictures_skipped")
    end

    # --- an answer opilot could not get ------------------------------------

    def test_a_failing_collection_read_is_not_an_empty_answer
      # Otherwise the WP is stamped "no pictures", updated_at still matches, and
      # that verdict stands until somebody edits the work package.
      out = mirror(item(description: "text"), FakeOP.new(collection_code: 503))

      assert out["pictures_pending"], "the next poll has to ask again"
      refute out.key?("pictures"), "nothing was learned, so nothing is claimed"
      assert_equal "text", out["description"]
    end

    def test_an_unfinished_mirror_prunes_nothing
      api = FakeOP.new(attached: [attachment("7")])
      mirror(item(description: "![](#{ref(7)})"), api)

      mirror(item(description: "![](#{ref(7)})"), FakeOP.new(collection_code: 503))

      assert_path_exists @dir / "pictures" / "7-shot.png",
                         "a bad minute at the API must not delete a picture"
    end

    def test_a_permanently_refused_collection_still_reads_a_reference_by_id
      # 403 IS an answer about the collection, and a comment's picture never
      # lived there anyway.
      api = FakeOP.new(standalone: { "9" => attachment("9") }, collection_code: 403)
      out = mirror(item(comments: [{ "id" => "5", "text" => "![](#{ref(9)})" }]), api)

      assert_equal 1, out["pictures"].length
      refute out["pictures_pending"], "nothing about a 403 changes next tick"
    end

    def test_a_transient_by_id_failure_asks_again
      api = FakeOP.new(by_id_code: 500)
      out = mirror(item(comments: [{ "id" => "5", "text" => "![](#{ref(9)})" }]), api)

      assert out["pictures_pending"]
      assert_equal 1, out["pictures_skipped"].length
    end

    def test_a_deleted_attachment_is_a_final_answer
      # A stale reference to an attachment somebody removed. Real, and asking
      # again every 20 seconds forever would only cost requests.
      api = FakeOP.new(by_id_code: 404)
      out = mirror(item(comments: [{ "id" => "5", "text" => "![](#{ref(9)})" }]), api)

      refute out["pictures_pending"]
      assert_match(/could not be read/, out["pictures_skipped"].first["reason"])
    end

    def test_a_transient_download_failure_asks_again
      api = FakeOP.new(attached: [attachment("7", bytes: nil)], download_code: 502)
      out = mirror(item, api)

      assert out["pictures_pending"]
    end

    def test_a_stale_skip_list_does_not_survive_a_clean_run
      api = FakeOP.new(attached: [attachment("7", name: "log.txt", type: "text/plain")])
      out = mirror(item, api)
      assert_equal 1, out["pictures_skipped"].length

      out = mirror(item, FakeOP.new)

      refute out.key?("pictures_skipped"), "the attachment is gone, so the note is too"
    end

    def test_a_raising_api_leaves_the_item_untouched
      broken = Class.new do
        def work_package_attachments(_id) = raise("boom")
      end.new

      out = nil
      _out, err = capture_io { out = mirror(item(description: "text"), broken) }

      assert_equal "text", out["description"]
      refute out.key?("pictures"), "nothing was learned, so nothing is claimed"
      assert out["pictures_pending"], "and the next poll asks again"
      assert_match "could not mirror pictures", (_out + err), "and it says so"
    end

    # --- refresh ------------------------------------------------------------

    def test_a_picture_already_on_disk_is_not_downloaded_again
      api = FakeOP.new(attached: [attachment("7")])
      mirror(item(description: "![](#{ref(7)})"), api)
      mirror(item(description: "![](#{ref(7)})"), api)

      assert_equal 1, api.downloads.length, "a new comment must not re-fetch every screenshot"
    end

    def test_a_changed_picture_is_downloaded_again
      api = FakeOP.new(attached: [attachment("7")])
      mirror(item(description: "![](#{ref(7)})"), api)
      (@dir / "pictures" / "7-shot.png").binwrite("stale")

      mirror(item(description: "![](#{ref(7)})"), api)

      assert_equal 2, api.downloads.length, "the size the API reports is the proof"
    end

    def test_a_picture_that_is_gone_is_pruned
      api = FakeOP.new(attached: [attachment("7")])
      mirror(item(description: "![](#{ref(7)})"), api)
      assert_path_exists @dir / "pictures" / "7-shot.png"

      mirror(item(description: "the picture was removed"), FakeOP.new)

      refute_path_exists @dir / "pictures" / "7-shot.png",
                         "the state dir is a mirror, not an archive"
    end
  end
end
