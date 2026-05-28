require_relative "../test_helper"

module Chomper
  class BacklogTest < Minitest::Test
    SEED_ITEMS = [
      { "id" => "1", "subject" => "Alpha", "state" => Backlog::STATE_UNTRIAGED, "locality_group" => "auth", "complexity" => "simple",   "files_touched" => [], "ai_category" => nil },
      { "id" => "2", "subject" => "Beta",  "state" => Backlog::STATE_PENDING,   "locality_group" => "ui",   "complexity" => "trivial",  "files_touched" => [], "ai_category" => nil },
      { "id" => "3", "subject" => "Gamma", "state" => Backlog::STATE_COMMITTED, "locality_group" => "api",  "complexity" => "moderate", "files_touched" => [], "ai_category" => nil },
      { "id" => "4", "subject" => "Delta", "state" => Backlog::STATE_BLOCKED,   "locality_group" => "db",   "complexity" => "complex",  "files_touched" => [], "ai_category" => nil },
    ].freeze

    def setup
      @tmpdir  = Dir.mktmpdir
      @path    = Pathname(@tmpdir) / "backlog.json"
      @backlog = Backlog.new(@path)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def seed(items = SEED_ITEMS)
      @path.write(JSON.generate("items" => items))
      @backlog.reload!
    end

    def test_exist_false_before_file_written
      refute @backlog.exist?
    end

    def test_exist_true_after_seed
      seed
      assert @backlog.exist?
    end

    def test_items_returns_all
      seed
      assert_equal 4, @backlog.items.length
    end

    def test_untriaged_returns_untriaged_state
      seed
      assert_equal ["1"], @backlog.untriaged.map { |i| i["id"] }
    end

    def test_pending_returns_pending_state
      seed
      assert_equal ["2"], @backlog.pending.map { |i| i["id"] }
    end

    def test_committed_returns_committed_state
      seed
      assert_equal ["3"], @backlog.committed.map { |i| i["id"] }
    end

    def test_blocked_returns_blocked_state
      seed
      assert_equal ["4"], @backlog.blocked.map { |i| i["id"] }
    end

    def test_find_by_string_id
      seed
      assert_equal "Alpha", @backlog.find("1")["subject"]
    end

    def test_find_by_integer_id
      seed
      assert_equal "Alpha", @backlog.find(1)["subject"]
    end

    def test_find_returns_nil_for_missing_id
      seed
      assert_nil @backlog.find("99")
    end

    def test_merge_new_items_preserves_triage_fields_for_existing
      seed
      new_items = [
        { "id" => "2", "subject" => "Beta Updated", "state" => Backlog::STATE_UNTRIAGED, "locality_group" => nil,
          "complexity" => nil, "files_touched" => [], "ai_category" => nil },
      ]
      @backlog.merge_new_items(new_items)

      item = @backlog.find("2")
      assert_equal "Beta Updated",        item["subject"]        # updated from API
      assert_equal Backlog::STATE_PENDING, item["state"]         # preserved
      assert_equal "ui",                  item["locality_group"] # preserved
      assert_equal "trivial",             item["complexity"]     # preserved
    end

    def test_merge_new_items_sets_untriaged_state_for_new_items
      seed
      new_items = [
        { "id" => "5", "subject" => "New", "state" => Backlog::STATE_PENDING, "locality_group" => nil,
          "complexity" => nil, "files_touched" => [], "ai_category" => nil },
      ]
      @backlog.merge_new_items(new_items)
      assert_equal Backlog::STATE_UNTRIAGED, @backlog.find("5")["state"]
    end

    def test_replace_with_new_items_discards_old
      seed
      @backlog.replace_with_new_items([{ "id" => "9", "subject" => "Only", "state" => Backlog::STATE_PENDING }])
      assert_equal ["9"], @backlog.items.map { |i| i["id"] }
    end

    def test_merge_fetched_items_preserves_existing_items_not_in_list
      seed
      @backlog.merge_fetched_items([{ "id" => "9", "subject" => "New", "state" => Backlog::STATE_PENDING }])
      assert_equal %w[1 2 3 4 9], @backlog.items.map { |i| i["id"] }.sort
    end

    def test_merge_fetched_items_upserts_existing_item_as_pending
      seed
      updated = { "id" => "1", "subject" => "Alpha Updated", "state" => Backlog::STATE_PENDING,
                  "locality_group" => nil, "complexity" => nil, "files_touched" => [], "ai_category" => nil }
      @backlog.merge_fetched_items([updated])
      item = @backlog.find("1")
      assert_equal "Alpha Updated",         item["subject"]
      assert_equal Backlog::STATE_PENDING,  item["state"]
    end

    def test_remove_items_drops_specified_ids
      seed
      @backlog.remove_items(["1", "3"])
      assert_equal %w[2 4], @backlog.items.map { |i| i["id"] }
    end

    def test_remove_items_preserves_unspecified_ids
      seed
      @backlog.remove_items(["2"])
      assert_equal "Alpha", @backlog.find("1")["subject"]
      assert_equal "Gamma", @backlog.find("3")["subject"]
    end

    def test_merge_triage_results_patches_fields
      seed
      @backlog.merge_triage_results([
        { "id" => "1", "locality_group" => "payments", "complexity" => "complex",
          "state" => Backlog::STATE_PENDING, "files_touched" => ["app/foo.rb"], "ai_category" => "logic-bug" },
      ])
      item = @backlog.find("1")
      assert_equal "payments",             item["locality_group"]
      assert_equal "complex",              item["complexity"]
      assert_equal Backlog::STATE_PENDING, item["state"]
      assert_equal ["app/foo.rb"],         item["files_touched"]
    end

    def test_merge_triage_results_leaves_untouched_items_alone
      seed
      @backlog.merge_triage_results([{ "id" => "1", "state" => Backlog::STATE_PENDING }])
      assert_equal "Beta", @backlog.find("2")["subject"]
    end

    def test_sort_by_complexity_orders_trivial_to_complex
      seed
      @backlog.sort_by_complexity!
      assert_equal %w[trivial simple moderate complex], @backlog.items.map { |i| i["complexity"] }
    end

    def test_set_state_committed
      seed
      @backlog.set_state("2", Backlog::STATE_COMMITTED)
      assert_equal Backlog::STATE_COMMITTED, @backlog.find("2")["state"]
    end

    def test_set_state_blocked
      seed
      @backlog.set_state("2", Backlog::STATE_BLOCKED)
      assert_equal Backlog::STATE_BLOCKED, @backlog.find("2")["state"]
    end

    def test_set_state_leaves_other_items_unchanged
      seed
      @backlog.set_state("2", Backlog::STATE_COMMITTED)
      refute_equal @backlog.find("2")["state"], @backlog.find("4")["state"]
      assert_equal "Alpha", @backlog.find("1")["subject"]
    end

    def test_atomic_write_persists_to_disk
      seed
      @backlog.set_state("2", Backlog::STATE_COMMITTED)
      fresh = Backlog.new(@path)
      assert_equal Backlog::STATE_COMMITTED, fresh.find("2")["state"]
    end
  end
end
