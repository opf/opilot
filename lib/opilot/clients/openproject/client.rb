module OPilot
  module Clients
    module OpenProject
      # The OpenProject REST client: Base's transport plus one module per area.
      # Every endpoint the agent uses lives in those modules; callers never
      # build URLs or call HTTP directly for OpenProject requests.
      class Client < Base
        include WorkPackages
        include Projects
        include Instance
        include Attachments
        include Documents
        include Notifications
      end
    end
  end
end
