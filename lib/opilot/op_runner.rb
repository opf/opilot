require "json"

module OPilot
  # `./opilot op <resource> <action>` — one command per Clients::OpenProject read
  # method, for looking at what the API actually returns.
  #
  # Two contracts, both load-bearing. **stdout is data**: JSON only, diagnostics
  # to stderr, never Helpers#log_script (Rainbow ANSI + prefix to stdout, plus a
  # chomp.log append). **Read-only by construction**: every action is a GET, so a
  # read-scoped token suffices and the write methods are absent on purpose.
  #
  # Config comes from Context#load_openproject_config!, not #load_config!: `op`
  # resolves no clone, so a malformed repos.json must not stop it.
  class OpRunner
    RESOURCES   = %w[me wp project status doc].freeze
    WP_ACTIONS  = %w[get inspect list activities reactions relations].freeze
    PRJ_ACTIONS = %w[get inspect types].freeze
    DOC_ACTIONS = %w[list get inspect attachments download].freeze

    # `--filter subject~login`. Only `=` and `~`; --filter-json is the escape
    # hatch, rather than growing an operator dialect here.
    FILTER = /\A(?<field>[A-Za-z_][A-Za-z0-9_]*)(?<operator>~|=)(?<value>.*)\z/m.freeze

    def initialize(ctx, api: nil)
      @ctx = ctx
      @api = api
    end

    def run(args)
      @ctx.load_openproject_config!
      dispatch(args)
    rescue Clients::HTTP::Error => e
      # A network failure past HTTP's retries, `statuses`' non-200 raise (the one
      # read method that raises), or too many redirects. Never a backtrace.
      $stderr.puts e.message
      raise OPilot::FatalError
    end

    private

    def api
      @api ||= Clients::OpenProject.new(@ctx.op_url, @ctx.token)
    end

    def dispatch(args)
      resource, *rest = args
      case resource
      when "me"      then no_args!("op me", rest); emit("me") { api.me }
      when "wp"      then wp(rest)
      when "project" then project(rest)
      when "status"  then status(rest)
      when "doc"     then doc(rest)
      else unknown!("resource", resource, RESOURCES)
      end
    end

    # ── resources ────────────────────────────────────────────────────────────

    def wp(args)
      action, *rest = args
      case action
      # `inspect` is opf/openproject-cli's word for this, aliased throughout.
      when "get", "inspect"
        id = one!("op wp get", rest, "<work-package-id>")
        emit("wp get #{id}") { api.work_package(id) }
      when "list"       then wp_list(rest)
      when "activities"
        id = one!("op wp activities", rest, "<work-package-id>")
        emit("wp activities #{id}") { api.work_package_activities(id) }
      when "reactions"
        id = one!("op wp reactions", rest, "<work-package-id>")
        emit("wp reactions #{id}") { api.work_package_emoji_reactions(id) }
      when "relations"
        wp_relations(one!("op wp relations", rest, "<work-package-id>"))
      else unknown!("wp action", action, WP_ACTIONS)
      end
    end

    # The `involved` filter coerces to Integer, so a semantic id ("STC-162")
    # matches nothing rather than failing — an empty result reading as "no
    # relations". Resolve it first, as Pull#related_work_packages does.
    def wp_relations(id)
      code, wp = api.work_package(id)
      unless code == 200 && wp
        $stderr.puts "HTTP #{code} — wp relations #{id}: could not read the work package to resolve its numeric id"
        raise OPilot::FatalError
      end
      emit("wp relations #{id}") { api.work_package_relations(wp["id"].to_s) }
    end

    def wp_list(args)
      opts, rest = flags("op wp list", args, %w[filter filter-json page page-size])
      usage!("op wp list", "[--filter <field>~<value>]... [--filter-json <json>] [--page <n>] [--page-size <n>]") if rest.any?
      emit("wp list") do
        api.work_packages(filters_json: filters_json(opts),
                          page:      positive_int!("--page", opts["page"]&.last, 1),
                          page_size: positive_int!("--page-size", opts["page-size"]&.last, 50))
      end
    end

    def project(args)
      action, *rest = args
      case action
      when "get", "inspect"
        id = one!("op project get", rest, "<project-id-or-identifier>")
        emit("project get #{id}") { api.project(id) }
      when "types"
        id = one!("op project types", rest, "<project-id-or-identifier>")
        emit("project types #{id}") { api.project_types(id) }
      else unknown!("project action", action, PRJ_ACTIONS)
      end
    end

    def status(args)
      action, *rest = args
      unknown!("status action", action, %w[list]) unless action == "list"
      no_args!("op status list", rest)
      emit("status list") { api.statuses }
    end

    def doc(args)
      action, *rest = args
      case action
      when "list"
        id = one!("op doc list", rest, "<project-id-or-identifier>")
        emit("doc list #{id}") { api.documents(id) }
      when "get", "inspect"
        id = one!("op doc get", rest, "<document-id>")
        emit("doc get #{id}") { api.document(id) }
      when "attachments"
        id = one!("op doc attachments", rest, "<document-id>")
        emit("doc attachments #{id}") { api.document_attachments(id) }
      when "download" then doc_download(rest)
      else unknown!("doc action", action, DOC_ACTIONS)
      end
    end

    # The one non-JSON payload. Written to --out rather than stdout, which would
    # break the contract every other action keeps and dump binary on a terminal.
    def doc_download(args)
      opts, rest = flags("op doc download", args, %w[out])
      url = rest.first
      out = opts["out"]&.last
      usage!("op doc download", "<download-url> --out <path>") if url.nil? || rest.length > 1 || out.nil?

      # Said out loud, because the alternative is a baffling 401: the client
      # withholds the token from any host that is not this instance.
      unless api.on_this_instance?(url)
        $stderr.puts "Note: #{URI(url).host rescue "that host"} is not #{URI(@ctx.op_url).host} — " \
                     "fetching without the API token."
      end

      code, bytes = api.download_attachment(url)
      if code >= 400 || bytes.nil?
        $stderr.puts "HTTP #{code} — doc download #{url}"
        raise OPilot::FatalError
      end
      File.binwrite(out, bytes)
      $stderr.puts "Wrote #{bytes.bytesize} bytes to #{out}"
    end

    # ── output ───────────────────────────────────────────────────────────────

    # The single funnel every action's response passes through, so the stdout
    # contract is stated once. `label` names the operation for stderr only.
    def emit(label)
      code, body = yield

      if code >= 400
        # The body first, and on stdout: a 422's validation payload is the most
        # common reason to reach for this command, and it has to survive `| jq`.
        $stdout.puts JSON.pretty_generate(body) if body
        $stderr.puts "HTTP #{code} — #{label}"
        # Bare: bin/opilot prints nothing when the message is the class name, so
        # no "Error: " line lands between the caller and the body just printed.
        raise OPilot::FatalError
      end

      if body.nil?
        # 204 carries no body by design. Anything else means the response was
        # not JSON — an HTML 502 from a proxy, say — and HTTP.get_json swallowed
        # it in its `rescue nil`. Say so rather than printing nothing at all.
        return if code == 204
        $stderr.puts "HTTP #{code} — #{label}: response body was not JSON"
        raise OPilot::FatalError
      end

      $stdout.puts JSON.pretty_generate(body)
    end

    # ── argument handling ────────────────────────────────────────────────────

    # Split `--name value` pairs off the positionals. Every flag collects into an
    # array, so --filter repeats and single-valued ones take .last.
    def flags(command, args, allowed)
      opts = Hash.new { |h, k| h[k] = [] }
      rest = []
      args = args.dup
      until args.empty?
        arg = args.shift
        unless arg.start_with?("--")
          rest << arg
          next
        end
        name = arg.delete_prefix("--")
        unless allowed.include?(name)
          reject!(command, "unknown flag --#{name} (this command takes #{allowed.map { |a| "--#{a}" }.join(", ")})")
        end
        value = args.shift
        reject!(command, "--#{name} needs a value") if value.nil?
        opts[name] << value
      end
      [opts, rest]
    end

    # Pasted ids carry a "#" and semantic ids are often lowercase — accept both,
    # as CLI does for the `dev` verbs.
    def one!(command, args, spec)
      usage!(command, spec) unless args.length == 1
      id = args.first.to_s.strip.delete_prefix("#")
      id.match?(/\A[A-Za-z][A-Za-z0-9_]*-\d+\z/) ? id.upcase : id
    end

    def no_args!(command, args)
      reject!(command, "takes no arguments, got #{args.map(&:inspect).join(", ")}") if args.any?
    end

    def positive_int!(flag, value, default)
      return default if value.nil?
      reject!("op wp list", "#{flag} must be a positive integer, got #{value.inspect}") unless value.match?(/\A[1-9]\d*\z/)
      value.to_i
    end

    # Giving both is named, not silently resolved. No filter sends an explicit
    # empty array: OpenProject applies its own default when `filters` is absent,
    # and an inspection command must not quietly scope its results.
    def filters_json(opts)
      raw    = opts["filter-json"].last if opts["filter-json"].any?
      pairs  = opts["filter"]
      reject!("op wp list", "pass --filter or --filter-json, not both") if raw && pairs.any?
      return raw if raw
      return "[]" if pairs.empty?

      clauses = pairs.map do |pair|
        m = FILTER.match(pair)
        reject!("op wp list", "--filter must look like <field>~<value> or <field>=<value>, got #{pair.inspect}") unless m
        JSON.parse(Clients::OpenProject.filter(m[:field], m[:operator], m[:value])).first
      end
      JSON.generate(clauses)
    end

    # ── failure ──────────────────────────────────────────────────────────────

    # CLI#usage!'s shape, on stderr because stdout belongs to the JSON. For a
    # wrong *shape* of call — the arg spec says what the right one is.
    def usage!(command, spec)
      $stderr.puts "Usage: ./opilot #{command} #{spec}"
      raise OPilot::FatalError
    end

    # For a specific complaint about a well-shaped call, where an arg spec would
    # answer the wrong question.
    def reject!(command, message)
      $stderr.puts "#{command}: #{message}"
      $stderr.puts "Run `./opilot op --help` for the full list."
      raise OPilot::FatalError
    end

    def unknown!(kind, given, allowed)
      $stderr.puts given.to_s.empty? ? "missing #{kind}" : "unknown #{kind} #{given.inspect}"
      $stderr.puts "Expected one of: #{allowed.join(", ")}"
      $stderr.puts "Run `./opilot op --help` for the full list."
      raise OPilot::FatalError
    end
  end
end
