require "json"

module OPilot
  module PD
    # Stage 0 of the `pd` pipeline: resolve the OpenProject ids the later stages
    # write against, once, and cache them (delete the file and re-run `pd init`).
    #
    # All BY NAME: `FEATURE`/`IMPLEMENTATION` aren't stock types and ids differ per
    # instance, so a hardcoded id would surface as an opaque 422 from a POST two
    # stages later. This fails fast instead, listing what's missing and what the
    # project does offer. Statuses carry their `isClosed` flag rather than names,
    # since the only question asked of them is "is this child closed?".
    class ResolvedIds
      include Helpers

      Error = Class.new(StandardError)

      def initialize(ctx, op: nil)
        @ctx = ctx
        @op  = op || Clients::OpenProject.new(ctx.op_url, ctx.token)
      end

      # .opilot/work_packages/<op_host>/resolved-ids.json — beside the saved
      # agent filters, in the same per-instance namespace, since these ids are
      # meaningless against a different OpenProject.
      def path
        Helpers.items_dir(@ctx) / "resolved-ids.json"
      end

      def read
        Helpers.safe_json_read(path) || {}
      end

      # Resolve and cache. Raises OPilot::FatalError listing every failure at
      # once — one round trip of fixing, rather than one error per re-run.
      def resolve!(project_id)
        problems = []

        project = fetch_project(project_id, problems)
        types   = fetch_types(project_id, problems)
        parent  = find_type(types, @ctx.pd_parent_type, problems)
        child   = find_type(types, @ctx.pd_child_type, problems)
        statuses = fetch_statuses(problems)
        find_statuses(statuses, problems)

        raise OPilot::FatalError, failure_message(project_id, types, statuses, problems) if problems.any?

        data = {
          "project_id"   => project_id.to_s,
          "project_name" => project["name"],
          "types"        => { "parent" => parent, "child" => child },
          "statuses"     => statuses,
          "resolved_at"  => Time.now.utc.iso8601
        }
        path.dirname.mkpath
        # Atomic, like every sibling cache in this directory (agent_filters.json,
        # gh_pr.json, …): a kill mid-write would otherwise leave a truncated file
        # that safe_json_read turns into {} without saying so.
        Helpers.write_json_atomic(path, data, "resolved_ids", pretty: true)
        data
      end

      def self.closed_status_ids(data)
        Array(data["statuses"]).select { |s| s["closed"] }.map { |s| s["id"] }
      end

      private

      def fetch_project(project_id, problems)
        code, body = @op.project(project_id)
        unless code == 200
          problems << "project #{project_id} is not readable (HTTP #{code})"
          return {}
        end
        check_write_permission(project_id, body, problems)
        body
      end

      # `pd generate-wp` POSTs work packages into this project, and a token that can
      # read but not write only reveals that after a proposal has been written and a
      # spec PR opened. OpenProject renders the `createWorkPackage*` links only for
      # a user with :add_work_packages in the project, so their absence is a real
      # answer rather than a guess.
      WRITE_LINKS = %w[createWorkPackageImmediately createWorkPackage].freeze

      def check_write_permission(project_id, body, problems)
        links = body["_links"] || {}
        return if WRITE_LINKS.any? { |name| links.key?(name) }
        problems << "this token cannot create work packages in project #{project_id} " \
                    "(no :add_work_packages) — `pd generate-wp` would fail"
      end

      def fetch_types(project_id, problems)
        code, body = @op.project_types(project_id)
        unless code == 200
          problems << "could not list types for project #{project_id} (HTTP #{code})"
          return []
        end
        (body&.dig("_embedded", "elements") || []).map { |t| { "id" => t["id"], "name" => t["name"].to_s } }
      end

      def fetch_statuses(problems)
        # #statuses raises on a non-200 (get_json!), so the code is never inspected
        # here — the rescue below is what reports a failure.
        _code, body = @op.statuses
        (body&.dig("_embedded", "elements") || []).map do |s|
          { "id" => s["id"], "name" => s["name"].to_s, "closed" => !!s["isClosed"] }
        end
      rescue StandardError => e
        problems << "could not list statuses (#{e.message})"
        []
      end

      # Case-insensitive: instances style these names inconsistently ("Feature",
      # "FEATURE"), and an exact-match failure here would be pure friction.
      def find_type(types, name, problems)
        found = types.find { |t| t["name"].casecmp?(name) }
        problems << "no work-package type named #{name.inspect} on this project" unless found
        found
      end

      # The statuses `pd implement` transitions a work package through. Checked here
      # rather than at implement time: a name this instance doesn't have would
      # otherwise surface as a warning after the spec PR is up and the code is
      # committed — the same "opaque failure two stages later" the type resolution
      # exists to prevent. An empty name means that transition is switched off.
      def find_statuses(statuses, problems)
        [@ctx.pd_implementing_status, @ctx.pd_implemented_status].reject { |n| n.to_s.empty? }.uniq.each do |name|
          next if statuses.any? { |s| s["name"].to_s.casecmp?(name) }
          problems << "no status named #{name.inspect} on this instance " \
                      "(`pd implement` transitions work packages through it)"
        end
      end

      def failure_message(project_id, types, statuses, problems)
        available = types.map { |t| t["name"] }.sort.join(", ")
        msg = <<~MSG
          Could not resolve the OpenProject ids for project #{project_id}:
          #{problems.map { |p| "  ✗ #{p}" }.join("\n")}

          Types available on this project: #{available.empty? ? "(none readable)" : available}
          Set OPILOT_PD_PARENT_TYPE / OPILOT_PD_CHILD_TYPE to match, or add the
          types to the project in OpenProject.
        MSG
        # Only when a status is what failed: the list is long on a real instance,
        # and printing it every time would bury the type message.
        return msg.strip unless problems.any? { |p| p.start_with?("no status named") }
        msg + <<~MSG.chomp
          \nStatuses on this instance: #{statuses.map { |s| s["name"] }.join(", ")}
          Set OPILOT_PD_IMPLEMENTING_STATUS / OPILOT_PD_IMPLEMENTED_STATUS to match
          (empty turns that transition off).
        MSG
      end
    end
  end
end
