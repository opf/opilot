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

require_relative "openproject/errors"
require_relative "openproject/response"
require_relative "openproject/query"
require_relative "openproject/base"
require_relative "openproject/work_packages"
require_relative "openproject/projects"
require_relative "openproject/instance"
require_relative "openproject/attachments"
require_relative "openproject/documents"
require_relative "openproject/client"
require_relative "openproject/href"
require_relative "openproject/resource"
require_relative "openproject/lookup"
