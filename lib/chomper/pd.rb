# The `pd` (product development) pipeline — see lib/chomper/pd/CLAUDE.md.
#
# Requiring this file is the pipeline's load boundary: nothing here is loaded by
# an agent run or a bug-fix command, so `CLI#pd` requires it on demand. Intake is
# lazier still (`PD::Runner#intake`), since it pulls in roo, nokogiri and rubyzip.
# PD::ChangeStore is the exception — gh-agent needs it to identify a spec PR, so
# gh_pull.rb requires it directly and it loads eagerly.
require_relative "pd/change_state"
require_relative "pd/resolved_ids"
require_relative "pd/runner"
