require_relative "../test_helper"

module Chomper
  class CLITest < Minitest::Test
    def test_wp_id_arg_strips_pasted_hash_prefix_and_whitespace
      cli = CLI.new(nil)
      assert_equal "59942", cli.send(:wp_id_arg, "#59942")
      assert_equal "59942", cli.send(:wp_id_arg, " #59942 ")
      assert_equal "59942", cli.send(:wp_id_arg, "59942")
      assert_equal "", cli.send(:wp_id_arg, nil)
    end

    def test_wp_id_arg_accepts_and_normalizes_semantic_ids
      cli = CLI.new(nil)
      assert_equal "PROJ-123", cli.send(:wp_id_arg, "PROJ-123")
      assert_equal "PROJ-123", cli.send(:wp_id_arg, "#PROJ-123")
      assert_equal "PROJ-123", cli.send(:wp_id_arg, "proj-123")
    end

    def test_pr_rejects_targets_that_are_neither_wp_ids_nor_pr_urls
      cli = CLI.new(nil)
      [["pr"],                                                       # no targets
       ["pr", "not-a-target"],                                       # neither form
       ["pr", "https://github.com/opf/openproject/issues/5"],        # not a PR URL
       ["pr", "59942", "garbage"]].each do |argv|                    # one bad target spoils the call
        assert_raises(Chomper::FatalError) { capture_io { cli.send(:pr, argv) } }
      end
    end

    def test_wp_id_pattern_validates_both_id_forms
      assert_match Helpers::WP_ID_PATTERN, "59942"
      assert_match Helpers::WP_ID_PATTERN, "PROJ-123"
      assert_match Helpers::WP_ID_PATTERN, "A1_B-7"
      refute_match Helpers::WP_ID_PATTERN, "proj-123", "route constraint is uppercase-only"
      refute_match Helpers::WP_ID_PATTERN, "PROJ-"
      refute_match Helpers::WP_ID_PATTERN, "123-PROJ"
      refute_match Helpers::WP_ID_PATTERN, "../escape"
      refute_match Helpers::WP_ID_PATTERN, ""
    end
  end
end
