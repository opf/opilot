require_relative "../test_helper"

module Chomper
  class CombinedAgentTest < Minitest::Test
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
        Chomper.request_stop if @stop_after
      end
    end

    def setup
      Chomper.instance_variable_set(:@stop, false)
      @calls = []
      @ctx   = Struct.new(:github_token).new("ghp_token")
    end

    def teardown
      Chomper.instance_variable_set(:@stop, false)
    end

    def test_polls_github_before_openproject_each_cycle
      gh = FakeLoop.new("gh", @calls)
      op = FakeLoop.new("op", @calls, stop_after: true) # stop after one full cycle
      capture_io { CombinedAgent.new(@ctx, agent: op, gh_agent: gh).run }

      # Both setups run before the loop; GitHub's tick precedes OpenProject's.
      assert_equal ["gh:setup", "op:setup", "gh:tick(gh)", "op:tick(op)"], @calls
    end

    def test_runs_openproject_only_when_no_github_token
      @ctx = Struct.new(:github_token).new(nil)
      gh = FakeLoop.new("gh", @calls)
      op = FakeLoop.new("op", @calls, stop_after: true)
      capture_io { CombinedAgent.new(@ctx, agent: op, gh_agent: gh).run }

      # No GitHub setup or tick — degrades to the OpenProject loop.
      assert_equal ["op:setup", "op:tick(op)"], @calls
    end
  end
end
