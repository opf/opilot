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
end
