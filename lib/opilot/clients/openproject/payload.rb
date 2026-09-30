module OPilot
  module Clients
    module OpenProject
      # Request bodies that more than one caller sends.
      module Payload
        module_function

        # The v3 create body. `_links.type` is present only when a type was
        # resolved: with no type, OpenProject assigns the project's first enabled
        # type. `type` is a type resource (its "id" is read).
        def work_package(project:, type:, subject:, description:)
          links = { "project" => Href.link(Href.project(project)) }
          links["type"] = Href.link(Href.type(type["id"])) if type

          { "subject"     => subject.to_s[0, 200],
            "description" => { "format" => "markdown", "raw" => description.to_s },
            "_links"      => links }
        end
      end
    end
  end
end
