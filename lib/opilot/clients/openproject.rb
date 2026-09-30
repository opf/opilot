module OPilot
  module Clients
    # The OpenProject SDK. Client (openproject/client.rb) is the REST client,
    # and every endpoint returns a Response; a failure is one of the Error
    # classes. Beside it sit Query (filter and sort values), Lookup (names →
    # resources), Resource (reading a v3 body) and Href (link paths).
    module OpenProject
    end
  end
end

# Several error classes in one file, so it is not autoloaded (see lib/opilot.rb).
require_relative "openproject/errors"
