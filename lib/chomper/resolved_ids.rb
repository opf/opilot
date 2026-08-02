require "json"

module Chomper
  # Stage 0 of the `pd` pipeline: resolve the OpenProject ids the rest of the
  # pipeline writes against, once, and cache them.
  #
  # Everything here is resolved BY NAME. `FEATURE` and `IMPLEMENTATION` are not
  # stock OpenProject types, and ids differ per instance, so hardcoding either
  # would break on the next instance and fail as an opaque 422 from a POST two
  # stages later. Resolution fails fast instead, listing exactly what is
  # missing and what the project does offer.
  #
  # Statuses are cached with their `isClosed` flag rather than mapped to names:
  # auto-archive only ever asks "is this child closed?", which the flag answers
  # without anyone having to name the instance's workflow states.
  #
  # Treated as a cache (§7 of the design): delete the file and re-run `pd init`.
  class ResolvedIds
    include Helpers

    Error = Class.new(StandardError)

    def initialize(ctx, op: nil)
      @ctx = ctx
      @op  = op || Clients::OpenProject.new(ctx.op_url, ctx.token)
    end

    # .chomper/work_packages/<op_host>/resolved-ids.json — beside the saved
    # agent filters, in the same per-instance namespace, since these ids are
    # meaningless against a different OpenProject.
    def path
      Helpers.items_dir(@ctx) / "resolved-ids.json"
    end

    def read
      Helpers.safe_json_read(path) || {}
    end

    def resolved_for?(project_id)
      read["project_id"].to_s == project_id.to_s
    end

    # Resolve and cache. Raises Chomper::FatalError listing every failure at
    # once — one round trip of fixing, rather than one error per re-run.
    def resolve!(project_id)
      problems = []

      project = fetch_project(project_id, problems)
      types   = fetch_types(project_id, problems)
      parent  = find_type(types, @ctx.pd_parent_type, problems)
      child   = find_type(types, @ctx.pd_child_type, problems)
      statuses = fetch_statuses(problems)

      raise Chomper::FatalError, failure_message(project_id, types, problems) if problems.any?

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

    # The cached ids, resolving them first if the cache is missing or points at
    # a different project.
    def ensure!(project_id)
      resolved_for?(project_id) ? read : resolve!(project_id)
    end

    def self.closed_status_ids(data)
      Array(data["statuses"]).select { |s| s["closed"] }.map { |s| s["id"] }
    end

    private

    def fetch_project(project_id, problems)
      code, body = @op.project(project_id)
      return body if code == 200
      problems << "project #{project_id} is not readable (HTTP #{code})"
      {}
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
      code, body = @op.statuses
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

    def failure_message(project_id, types, problems)
      available = types.map { |t| t["name"] }.sort.join(", ")
      <<~MSG.strip
        Could not resolve the OpenProject ids for project #{project_id}:
        #{problems.map { |p| "  ✗ #{p}" }.join("\n")}

        Types available on this project: #{available.empty? ? "(none readable)" : available}
        Set CHOMPER_PD_PARENT_TYPE / CHOMPER_PD_CHILD_TYPE to match, or add the
        types to the project in OpenProject.
      MSG
    end
  end
end
