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
  end
end
