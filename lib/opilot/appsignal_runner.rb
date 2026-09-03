require "json"

module OPilot
  # `./opilot appsignal` — turn a production error into a work package and a
  # draft PR.
  #
  # This is the one command that sends PRODUCTION INCIDENT DATA to the model, and
  # that is why it exists: TODO.md listed an AppSignal integration for a long
  # time and blocked it on exactly that, because opilot must not hand user data
  # to a third-party model. It is unblocked by the model being local, not by the
  # objection having gone away — so #require_local_inference! is a hard gate, not
  # a warning, and it fails closed.
  #
  # `fix` does almost nothing itself. Once the work package exists,
  # FixRunner#ship_ids is already the whole plan → approve → implement → publish
  # pipeline, with its own approval prompts. What is new here is only: read the
  # incident, write one work package, create it.
  #
  # It owns its own subcommand dispatch, like OpRunner and PD::Runner.
  class AppSignalRunner
    include Helpers

    FIX_FLAGS = %w[project type app].freeze

    def initialize(ctx, harness: Harness.new(ctx), api: nil, appsignal: nil, fix_runner: nil)
      @ctx       = ctx
      @harness   = harness
      @api       = api || Clients::OpenProject.new(ctx.op_url, ctx.token)
      @appsignal = appsignal
      @fix_runner = fix_runner
    end

    # `fix` is the only verb, so a bare incident number is accepted too:
    # `./opilot appsignal 2025` reads the same as `appsignal fix 2025`, and
    # there is nothing else it could have meant.
    def run(args)
      sub, *rest = args
      return fix(rest) if sub == "fix"
      return fix(args) if sub.to_s.match?(/\A#?\d+\z/)

      $stderr.puts "unknown appsignal subcommand #{sub.inspect}"
      UI.new(@ctx).appsignal_usage
      raise OPilot::FatalError
    rescue Clients::AppSignal::Error => e
      # An API failure is a fact about the run, not a bug in opilot, so it reads
      # as one line rather than as a Ruby backtrace. The client has already
      # scrubbed the token out of the message.
      raise OPilot::FatalError, "AppSignal: #{e.message}"
    end

    private

    def fix(args)
      opts, rest = flags("appsignal fix", args, FIX_FLAGS)
      Helpers.usage!("appsignal fix", "<incident-number> [--project <id>] [--type <name>] [--app <id-or-name>]") \
        unless rest.length == 1
      number  = rest.first.to_s.strip.delete_prefix("#")
      Helpers.usage!("appsignal fix", "<incident-number>", "e.g. 4711") unless number.match?(/\A\d+\z/)

      # Preflighted BEFORE the LLM call, because a work package can never be
      # deleted: the guard, the harness, and the token that publishing needs.
      # These four hold for BOTH paths below — a re-run still plans, implements
      # and publishes, so it still needs a local model and somewhere to push.
      require_local_inference!
      resolve_app!(opts["app"])
      ensure_harness!
      require_publish_token!

      dir = Helpers.incident_dir(@ctx, @app, number)
      dir.mkpath

      # Created from this incident already? Then that work package IS the
      # answer, and asking again must not mint a second one for the same error.
      # Asked BEFORE the project is resolved, because nothing below this line
      # runs on a re-run: demanding --project to resume a build would refuse the
      # one path that creates nothing.
      if Helpers.file_has_content?(dir / "wp_id.txt")
        existing = (dir / "wp_id.txt").read.strip
        puts "  Incident ##{number} is already work package #{wp_label(existing)}."
        return build(existing)
      end

      # Held on the instance because the type list is resolved against it in two
      # places — the draft's TYPE menu and the payload's type link — and reading
      # the flag in one and the env var in the other is exactly how those two
      # drift apart.
      @project = opts["project"] || @ctx.appsignal_project
      raise OPilot::FatalError, "No project — pass --project <id> or set OPILOT_APPSIGNAL_PROJECT in .env." \
        unless @project
      # An operator naming the type OVERRIDES the writer's TYPE: line. They can
      # see the project's own type list and the writer is guessing from a
      # backtrace, so the flag has to win — otherwise a wrong type costs a whole
      # re-run of a command that will not create anything the second time.
      @type_override = opts["type"]

      # The permission the create needs, checked before the draft is written.
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

    # The whole existing pipeline, unchanged: plan, approve, implement, publish,
    # with its own prompts. Nothing about a fix that started at an incident makes
    # it different from one that started at a work package — by this point it IS
    # a work package.
    def build(wp_id)
      # The harness is handed on rather than rebuilt: it holds the connection
      # settings this run already validated with #ensure_harness!.
      (@fix_runner || FixRunner.new(@ctx, harness: @harness)).ship_ids(wp_id)
    end

    # The gate this command exists behind.
    #
    # inference-gw answers it, not a lookup here — see Context#inference_privacy. The
    # message names the endpoint, because "refused" without it sends the reader
    # to the wrong file.
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

    # `fix` ends in a push and a PR, so a missing token must fail here rather
    # than after a fetch, an LLM call and a work package that cannot be deleted.
    def require_publish_token!
      publish = Publish.new(@ctx)
      return if publish.author_token
      raise OPilot::FatalError,
            "No GitHub token — set #{publish.token_env_var} in .env. `appsignal fix` ends at a draft PR."
    end

    # OpenProject renders the createWorkPackage links only for a user who holds
    # :add_work_packages, so their absence is an answer rather than a guess —
    # and asking now costs one request instead of a whole draft.
    def require_create_permission!(project)
      code, json = @api.project(project)
      raise OPilot::FatalError, "Could not read project #{project} (HTTP #{code})." unless code == 200 && json
      unless Helpers.create_wp_allowed?(json)
        raise OPilot::FatalError,
              "My OpenProject token cannot create work packages in #{json["name"]} — it has no " \
              "`add_work_packages` permission there. Ask an administrator for it."
      end
      json
    end

    # The draft to show at #confirm_create — cached on disk so a re-run (the
    # form rejected it, the operator aborted, the process died) never re-spends
    # the LLM call that wrote it. Written the instant a usable draft exists,
    # BEFORE the confirm prompt: an abort must not lose it, or the next run pays
    # for the same draft twice.
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

    # One LLM call. Returns the parsed block, or nil having said why.
    #
    # One retry, and it is safe for the same reason Agent#write_work_packages'
    # is: nothing has been created yet, so the failure it covers is a lost
    # request rather than a duplicate work package.
    def write_work_package(number, incident_file, retry_bad: true, format_note: nil)
      log_script "Drafting a work package from AppSignal incident ##{number}…"
      prompt = Prompts.appsignal_wp(
        incident: container_path(incident_file), number: number, app: @app,
        repos: repos_for_prompt(@ctx.repos.all), types: Helpers.types_for_prompt(project_types), format_note: format_note
      )
      reply  = @harness.run(prompt, tools: read_tools, model: Harness::MODEL_HEAVY).to_s
      answer = Helpers.after_marker(reply, "ANSWER")

      if answer.lstrip.start_with?("NEEDS_INFO")
        puts ""
        puts "  ⚠ Not enough in this incident to write a work package:"
        puts answer.sub(/\A\s*NEEDS_INFO\s*\n?/, "").strip.lines.map { |l| "    #{l}" }.join
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

    # Show the draft and ask. A work package cannot be deleted, so a person sees
    # it before the POST even though `fix` is otherwise a one-command flow.
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

    # Preflight, then create. The form runs the same SetAttributesService the
    # create runs and does not save, so a payload it accepts is one the create
    # accepts — and it answers 200 even for a payload it rejects, which is why
    # `_embedded.validationErrors` decides and the status code does not.
    def create_work_package(draft)
      payload = payload_for(draft)
      return nil unless payload_accepted?(payload)

      code, body = @api.create_work_package(payload)
      unless code == 201 && body
        puts "  ⚠ Could not create the work package (HTTP #{code}). The response is in my log."
        log_script "appsignal create failed — HTTP #{code} on #{payload["subject"].inspect}"
        return nil
      end
      id = (body["id"] || body["_meta"]&.dig("id")).to_s
      puts "  ✓ Created #{wp_label(id)} — #{@ctx.op_url}/work_packages/#{id}"
      id
    end

    # No match leaves the type out, and OpenProject assigns the project's own
    # default — better than refusing over a name the writer guessed.
    def payload_for(draft)
      Helpers.wp_payload(project: @project, type: Helpers.find_type(project_types, draft_type_name(draft)),
                         subject: draft["subject"], description: draft["description"])
    end

    # --type wins over the writer's TYPE: line — see #fix.
    def draft_type_name(draft) = @type_override || draft["type"]

    def payload_accepted?(payload)
      code, form = @api.create_work_package_form(payload)
      # nil is both "the form gave no verdict" (403, an HTML error from a proxy —
      # let the create speak for itself rather than blocking on a preflight that
      # did not run) and "nothing wrong". Only the first is worth a log line.
      errors = Helpers.form_validation_errors(code, form)
      log_script "The create form answered HTTP #{code}; creating without it." \
        unless code == 200 && form.is_a?(Hash)
      return true unless errors

      errors = hack_required_custom_fields!(payload, form, errors)
      return true unless errors

      # Named in the instance's own wording. opilot must not fill a required
      # custom field itself: the value carries business meaning only a person
      # has, and the work package would be permanent.
      puts ""
      puts "  ⚠ #{@project_json["name"]} needs values I must not invent:"
      errors.each { |field, error| puts "    - #{error["message"]} (`#{field}`)" }
      puts ""
      puts "  Create the work package in OpenProject, then run `./opilot dev build <id>`."
      false
    end

    # ── an explicit, narrow exception to "opilot must not invent a required
    # custom field's value" ────────────────────────────────────────────────
    #
    # These are opilot's OWN manufactured test fields — no ticket has ever
    # depended on one meaning something — kept around to exercise the
    # create-form path end to end. Matched by name, not by project or field id,
    # so the allowlist means what it says: everything else still refuses,
    # unchanged, however #fix is invoked. Keyed lower-case/stripped because the
    # instance's own field names carry stray casing and a trailing space
    # ("...Required CF ").
    CF_VALUE_HACKS = {
      "bug found in version"                                  => :highest,
      "cécile list type multi select custom field"            => :random,
      "cécile hierarchy notafilter singleselect required cf"  => :random,
      "cécile's 1st scored list"                               => :random
    }.freeze

    # Fill every errored field this run recognizes, then re-check the form —
    # a wrong link shape here would otherwise become a work package that can
    # never be deleted, so the one extra round trip is worth it. Returns the
    # remaining errors (nil if none are left), the same shape
    # Helpers.form_validation_errors already returns.
    def hack_required_custom_fields!(payload, form, errors)
      schema = form.dig("_embedded", "schema") || {}
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
      code, form = @api.create_work_package_form(payload)
      Helpers.form_validation_errors(code, form)
    end

    # One candidate href for a hacked field. A schema field's `allowedValues`
    # is either the values themselves (list/version fields render them inline)
    # or a link to fetch them (hierarchy/user fields render only a link) — see
    # API::V3::Utilities::CustomFieldInjector in the openproject source for
    # which shape goes with which field format.
    def hacked_custom_field_href(node, strategy)
      allowed = node.dig("_links", "allowedValues")
      candidates =
        case allowed
        when Array then allowed
        when Hash  then hierarchy_item_candidates(allowed["href"])
        end
      return nil if candidates.to_a.empty?

      case strategy
      # The titles on this test project are noise ("adsf", "backlog", …), not
      # version numbers, so "highest" is the highest id among the candidates —
      # the one thing that IS a number here.
      when :highest then candidates.max_by { |c| c["href"].to_s[/\d+\z/].to_i }["href"]
      when :random  then candidates.sample["href"]
      end
    end

    # A hierarchy custom field's selectable items, as candidate hrefs. The tree
    # has one synthetic root with no label of its own (custom_field_items
    # returns it as element zero); every other node is a real, selectable item.
    def hierarchy_item_candidates(items_href)
      id = items_href.to_s[%r{/custom_fields/(\d+)/items\z}, 1]
      return [] unless id
      code, body = @api.custom_field_items(id)
      return [] unless code == 200 && body
      ((body["_embedded"] || {})["elements"] || [])
        .select { |item| item["label"] }
        .map { |item| { "href" => item.dig("_links", "self", "href") } }
    end

    def project_types
      @project_types ||= begin
        code, body = @api.project_types(@project)
        code == 200 && body ? Helpers.type_list(body) : []
      end
    end

    def appsignal
      @appsignal ||= begin
        raise OPilot::FatalError, "AppSignal is not configured — set APPSIGNAL_API_TOKEN in .env." \
          unless @ctx.appsignal_token
        Clients::AppSignal.new(@ctx.appsignal_token)
      end
    end

    # AppSignal's own id for an app: 24 hex characters. Nobody types one from
    # memory, which is why a NAME is accepted here too.
    APP_ID = /\A[0-9a-f]{24}\z/

    # Which app this reads. The token is the only thing that MUST be set.
    #
    # A name is resolved to an id, because "edge-aws-de-trials2" is what a person
    # reads off the AppSignal URL bar and an id is not. The API only takes the
    # id, and its answer to a name is `Object not found`, which names neither the
    # problem nor the fix.
    #
    # A name matching several apps is NOT chosen between: the usual reason is one
    # name in two environments, and staging and production are the two that must
    # never be confused.
    def resolve_app!(flag)
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
      log_script "AppSignal app #{given} is #{@app} (#{matches.first["environment"]})"
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

    # Best-effort: a token that cannot list apps is no reason to turn "name your
    # app" into an API error.
    def applications_list
      return "(This token can see no applications.)" if applications.empty?
      applications.map { |a| "#{a["id"]}  #{a["name"]} (#{a["environment"]})" }.join("\n")
    rescue Clients::AppSignal::Error, OPilot::FatalError => e
      "(Could not list your apps: #{e.message})"
    end

    def indent(text) = text.to_s.lines.map { |l| "  #{l}" }.join

    # --- argument plumbing, mirroring OpRunner's ------------------------------

    # OpRunner#flags' shape, minus the repeatable values it needs: none of
    # --project/--type/--app can be given twice, so the last one simply wins and
    # the caller reads a string rather than an array.
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
        # A complaint about a well-shaped call, not a wrong SHAPE of call — an
        # arg spec would answer the wrong question, so this names the flags the
        # command does take (OpRunner#reject!'s split, for its reason).
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
