module OPilot
  module Clients
    module OpenProject
      # Names → OpenProject resources, over a client's endpoints. It keeps its own
      # cache, so build one per run: a long-lived one would never see a new status.
      #
      # One failure rule for every resolver: `nil` means the list was read and the
      # name is not in it; a list that could not be read raises an Error. Callers
      # word those two differently, so they must not look alike.
      class Lookup
        # Not an HTTP failure, so it carries no code.
        class AmbiguousName < Error; end

        def initialize(api)
          @api = api
          @cache = {}
        end

        # Every work package a filter matches, across pages, up to `max`:
        # [code, elements, total]. On a failed page: [code, nil, 0].
        def all_work_packages(filters_json, sort_by: '[["id","asc"]]', max: nil, page_size: 100)
          elements = []
          total = 0
          (1..).each do |page|
            code, resp = @api.work_packages(filters_json: filters_json, page: page, page_size: page_size, sort_by: sort_by)
            return [code, nil, 0] unless code == 200 && resp
            total = resp["total"].to_i
            batch = resp.dig("_embedded", "elements") || []
            elements.concat(batch)
            break if batch.empty? || elements.length >= total || (max && elements.length >= max)
          end
          [200, max ? elements.first(max) : elements, total]
        end

        def statuses   = memo(:statuses)   { elements("statuses") { @api.statuses } }
        def priorities = memo(:priorities) { elements("priorities") { @api.priorities } }

        def status(name)   = Resource.find_named(statuses, name)
        def priority(name) = Resource.find_named(priorities, name)

        def types(project_id)
          memo([:types, project_id.to_s]) { elements("the types of project #{project_id}") { @api.project_types(project_id) } }
        end

        def type(project_id, name)
          return types(project_id).find { |t| t["id"].to_s == name.to_s } if name.to_s.match?(/\A\d+\z/)
          Resource.find_named(types(project_id), name)
        end

        def versions(project_id)
          memo([:versions, project_id.to_s]) do
            elements("the versions of project #{project_id}") { @api.project_versions(project_id) }
          end
        end

        def version(project_id, name) = Resource.find_named(versions(project_id), name)

        # The principal whose name is exactly `name`, ignoring case. The API's `=`
        # already ignores case; the check here makes an ambiguous name an error
        # instead of the first match.
        def principal(name)
          memo([:principal, name.to_s.downcase]) do
            filter = Query.filter("name", "=", name.to_s)
            found = elements("principals named #{name.inspect}") { @api.principals(filters_json: filter) }
            raise AmbiguousName, "#{found.length} principals are named #{name.inspect}" if found.length > 1
            found.first
          end
        end

        # The NUMERIC id of a work package or a project, given either spelling
        # ("PROJ-12", "my-project"). Routes typed Integer, filters that coerce
        # to Integer and payload links all need it; a semantic id there matches
        # nothing rather than failing.
        def work_package_id(id)
          return id.to_s if id.to_s.match?(/\A\d+\z/)
          memo([:work_package_id, id.to_s]) { read("work package #{id}") { @api.work_package(id) }["id"].to_s }
        end

        def project_id(id)
          return id.to_s if id.to_s.match?(/\A\d+\z/)
          memo([:project_id, id.to_s]) { read("project #{id}") { @api.project(id) }["id"].to_s }
        end

        # The schema of a (project, type) pair. Both ids NUMERIC, as the route needs.
        def schema(project_id, type_id)
          memo([:schema, project_id.to_s, type_id.to_s]) do
            read("the schema of #{project_id}-#{type_id}") { @api.work_package_schema(project_id, type_id) }
          end
        end

        # The payload key for a field's display name ("Customer" → "customField12",
        # "Priority" → "priority"), or nil. A key given as-is also resolves.
        def field_key(project_id, type_id, name)
          fields = schema(project_id, type_id).select { |key, node| node.is_a?(Hash) && !key.start_with?("_") }
          return name.to_s if fields.key?(name.to_s)
          fields.find { |_key, node| node["name"].to_s.casecmp?(name.to_s) }&.first
        end

        private

        def memo(key)
          return @cache[key] if @cache.key?(key)
          @cache[key] = yield
        end

        # The body of a 200, or the typed Error for what the read answered. A
        # NetworkError is re-raised with `what` in its message. Destructuring
        # rather than #value!, so a test fake may return a plain tuple.
        def read(what)
          code, body = begin
            yield
          rescue NetworkError => e
            raise NetworkError, "could not read #{what} (#{e.message})"
          end
          return body if code == 200 && body
          raise Error.for(code, body, "could not read #{what} (HTTP #{code})")
        end

        def elements(what, &block) = read(what, &block).dig("_embedded", "elements") || []
      end
    end
  end
end
