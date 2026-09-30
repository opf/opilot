module OPilot
  module Clients
    module OpenProject
      # Projects and what hangs off one: its types and versions.
      module Projects
        # Projects the token can see. Filters as in #work_packages, for example
        # `active` or a project attribute (`customField12`).
        def projects(filters_json: "[]", page: 1, page_size: 100)
          collection("projects", filters_json: filters_json, page: page, page_size: page_size)
        end

        def project(project_id)
          get("projects/#{project_id}")
        end

        def project_types(project_id)
          get("projects/#{project_id}/types")
        end

        # The versions a project can use, shared ones included.
        def project_versions(project_id)
          get("projects/#{project_id}/versions")
        end
      end
    end
  end
end
