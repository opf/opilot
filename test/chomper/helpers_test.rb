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

    def test_strip_ansi_passthrough_plain_string
      assert_equal "plain text", h.strip_ansi("plain text")
    end

    def test_strip_ansi_empty_string
      assert_equal "", h.strip_ansi("")
    end

    def test_branch_slug_basic
      assert_equal "fix/42-fix-the-login-bug", h.branch_slug(42, "Fix the login bug")
    end

    def test_branch_slug_downcases
      assert_equal "fix/1-all-caps", h.branch_slug(1, "ALL CAPS")
    end

    def test_branch_slug_replaces_special_chars_with_hyphens
      slug = h.branch_slug(1, "Fix: the #1 bug (critical!)")
      refute_match(/[^a-z0-9\-\/]/, slug)
    end

    def test_branch_slug_truncates_title_to_40_chars
      long_title = "a" * 60
      slug = h.branch_slug(1, long_title)
      title_part = slug.sub("fix/1-", "")
      assert title_part.length <= 40
    end

    def test_branch_slug_integer_id
      assert_match(/^fix\/99-/, h.branch_slug(99, "Some title"))
    end
  end
end
