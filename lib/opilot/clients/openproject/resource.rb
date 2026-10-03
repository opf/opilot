module OPilot
  module Clients
    module OpenProject
      # Reading the resources the API returns: no requests, only the shape of a
      # v3 body. Lookup resolves names with it; callers use it directly.
      module Resource
        module_function

        # Rendered only for a user who holds :add_work_packages.
        CREATE_WP_LINKS = %w[createWorkPackageImmediately createWorkPackage].freeze

        def elements(body)
          (body || {}).dig("_embedded", "elements") || []
        end

        # A project's work-package types as [{ "id", "name" }], from a
        # #project_types response.
        def type_list(body)
          elements(body).map { |t| { "id" => t["id"], "name" => t["name"].to_s } }
        end

        # The element with this name, case-insensitively — instances style
        # names inconsistently ("Feature", "FEATURE"). One definition, so a type
        # or status name that resolves in one command resolves in all of them.
        def find_named(list, name)
          return nil if name.to_s.strip.empty?
          list.to_a.find { |e| e["name"].to_s.casecmp?(name.to_s) }
        end

        # The id a user sees: semantic ("PROJ-123") in semantic mode, numeric
        # otherwise, and "id" on instances that predate displayId. The poll
        # cache and every published link must name a work package this way.
        def display_id(wp)
          id = (wp || {})["displayId"]
          (id.nil? || id.to_s.empty? ? (wp || {})["id"] : id).to_s
        end

        # Whether this token may create work packages in a project (a project
        # body). The links' absence is a real answer, so this is a preflight
        # rather than a guess.
        def create_wp_allowed?(project)
          links = (project || {})["_links"] || {}
          CREATE_WP_LINKS.any? { |name| links.key?(name) }
        end

        # A list element embeds nothing, so a linked resource's name is its title.
        def link_title(resource, key)
          resource.dig("_links", key, "title") || resource.dig("_embedded", key, "name")
        end

        def link_id(resource, key) = href_id(resource.dig("_links", key, "href"))

        # --- schemas ---

        # A schema's fields, { key => node }. The schema also holds _type, _links,
        # _dependencies and _attributeGroups, which are not fields.
        def schema_fields(schema)
          (schema || {}).select { |key, node| node.is_a?(Hash) && !key.start_with?("_") }
        end

        # A form's required, writable fields, with the form's error for each when
        # it has one. `allowedValues` is passed as the schema renders it: see
        # Lookup#allowed_values for its two shapes.
        def required_fields(form)
          errors = form.dig("_embedded", "validationErrors") || {}
          schema_fields(form.dig("_embedded", "schema")).filter_map do |key, node|
            next unless node["required"] && node["writable"] != false
            { "field"         => key,
              "name"          => node["name"],
              "type"          => node["type"],
              "hasDefault"    => node["hasDefault"],
              "allowedValues" => node.dig("_links", "allowedValues"),
              "error"         => errors.dig(key, "message") }.compact
          end
        end

        # The [project_id, type_id] a schema href names
        # ("/api/v3/work_packages/schemas/7-5"), or nil.
        def schema_ids(href)
          href.to_s[%r{/schemas/(\d+-\d+)\z}, 1]&.split("-")
        end

        # The custom field whose items an allowedValues link points at
        # ("/api/v3/custom_fields/12/items"), or nil for any other link.
        def items_field_id(href)
          href.to_s[%r{/custom_fields/(\d+)/items\z}, 1]
        end

        # A work package's custom fields that hold a value, { "customField12" => value },
        # from both the plain attributes and the links.
        def custom_field_values(wp)
          wp.select { |k, _| k.start_with?("customField") }
            .merge((wp["_links"] || {}).select { |k, _| k.start_with?("customField") })
            .transform_values { |v| custom_field_value(v) }
            .reject { |_, v| v.nil? || v == "" || v == [] }
        end

        # A value as a reader sees it: a formattable's raw text, a link's title.
        def custom_field_value(value)
          case value
          when Array then value.map { |v| custom_field_value(v) }.compact
          when Hash  then value.key?("raw") ? value["raw"].to_s.strip : value["title"]
          else value
          end
        end

        # The trailing id of an href ("/api/v3/work_packages/108" → "108"), or nil.
        def href_id(href)
          id = href.to_s.split("/").last
          id.to_s.empty? ? nil : id
        end
      end
    end
  end
end
