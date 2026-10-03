require "json"

module OPilot
  module Runners
    # `./opilot appsignal`: a production error becomes a work package and a draft PR.
    # `fix` sends incident data to the model, so #require_local_inference! fails
    # closed. See CLAUDE.md, appsignal.
    #
    # `apps` and `incident list|get` only read, as `op` does: JSON on stdout,
    # messages on stderr. They call no model, so the guard does not apply.
    class AppSignal
      Resource = Clients::OpenProject::Resource

      include Helpers

      FIX_FLAGS  = %w[project type app].freeze
      LIST_FLAGS = %w[app state sort search namespace limit page].freeze

      # The verbs that only read. CLI runs them without a session.
      READ_COMMANDS = %w[apps incident].freeze

      STATES = { "open" => "OPEN", "closed" => "CLOSED", "wip" => "WIP", "all" => nil }.freeze
      SORTS  = { "last" => "LAST", "total" => "TOTAL", "id" => "ID" }.freeze

      def initialize(ctx, harness: Harness.new(ctx), api: nil, appsignal: nil, fix_runner: nil)
        @ctx       = ctx
        @harness   = harness
        @api       = api || Clients::OpenProject::Client.new(ctx.op_url, ctx.token)
        @appsignal = appsignal
        @fix_runner = fix_runner
      end

      # `fix` is the only verb, so a bare incident number is accepted too.
      def run(args)
        sub, *rest = args
        return apps(rest) if sub == "apps"
        return incident(rest) if sub == "incident"
        return fix(rest) if sub == "fix"
        return fix(args) if sub.to_s.match?(/\A#?\d+\z/)

        $stderr.puts "unknown appsignal subcommand #{sub.inspect}"
        UI.new(@ctx).appsignal_usage
        raise OPilot::FatalError
      rescue Clients::AppSignal::Error => e
        # One line, not a backtrace. The client has already scrubbed the token.
        raise OPilot::FatalError, "AppSignal: #{e.message}"
      end

      private

      def apps(args)
        reject!("appsignal apps", "takes no arguments") if args.any?
        emit(appsignal.applications)
      end

      def incident(args)
        action, *rest = args
        case action
        when "list" then list_incidents(rest)
        when "get"  then get_incident(rest)
        else reject!("appsignal incident", "unknown action #{action.inspect}. It takes: list, get.")
        end
      end

      def list_incidents(args)
        command = "appsignal incident list"
        opts, rest = flags(command, args, LIST_FLAGS)
        reject!(command, "takes no arguments, only flags") if rest.any?
        state = choice!(command, "state", opts["state"] || "open", STATES)
        order = choice!(command, "sort", opts["sort"] || "last", SORTS)
        limit = positive!(command, "limit", opts["limit"] || "25")
        page  = positive!(command, "page", opts["page"] || "1")
        resolve_app!(opts["app"], quiet: true)

        emit(appsignal.exception_incidents(@app, state: state, order: order, query: opts["search"],
                                                 namespace: opts["namespace"], limit: limit,
                                                 offset: (page - 1) * limit))
      end

      def get_incident(args)
        command = "appsignal incident get"
        opts, rest = flags(command, args, %w[app])
        number = rest.first.to_s.strip.delete_prefix("#")
        reject!(command, "needs one incident number, e.g. 4711") unless rest.length == 1 && number.match?(/\A\d+\z/)
        resolve_app!(opts["app"], quiet: true)

        emit(appsignal.incident(@app, number))
      end

      # stdout is data, as in Runners::Op.
      def emit(data) = $stdout.puts(JSON.pretty_generate(data))

      def choice!(command, flag, value, allowed)
        key = value.downcase
        return allowed[key] if allowed.key?(key)
        reject!(command, "--#{flag} takes #{allowed.keys.join(", ")}, not #{value.inspect}")
      end

      def positive!(command, flag, value)
        reject!(command, "--#{flag} takes a positive number, not #{value.inspect}") unless value.match?(/\A[1-9]\d*\z/)
        value.to_i
      end

      def fix(args)
        opts, rest = flags("appsignal fix", args, FIX_FLAGS)
        Helpers.usage!("appsignal fix", "<incident-number> [--project <id>] [--type <name>] [--app <id-or-name>]") \
          unless rest.length == 1
        number  = rest.first.to_s.strip.delete_prefix("#")
        Helpers.usage!("appsignal fix", "<incident-number>", "e.g. 4711") unless number.match?(/\A\d+\z/)

        # Preflighted before the LLM call, because a work package cannot be deleted.
        # A re-run below still needs all four.
        require_local_inference!
        resolve_app!(opts["app"])
        ensure_harness!
        require_publish_token!

        dir = Helpers.incident_dir(@ctx, @app, number)
        dir.mkpath

        # An existing work package is the answer; never create a second one.
        # Checked before the project, so a re-run does not need --project.
        if Helpers.file_has_content?(dir / "wp_id.txt")
          existing = (dir / "wp_id.txt").read.strip
          puts "  Incident ##{number} is already work package #{wp_label(existing)}."
          return build(existing)
        end

        # One value for both the TYPE menu and the payload's type link, so they cannot drift.
        @project = opts["project"] || @ctx.appsignal_project
        raise OPilot::FatalError, "No project — pass --project <id> or set OPILOT_APPSIGNAL_PROJECT in .env." \
          unless @project
        # --type overrides the writer's TYPE: line: the operator sees the real type list.
        @type_override = opts["type"]

        @project_json = require_create_permission!(@project)

        draft = drafted_work_package(dir, number)
        return unless draft
        return unless confirm_create(draft)

        wp_id = create_work_package(draft)
        return unless wp_id
        (dir / "wp_id.txt").write(wp_id)
        record_progress(wp_id, "-", "appsignal:#{number}")

        build(wp_id)
      end

      # The normal plan → implement → publish pipeline, with the validated harness.
      def build(wp_id)
        (@fix_runner || Runners::Fix.new(@ctx, harness: @harness)).ship_ids(wp_id)
      end

      # inference-gw answers this, not a lookup here (Context#inference_privacy).
      def require_local_inference!
        allowed, why = @ctx.inference_privacy
        return if allowed

        raise OPilot::FatalError, <<~MSG.strip
          Refusing to run: opilot cannot confirm the model is local.

          `appsignal` sends production error data — messages and backtraces — to
          the model, so it runs only against an endpoint on your own network.

          OPILOT_INFERENCE_URL is #{@ctx.inference_url}
          #{why}

          Point OPILOT_INFERENCE_URL at a server on your own network
          (http://host.docker.internal:11434/v1 reaches Ollama on this machine)
          and re-run.
        MSG
      end

      # Fail before the work package exists, not at the push.
      def require_publish_token!
        publish = GitHub::Publish.new(@ctx)
        return if publish.author_token
        raise OPilot::FatalError,
              "No GitHub token — set #{publish.token_env_var} in .env. `appsignal fix` ends at a draft PR."
      end

      # The createWorkPackage links exist only for a user with :add_work_packages.
      def require_create_permission!(project)
        res = @api.project(project)
        raise OPilot::FatalError, "Could not read project #{project} (HTTP #{res.code})." unless res.ok?
        unless Resource.create_wp_allowed?(res.body)
          raise OPilot::FatalError,
                "My OpenProject token cannot create work packages in #{res.body["name"]} — it has no " \
                "`add_work_packages` permission there. Ask an administrator for it."
        end
        res.body
      end

      # Cached in draft.json before the confirm prompt, so a re-run or an abort
      # never pays for the same LLM call twice.
      def drafted_work_package(dir, number)
        draft_file = dir / "draft.json"
        if Helpers.file_has_content?(draft_file)
          draft = Helpers.safe_json_read(draft_file)
          if draft
            puts "  Reusing the work package already drafted from incident ##{number}."
            return draft
          end
        end

        incident_file = dir / "incident.json"
        log_script "Fetching AppSignal incident ##{number}…"
        incident_file.write(JSON.pretty_generate(appsignal.incident(@app, number)))

        draft = write_work_package(number, incident_file)
        return nil unless draft
        draft_file.write(JSON.pretty_generate(draft))
        draft
      end

      # One LLM call, one retry (safe: nothing is created yet). Returns the block or nil.
      def write_work_package(number, incident_file, retry_bad: true, format_note: nil)
        log_script "Drafting a work package from AppSignal incident ##{number}…"
        prompt = Prompts::Triager.appsignal_wp(
          incident: container_path(incident_file), number: number, app: @app,
          repos: repos_for_prompt(@ctx.repos.all), types: Helpers.types_for_prompt(project_types), format_note: format_note
        )
        reply  = llm(:triager, prompt).to_s
        answer = Helpers.after_marker(reply, "ANSWER")

        if (questions = Helpers.needs_info(answer))
          puts ""
          puts "  ⚠ Not enough in this incident to write a work package:"
          puts questions.lines.map { |l| "    #{l}" }.join
          puts ""
          return nil
        end

        draft = Helpers.parse_work_packages(answer).first
        return draft if draft
        return write_work_package(number, incident_file, retry_bad: false,
                                  format_note: Helpers.wp_format_miss(answer)) if retry_bad

        log_script "AppSignal ##{number} — the writer produced no usable work-package block twice."
        puts "  ⚠ Could not draft a work package from this incident."
        nil
      end

      # A work package cannot be deleted, so a person sees it before the POST.
      def confirm_create(draft)
        puts ""
        puts "  #{Rainbow(draft["subject"]).bold}"
        puts "  #{Rainbow("#{draft_type_name(draft)} in #{@project_json["name"]}").dimgray}"
        puts ""
        puts render_markdown(draft["description"])
        puts ""
        ping_terminal("opilot: work package drafted from the incident")
        prompt_choice("[y]es create it / [a]bort",
                      { create: %w[y yes], abort: %w[a abort] }, default: :create) == :create
      end

      # Preflight through the create form, then create. See CLAUDE.md, `:create_wp`.
      def create_work_package(draft)
        payload = payload_for(draft)
        return nil unless payload_accepted?(payload)

        res = @api.create_work_package(payload)
        unless res.ok?
          puts "  ⚠ Could not create the work package (HTTP #{res.code}). The response is in my log."
          log_script "appsignal create failed — HTTP #{res.code} on #{payload["subject"].inspect}"
          return nil
        end
        id = (res.body["id"] || res.body["_meta"]&.dig("id")).to_s
        puts "  ✓ Created #{wp_label(id)} — #{Helpers.wp_url(@ctx, id)}"
        id
      end

      # No match leaves the type out, and OpenProject assigns the project's own
      # default — better than refusing over a name the writer guessed.
      def payload_for(draft)
        Clients::OpenProject::Payload.work_package(
          project: @project, type: Resource.find_named(project_types, draft_type_name(draft)),
          subject: draft["subject"], description: draft["description"]
        )
      end

      # --type wins over the writer's TYPE: line — see #fix.
      def draft_type_name(draft) = @type_override || draft["type"]

      def payload_accepted?(payload)
        form = @api.create_work_package_form(payload)
        # A form that did not run gives no verdict; let the create report itself.
        log_script "The create form answered HTTP #{form.code}; creating without it." \
          unless form.form_answered?
        errors = form.validation_errors
        return true unless errors

        errors = hack_required_custom_fields!(payload, form.body, errors)
        return true unless errors

        # opilot must not fill a required custom field: only a person knows the value.
        puts ""
        puts "  ⚠ #{@project_json["name"]} needs values I must not invent:"
        errors.each { |field, error| puts "    - #{error["message"]} (`#{field}`)" }
        puts ""
        puts "  Create the work package in OpenProject, then run `./opilot dev build <id>`."
        false
      end

      # A narrow exception to "never invent a required custom field": opilot's own
      # test fields, kept to exercise the create-form path. Matched by name only,
      # so every other field still refuses. Keys are lower-case and stripped,
      # because the instance's names carry stray casing and a trailing space.
      CF_VALUE_HACKS = {
        "bug found in version"                                  => :highest,
        "cécile list type multi select custom field"            => :random,
        "cécile hierarchy notafilter singleselect required cf"  => :random,
        "cécile's 1st scored list"                               => :random
      }.freeze

      # Fill the recognized fields, then re-check the form: a wrong link shape would
      # be permanent. Returns the remaining errors, or nil.
      def hack_required_custom_fields!(payload, form, errors)
        schema = Resource.schema_fields(form.dig("_embedded", "schema"))
        filled = []

        errors.each_key do |field|
          node     = schema[field]
          strategy = node && CF_VALUE_HACKS[node["name"].to_s.strip.downcase]
          next unless strategy

          href = hacked_custom_field_href(node, strategy)
          next unless href

          payload["_links"][field] = node["type"].to_s.start_with?("[]") ? [{ "href" => href }] : { "href" => href }
          filled << node["name"]
        end
        return errors if filled.empty?

        log_script "appsignal: invented a value for #{filled.join(", ")} (allowlisted test field#{"s" if filled.length > 1})."
        @api.create_work_package_form(payload).validation_errors
      end

      def hacked_custom_field_href(node, strategy)
        candidates = begin
          Clients::OpenProject::Lookup.new(@api).allowed_values(node)
        rescue Clients::OpenProject::Error
          nil
        end
        return nil if candidates.to_a.empty?

        case strategy
        # The titles are noise, not version numbers, so "highest" means the highest id.
        when :highest then candidates.max_by { |c| c["href"].to_s[/\d+\z/].to_i }["href"]
        when :random  then candidates.sample["href"]
        end
      end

      def project_types
        @project_types ||= begin
          res = @api.project_types(@project)
          res.ok? ? Resource.type_list(res.body) : []
        end
      end

      def appsignal
        @appsignal ||= begin
          raise OPilot::FatalError, "AppSignal is not configured — set APPSIGNAL_API_TOKEN in .env." \
            unless @ctx.appsignal_token
          Clients::AppSignal.new(@ctx.appsignal_token)
        end
      end

      # AppSignal's app id. A name is accepted too.
      APP_ID = /\A[0-9a-f]{24}\z/

      # Resolves a name to an id; the API answers a name with `Object not found`.
      # A name that matches several apps is refused: staging and production must
      # never be confused.
      # `quiet` sends the note to stderr, so a read command keeps stdout for data.
      def resolve_app!(flag, quiet: false)
        given = flag || @ctx.appsignal_app_id
        raise OPilot::FatalError, no_app_message("Name the AppSignal app") unless given
        return @app = given if given.match?(APP_ID)

        matches = applications.select { |a| a["name"].to_s.casecmp?(given) }
        raise OPilot::FatalError, no_app_message("No AppSignal app is named #{given.inspect}") if matches.empty?
        if matches.length > 1
          raise OPilot::FatalError, no_app_message("#{given.inspect} names #{matches.length} apps, " \
                                                   "so give the id instead")
        end

        @app = matches.first["id"]
        note = "AppSignal app #{given} is #{@app} (#{matches.first["environment"]})"
        quiet ? $stderr.puts(note) : log_script(note)
      end

      def no_app_message(opening)
        <<~MSG.strip
          #{opening}: pass --app <app-id-or-name>, or set APPSIGNAL_APP_ID in .env.

          #{indent(applications_list)}
        MSG
      end

      def applications
        @applications ||= appsignal.applications
      end

      # Best-effort: a failed list must not hide the "name your app" message.
      def applications_list
        return "(This token can see no applications.)" if applications.empty?
        applications.map { |a| "#{a["id"]}  #{a["name"]} (#{a["environment"]})" }.join("\n")
      rescue Clients::AppSignal::Error, OPilot::FatalError => e
        "(Could not list your apps: #{e.message})"
      end

      def indent(text) = text.to_s.lines.map { |l| "  #{l}" }.join

      # --- argument plumbing, mirroring Runners::Op's ------------------------------

      # Like Runners::Op#flags, but no flag repeats: the last one wins.
      def flags(command, args, allowed)
        opts = {}
        rest = []
        args = args.dup
        until args.empty?
          arg = args.shift
          unless arg.start_with?("--")
            rest << arg
            next
          end
          name = arg.delete_prefix("--")
          # Names the flags the command takes (see Runners::Op#reject!).
          reject!(command, "unknown flag --#{name}. It takes: #{allowed.map { |f| "--#{f}" }.join(", ")}.") \
            unless allowed.include?(name)
          value = args.shift
          reject!(command, "--#{name} needs a value") if value.nil?
          opts[name] = value
        end
        [opts, rest]
      end

      def reject!(command, message)
        $stderr.puts "#{command}: #{message}"
        $stderr.puts "Run `./opilot appsignal --help` for the full usage."
        raise OPilot::FatalError
      end
    end
  end
end
