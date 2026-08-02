require "json"

module Chomper
  # The `pd` (product development) command family: the spec-driven pipeline that
  # turns OpenProject Documents into an OpenSpec change proposal, work packages,
  # and implementation PRs.
  #
  # Kept in its own namespace because the bug-fix verbs (plan/build/ship/pr) all
  # take a work-package id too, while doing something entirely different — and
  # because the identity rules differ (see #publish below).
  #
  # M0 implements `init` and `intake`; the later stages land in M1–M4.
  class ProductRunner
    include Helpers

    CHANGE_ID_PATTERN = /\A[a-z0-9][a-z0-9-]*\z/

    def initialize(ctx, op: nil, intake: nil)
      @ctx    = ctx
      @op     = op || Clients::OpenProject.new(ctx.op_url, ctx.token)
      @intake = intake || Intake.new(ctx, op: @op)
    end

    def run(argv)
      case argv[0]
      when "init"   then init(*argv[1..].to_a)
      when "intake" then intake(*argv[1..].to_a)
      else usage!(argv[0])
      end
    end

    # `pd init [--repo <name>]` — resolve the OpenProject ids and seed the
    # canonical spec store. Safe to re-run.
    def init(*args)
      opts       = parse_options(args)
      project_id = opts[:positional][0]
      usage!("init", "a project id is required") unless project_id

      repo = resolve_repo(opts[:repo])
      log_script "Resolving OpenProject ids for project #{project_id}…"
      data = ResolvedIds.new(@ctx, op: @op).resolve!(project_id)
      report_resolved(data)

      log_script "Seeding the canonical spec store for #{repo.name}…"
      store = ChangeStore.new(@ctx, repo)
      store.setup!
      puts "  ✓ store   #{store.root}"
      puts "  ✓ working #{store.working_tree} (git-excluded in the clone)"
      puts ""
      puts "  Next: ./chomper pd intake #{project_id} <change-id> [--doc-id <id>]"
      data
    end

    # `pd intake <project-id> <change-id> [--doc-id <id>]...` — mirror the
    # selected documents into the change's intake/ directory.
    def intake(*args)
      opts       = parse_options(args)
      project_id = opts[:positional][0]
      change_id  = opts[:positional][1]
      usage!("intake", "a project id and a change id are required") unless project_id && change_id
      validate_change_id!(change_id)

      repo  = resolve_repo(opts[:repo])
      store = ChangeStore.new(@ctx, repo)
      unless store.initialized?
        raise Chomper::FatalError, "no spec store for #{repo.name} yet — run `./chomper pd init #{project_id}` first"
      end

      state = state_for(change_id, store)
      store.materialise!

      scope = opts[:doc_ids].any? ? "#{opts[:doc_ids].length} document(s)" : "every document"
      log_script "Intake — project #{project_id}, #{scope} → change #{change_id}"
      result = @intake.fetch(state, project_id: project_id, doc_ids: opts[:doc_ids])

      unless result.changed?
        puts "  No change since the last intake (#{result.hash[0, 19]}…) — nothing written."
        return result
      end

      record_intake(state, project_id, opts[:doc_ids], result)
      store.persist!("Intake for #{change_id} (#{result.documents.length} document(s))")
      report_intake(result, state)
      result
    end

    private

    # The `pd` pipeline ALWAYS publishes as the contributor bot. FixRunner picks
    # its identity from the configured tokens; this must not, because every `pd`
    # push targets the bot's own fork. The CLI already refuses to dispatch `pd`
    # at all when a maintainer token is set — this is the second belt, so the
    # guard is never the only thing standing between `pd` and a canonical push.
    def publish
      @publish ||= Publish.new(@ctx, as: :contributor)
    end

    def resolve_repo(name)
      return @ctx.default_repo unless name
      @ctx.repos[name] ||
        raise(Chomper::FatalError,
              "unknown repo #{name.inspect} — repos.json has: #{@ctx.repos.all.map(&:name).join(", ")}")
    end

    def state_for(change_id, store)
      dir = Helpers.change_dir(@ctx, change_id)
      dir.mkpath
      ChangeState.new(change_id: change_id, store: store, state_dir: dir)
    end

    # change-id is author-supplied and becomes a directory name that everything
    # downstream binds to, so it is validated rather than sanitised — silently
    # rewriting it would break the binding the operator thinks they created.
    def validate_change_id!(change_id)
      return if change_id.match?(CHANGE_ID_PATTERN)
      raise Chomper::FatalError,
            "invalid change id #{change_id.inspect} — use kebab-case: lowercase letters, " \
            "digits and hyphens, starting with a letter or digit (e.g. add-recurring-meetings)"
    end

    def record_intake(state, project_id, doc_ids, result)
      state.merge_tracker(
        "change_id"     => state.change_id,
        "repo"          => state.repo.name,
        "project_id"    => project_id.to_s,
        "intake"        => {
          "hash"      => result.hash,
          "selection" => doc_ids.map(&:to_s),
          "documents" => result.documents.map do |d|
            { "id" => d["id"], "title" => d["title"].to_s,
              "updated_at" => d["updatedAt"] || d["updated_at"] }
          end
        },
        "unconvertible" => result.unconvertible
      )
    end

    def report_resolved(data)
      puts "  ✓ project  #{data["project_id"]}  #{data["project_name"]}"
      %w[parent child].each do |role|
        t = data.dig("types", role)
        puts "  ✓ type #{role.ljust(6)} #{t["name"]} (#{t["id"]})"
      end
      closed = ResolvedIds.closed_status_ids(data)
      puts "  ✓ statuses #{data["statuses"].length} (#{closed.length} closed)"
    end

    def report_intake(result, state)
      result.documents.each_with_index do |doc, i|
        puts "  ✓ ##{doc["id"]}  #{doc["title"]}  (#{doc["updatedAt"] || doc["updated_at"]})"
        puts "     #{format("%03d", i + 1)}-… .md"
      end
      if result.unconvertible.any?
        puts ""
        puts "  ⚠ #{result.unconvertible.length} attachment(s) could not be read — a requirement"
        puts "    hiding in one of these is MISSING from this intake:"
        result.unconvertible.each { |u| puts "      ##{u["document"]} #{u["file"]} — #{u["reason"]}" }
      end
      puts ""
      puts "  intake → #{state.intake_dir}"
    end

    # Minimal flag parsing: --repo <name> and repeatable --doc-id <id>.
    # Deliberately not OptionParser — chomper's other commands hand-roll their
    # argv handling too, and this keeps the "unknown flag" error in one voice.
    def parse_options(args)
      opts = { positional: [], doc_ids: [], repo: nil }
      # Split `--flag=value` into two tokens up front, so each flag needs one
      # arm below instead of one per spelling.
      queue = args.flat_map { |a| (m = /\A(--[a-z-]+)=(.*)\z/m.match(a)) ? [m[1], m[2]] : [a] }
      until queue.empty?
        arg = queue.shift
        case arg
        when "--doc-id" then opts[:doc_ids] << require_value!(queue, arg)
        when "--repo"   then opts[:repo] = require_value!(queue, arg)
        when /\A-/      then raise Chomper::FatalError, "unknown option #{arg.inspect}"
        else opts[:positional] << arg
        end
      end
      opts
    end

    def require_value!(queue, flag)
      value = queue.shift
      raise Chomper::FatalError, "#{flag} needs a value" if value.nil? || value.start_with?("-")
      value
    end

    def usage!(subcommand, reason = nil)
      message = reason ? "#{reason}\n\n" : "unknown pd subcommand #{subcommand.inspect}\n\n"
      raise Chomper::FatalError, message + <<~USAGE.strip
        Usage: ./chomper pd <command>

          init <project-id> [--repo <name>]
              Resolve the OpenProject ids and seed the canonical spec store.

          intake <project-id> <change-id> [--doc-id <id>]... [--repo <name>]
              Mirror OpenProject Documents into the change's intake/ directory.
              Without --doc-id every document in the project is pulled in.

        change-id is author-chosen kebab-case (e.g. add-recurring-meetings).
      USAGE
    end
  end
end
