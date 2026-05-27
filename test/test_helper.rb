require "bundler/setup"
require "minitest/autorun"
require "webmock/minitest"
require "json"
require "pathname"
require "fileutils"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "chomper/context"
require "chomper/backlog"
require "chomper/http"
require "chomper/helpers"
require "chomper/claude"
require "chomper/pull"
require "chomper/triage"
require "chomper/fix"
require "chomper/publish"
require "chomper/cli"

WebMock.disable_net_connect!
