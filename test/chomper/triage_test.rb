require_relative "../test_helper"

module Chomper
  class TriageTest < Minitest::Test
    def setup
      ctx = Struct.new(:state_dir, :state_container, :log_file, :script_dir).new(
        Pathname("/state"), "/state", Pathname("/dev/null"), Pathname("/tmp")
      )
      @triage = Triage.new(ctx, nil, nil)
    end

    def test_extract_json_block_returns_content_between_delimiters
      text = "Preamble text\n---BEGIN JSON---\n[{\"id\":\"1\"}]\n---END JSON---\nTrailing"
      result = @triage.send(:extract_json_block, text)
      assert_equal "[{\"id\":\"1\"}]\n", result
    end

    def test_extract_json_block_returns_nil_without_begin_delimiter
      assert_nil @triage.send(:extract_json_block, "no delimiters here")
    end

    def test_extract_json_block_returns_nil_empty_string
      assert_nil @triage.send(:extract_json_block, "")
    end

    def test_extract_json_block_handles_multiline_json
      json = "[\n  {\"id\": \"1\"},\n  {\"id\": \"2\"}\n]"
      text = "---BEGIN JSON---\n#{json}\n---END JSON---"
      result = @triage.send(:extract_json_block, text)
      assert_equal "#{json}\n", result
    end

    def test_extract_json_block_nothing_after_end_delimiter
      text = "---BEGIN JSON---\n[]\n---END JSON---"
      refute_nil @triage.send(:extract_json_block, text)
    end

    BATCH = [{ "id" => "1" }, { "id" => "2" }].freeze

    def test_build_prompt_includes_item_paths
      prompt = @triage.send(:build_prompt, BATCH)
      assert_includes prompt, "/state/items/1/item.json"
      assert_includes prompt, "/state/items/2/item.json"
    end

    def test_build_prompt_includes_begin_json_delimiter
      prompt = @triage.send(:build_prompt, BATCH)
      assert_includes prompt, "---BEGIN JSON---"
    end

    def test_build_prompt_includes_end_json_delimiter
      prompt = @triage.send(:build_prompt, BATCH)
      assert_includes prompt, "---END JSON---"
    end

    def test_build_prompt_includes_schema_fields
      prompt = @triage.send(:build_prompt, BATCH)
      assert_includes prompt, "locality_group"
      assert_includes prompt, "complexity"
      assert_includes prompt, "files_touched"
      assert_includes prompt, "ai_category"
    end

    def test_build_prompt_includes_complexity_levels
      prompt = @triage.send(:build_prompt, BATCH)
      assert_includes prompt, "trivial"
      assert_includes prompt, "simple"
      assert_includes prompt, "moderate"
      assert_includes prompt, "complex"
    end
  end

  class TriageItemSelectionTest < Minitest::Test
    def setup
      @tmpdir  = Dir.mktmpdir
      @path    = Pathname(@tmpdir) / "backlog.json"
      @backlog = Backlog.new(@path)

      items = [
        { "id" => "1", "state" => Backlog::STATE_UNTRIAGED },
        { "id" => "2", "state" => Backlog::STATE_REQUESTED },
        { "id" => "3", "state" => Backlog::STATE_PENDING   },
      ]
      @path.write(JSON.generate("items" => items))

      ctx = Struct.new(:state_dir, :state_container, :log_file, :script_dir).new(
        Pathname(@tmpdir), @tmpdir.to_s, Pathname("/dev/null"), Pathname(@tmpdir)
      )
      @triaged_ids = []
      claude = Struct.new(:nothing).new
      claude.define_singleton_method(:run) do |prompt|
        ids = prompt.scan(%r{items/(\d+)/item\.json}).flatten
        json = ids.map { |id| { "id" => id, "state" => "pending", "locality_group" => "x",
                                "complexity" => "trivial", "files_touched" => [], "ai_category" => nil } }
        "---BEGIN JSON---\n#{JSON.generate(json)}\n---END JSON---"
      end
      @triage = Triage.new(ctx, @backlog, claude)
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_run_triage_stage_only_processes_untriaged
      @triage.run_triage_stage
      assert_equal "pending", @backlog.find("1")["state"]
      assert_equal Backlog::STATE_REQUESTED, @backlog.find("2")["state"]
    end

    def test_run_triage_for_requested_only_processes_requested
      @triage.run_triage_for_requested
      assert_equal Backlog::STATE_UNTRIAGED, @backlog.find("1")["state"]
      assert_equal "pending", @backlog.find("2")["state"]
    end
  end
end
