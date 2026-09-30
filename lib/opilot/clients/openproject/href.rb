module OPilot
  module Clients
    module OpenProject
      # The path format of every link a payload carries, in one place.
      module Href
        module_function

        def work_package(id) = "/api/v3/work_packages/#{id}"
        def status(id)       = "/api/v3/statuses/#{id}"
        def type(id)         = "/api/v3/types/#{id}"
        def project(id)      = "/api/v3/projects/#{id}"
        def priority(id)     = "/api/v3/priorities/#{id}"
        def version(id)      = "/api/v3/versions/#{id}"
        def user(id)         = "/api/v3/users/#{id}"

        def link(href) = { "href" => href }
      end
    end
  end
end
