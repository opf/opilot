require "bundler/setup"
require "minitest/autorun"
require "webmock/minitest"
require "json"
require "pathname"
require "fileutils"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "opilot/context"
require "opilot/clients"
require "opilot/helpers"
require "opilot/prompts"
require "opilot/harness"
require "opilot/ui"
require "opilot/pull"
require "opilot/publish"
require "opilot/agent"
require "opilot/gh_pull"
require "opilot/gh_agent"
require "opilot/combined_agent"
require "opilot/fix_runner"
require "opilot/pr_runner"
require "opilot/chat_runner"
require "opilot/usage_runner"
require "opilot/op_runner"
# The `pd` pipeline is lazily required in production (see bin/opilot); the suite
# loads all of it, intake converter included, since it tests every stage.
require "opilot/pd"
require "opilot/pd/intake"
require "opilot/cli"

require_relative "support/fixtures"

WebMock.disable_net_connect!

# webmock/minitest hooks its per-test reset into an ALIASED `teardown`, so any
# test class that defines its own `teardown` without calling `super` silently
# disables it — and nearly all of ours do. Stub registrations and request counts
# then leak across tests in the same file, which makes `assert_requested times:`
# meaningless (it counts every earlier test's calls too) and lets a test pass on
# a stub some unrelated test happened to register. Hook the reset into
# `after_teardown` instead, which minitest always calls regardless of what a
# subclass does with `teardown`.
module WebMockAlwaysReset
  def after_teardown
    super
    WebMock.reset!
  end
end
Minitest::Test.prepend(WebMockAlwaysReset)

# Disable real retry backoff so the suite doesn't sleep through retries.
OPilot::Clients::HTTP.base_interval = 0
OPilot::Clients::GitHub.base_interval = 0
