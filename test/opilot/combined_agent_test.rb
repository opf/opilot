require_relative "../test_helper"

module OPilot
  class CombinedAgentTest < Minitest::Test
    # The run loop is endless (in production only Ctrl-C's SystemExit ends it),
    # so the fake ends it by raising StopLoop — an Exception, not a
    # StandardError, so it escapes guarded_tick the same way SystemExit does.
    class StopLoop < Exception; end

    # Records the order in which setup/tick are called, and stops the loop after
    # one cycle so the test terminates. `tick` appends a tag per call.
    class FakeLoop
      attr_reader :calls
      def initialize(tag, calls, stop_after: false)
        @tag = tag; @calls = calls; @stop_after = stop_after
      end

      def setup
        @calls << "#{@tag}:setup"
        @tag # stands in for filters / scan_from_at
      end

      def tick(arg)
        @calls << "#{@tag}:tick(#{arg})"
        raise StopLoop if @stop_after
      end
    end

    def setup
      @calls = []
      @ctx   = Struct.new(:contributor_token).new("ghp_token")
    end

    def test_polls_github_before_openproject_each_cycle
      gh = FakeLoop.new("gh", @calls)
      op = FakeLoop.new("op", @calls, stop_after: true) # stop after one full cycle
      assert_raises(StopLoop) do
        capture_io { CombinedAgent.new(@ctx, agent: op, gh_agent: gh).run }
      end

      # Both setups run before the loop; GitHub's tick precedes OpenProject's.
      assert_equal ["gh:setup", "op:setup", "gh:tick(gh)", "op:tick(op)"], @calls
    end

    def test_runs_openproject_only_when_no_github_token
      @ctx = Struct.new(:contributor_token).new(nil)
      gh = FakeLoop.new("gh", @calls)
      op = FakeLoop.new("op", @calls, stop_after: true)
      assert_raises(StopLoop) do
        capture_io { CombinedAgent.new(@ctx, agent: op, gh_agent: gh).run }
      end

      # No GitHub setup or tick — degrades to the OpenProject loop.
      assert_equal ["op:setup", "op:tick(op)"], @calls
    end
  end
end
