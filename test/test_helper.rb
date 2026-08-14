require "bundler/setup"
require "minitest/autorun"
require "webmock/minitest"
require "json"
require "pathname"
require "fileutils"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "chomper/context"
require "chomper/clients"
require "chomper/helpers"
require "chomper/prompts"
require "chomper/harness"
require "chomper/ui"
require "chomper/pull"
require "chomper/publish"
require "chomper/agent"
require "chomper/gh_pull"
require "chomper/gh_agent"
require "chomper/combined_agent"
require "chomper/fix_runner"
require "chomper/pr_runner"
require "chomper/chat_runner"
require "chomper/usage_runner"
# The `pd` pipeline is lazily required in production (see bin/chomper); the suite
# loads all of it, intake converter included, since it tests every stage.
require "chomper/pd"
require "chomper/pd/intake"
require "chomper/cli"

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
Chomper::Clients::HTTP.base_interval = 0
Chomper::Clients::GitHub.base_interval = 0
