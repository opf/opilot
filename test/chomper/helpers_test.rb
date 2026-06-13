require_relative "../test_helper"

module Chomper
  class HelpersTest < Minitest::Test
    class Host
      include Helpers
      def initialize
        @ctx = Struct.new(:log_file, :script_dir).new(
          Pathname("/dev/null"),
          Pathname("/tmp")
        )
      end
    end

    def h = @h ||= Host.new

    def test_strip_ansi_removes_color_codes
      assert_equal "red text", h.strip_ansi("\e[31mred text\e[0m")
    end

    def test_wp_label_prefixes_numeric_ids_only
      assert_equal "#59942",   h.wp_label("59942")
      assert_equal "STC-162",  h.wp_label("STC-162")
      assert_equal "#42",      Helpers.wp_label(42)
    end

    def test_strip_ansi_passthrough_plain_string
      assert_equal "plain text", h.strip_ansi("plain text")
    end

    def test_strip_ansi_empty_string
      assert_equal "", h.strip_ansi("")
    end

    def test_branch_slug_basic
      assert_equal "bug/42-fix-the-login-bug", h.branch_slug(42, "Bug", "Fix the login bug")
    end

    def test_branch_slug_downcases
      assert_equal "feature/1-all-caps", h.branch_slug(1, "Feature", "ALL CAPS")
    end

    def test_branch_slug_sanitizes_type
      assert_equal "new-feature/1-title", h.branch_slug(1, "New Feature", "title")
    end

    def test_branch_slug_ampersand_in_type
      assert_equal "research-and-development/1-title", h.branch_slug(1, "Research & Development", "title")
    end

    def test_branch_slug_falls_back_to_task_when_type_empty
      assert_match(/^task\//, h.branch_slug(1, "", "title"))
    end

    def test_branch_slug_replaces_special_chars_with_hyphens
      slug = h.branch_slug(1, "Bug", "Fix: the #1 bug (critical!)")
      refute_match(/[^a-z0-9\-\/]/, slug)
    end

    def test_branch_slug_truncates_title_to_40_chars
      slug = h.branch_slug(1, "Bug", "a" * 60)
      title_part = slug.sub("bug/1-", "")
      assert title_part.length <= 40
    end

    def test_branch_slug_integer_id
      assert_match(/^bug\/99-/, h.branch_slug(99, "Bug", "Some title"))
    end

    def test_branch_slug_string_id
      assert_match(/^bug\/ABC-123-/, h.branch_slug("ABC-123", "Bug", "Some title"))
    end
  end
end
