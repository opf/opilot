# The `pd` (product development) pipeline: OpenProject Documents → an OpenSpec
# change proposal reviewed as a PR → generated work packages → one
# implementation run per work package.
#
# Its own namespace because the bug-fix verbs (plan/build/ship/pr) also take a
# work-package id while meaning something else entirely, and because the two
# share nothing but the shared core (Context, Helpers, Claude, Publish).
#
# Requiring this file is the pipeline's load boundary: nothing here is loaded by
# an agent run or a bug-fix command, so `CLI#pd` requires it on demand. Intake
# is one step lazier still (`PD::Runner#intake` requires it) — it pulls in roo,
# nokogiri and rubyzip, which only the stages that read a document ever need.
#
# PD::ChangeStore is the exception: gh-agent needs it to identify a spec PR, so
# gh_pull.rb requires chomper/pd/change_state directly and it loads eagerly.
require_relative "pd/change_state"
require_relative "pd/resolved_ids"
require_relative "pd/runner"
