module OPilot
  module Clients
    module OpenProject
      # Instance-wide lists — statuses, priorities, principals, custom field
      # values — and the token's own identity.
      module Instance
        def me
          get("users/me")
        end

        def statuses
          get("statuses")
        end

        # Not paginated: the endpoint renders every priority.
        def priorities
          get("priorities")
        end

        # Users, groups and placeholders. /users lists only for an admin; this
        # works with a normal token. `name` takes `=` (case-insensitive) and `~`.
        def principals(filters_json: "[]", page: 1, page_size: 100)
          collection("principals", filters_json: filters_json, page: page, page_size: page_size)
        end

        # The values a hierarchy custom field allows, as a flat tree (each item
        # carries `label`, `depth` and a self link — the href a payload link needs).
        #
        # A schema renders allowed values two ways: a list field embeds them
        # (`schema_with_allowed_collection`), while a hierarchy, user or version
        # field renders only a LINK to them (`schema_with_allowed_link`). So the
        # values of a required hierarchy field cannot be read off the form at all,
        # and this is the endpoint its link points at (`api_v3_paths
        # .custom_field_items`). No query parameters: the route takes `parent` and
        # `depth` only, and the whole tree is what a caller filling a field wants.
        def custom_field_items(custom_field_id)
          get("custom_fields/#{custom_field_id}/items")
        end
      end
    end
  end
end
