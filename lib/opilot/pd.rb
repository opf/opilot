module OPilot
  # The `pd` (product development) pipeline — see lib/opilot/pd/CLAUDE.md.
  #
  # Autoloading keeps it out of every other run: nothing under pd/ loads until
  # code names a PD constant. Intake loads later still (`PD::Runner#intake`),
  # since it pulls in roo, nokogiri and rubyzip. PD::ChangeStore is the one part
  # gh-agent names on every tick, to identify a spec PR.
  module PD
  end
end
