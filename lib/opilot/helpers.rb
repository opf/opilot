module OPilot
  # Shared helpers, one file per concern. Every file reopens this module, so
  # `Helpers.x` and `include Helpers` reach all of them. File/JSON idioms are
  # module functions (`def self.`) because some classes that use them —
  # OpenProject::Pull, UI — do not include Helpers.
  module Helpers
  end
end

require_relative "helpers/state"
require_relative "helpers/contracts"
require_relative "helpers/work_packages"
require_relative "helpers/terminal"
require_relative "helpers/git"
require_relative "helpers/pipeline"
