module OPilot
  module Clients
    module OpenProject
      # Request bodies that more than one caller sends.
      module Payload
        module_function

        # The v3 create body. `_links.type` is present only when a type was
        # resolved: with no type, OpenProject assigns the project's first enabled
        # type. `type` is a type resource (its "id" is read). `parent` is a
        # work-package id; it needs :manage_subtasks, so only callers that hold it
        # pass one.
        def work_package(project:, type:, subject:, description:, parent: nil)
          links = { "project" => Href.link(Href.project(project)) }
          links["type"] = Href.link(Href.type(type["id"])) if type
          links["parent"] = Href.link(Href.work_package(parent)) if parent

          { "subject"     => subject.to_s[0, 200],
            "description" => { "format" => "markdown", "raw" => description.to_s },
            "_links"      => links }
        end
      end
    end
  end
end
