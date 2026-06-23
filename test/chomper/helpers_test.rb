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

    def test_adopt_github_author_sets_git_identity_from_the_bot
      Helpers.instance_variable_set(:@github_author_adopted, nil)
      stub_request(:get, "https://api.github.com/user").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("login" => "chomper-bot", "id" => 7, "name" => "Chomper Bot")
      )
      ctx  = Struct.new(:github_token).new("tok")
      keys = %w[GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL]
      saved = keys.to_h { |k| [k, ENV[k]] }
      begin
        Helpers.adopt_github_author!(ctx)
        assert_equal "Chomper Bot", ENV["GIT_AUTHOR_NAME"]
        assert_equal "7+chomper-bot@users.noreply.github.com", ENV["GIT_AUTHOR_EMAIL"]
        assert_equal "Chomper Bot", ENV["GIT_COMMITTER_NAME"]
        assert_equal "7+chomper-bot@users.noreply.github.com", ENV["GIT_COMMITTER_EMAIL"]
      ensure
        saved.each { |k, v| ENV[k] = v }
        Helpers.instance_variable_set(:@github_author_adopted, nil)
      end
    end

    def test_adopt_github_author_is_a_noop_without_a_token
      Helpers.instance_variable_set(:@github_author_adopted, nil)
      # No WebMock stub: if it tried to reach GitHub, the request would raise.
      Helpers.adopt_github_author!(Struct.new(:github_token).new(nil))
    ensure
      Helpers.instance_variable_set(:@github_author_adopted, nil)
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

    # parse_scan_from returns an ISO8601 cutoff `seconds_ago` before now.
    def assert_scan_from(seconds_ago, input)
      parsed = Time.parse(Helpers.parse_scan_from(input))
      assert_in_delta (Time.now.utc - seconds_ago), parsed, 5,
                      "#{input.inspect} should resolve to ~#{seconds_ago}s ago"
    end

    def test_parse_scan_from_blank_and_now_mean_now
      assert_scan_from(0, "")
      assert_scan_from(0, "now")
    end

    def test_parse_scan_from_minutes_hours_days_weeks
      assert_scan_from(60,        "1m")
      assert_scan_from(120,       "2 mins")
      assert_scan_from(3 * 3600,  "3h")
      assert_scan_from(2 * 86400, "2 days")
      assert_scan_from(604800,    "1 week")
    end

    def test_parse_scan_from_months_and_years
      assert_scan_from(2592000,     "1 month")
      assert_scan_from(2 * 2592000, "2 months")
      assert_scan_from(2592000,     "1mo")
      assert_scan_from(31536000,    "1 year")
    end

    def test_parse_scan_from_unparseable_defaults_to_now
      out, = capture_io { assert_scan_from(0, "next tuesday-ish") }
      assert_match(/Could not parse/, out)
    end
  end
end
