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
require "chomper/claude"
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
require "chomper/openspec"
require "chomper/tasks_file"
require "chomper/change_state"
require "chomper/resolved_ids"
require "chomper/intake"
require "chomper/product_runner"
require "chomper/cli"

WebMock.disable_net_connect!

# Disable real retry backoff so the suite doesn't sleep through retries.
Chomper::Clients::HTTP.base_interval = 0
Chomper::Clients::GitHub.base_interval = 0
