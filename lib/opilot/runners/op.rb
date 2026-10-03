require "json"

module OPilot
  module Runners
    # `./opilot op <resource> <action>` — one command per Clients::OpenProject
    # method it exposes, for looking at what the API actually returns.
    #
    # Two contracts. **stdout is data**: JSON only, diagnostics to stderr, never
    # Helpers#log_script (Rainbow ANSI + prefix to stdout, plus a chomp.log
    # append) — that one is absolute. **Read-only except `wp create`**: every other
    # action is a GET, so a read-scoped token still covers all of them, and the
    # remaining write methods (comment, update) stay absent on purpose. `wp form`
    # is a POST that writes nothing — it is the API's own dry run.
    #
    # `wp create` is here because a work package is the one thing an operator needs
    # to write while looking at the API, and because agent mode can now create them
    # too — one operation should not exist in only one of the two places. It carries
    # --dry-run instead of a prompt: a work package can never be deleted, but stdout
    # belongs to the JSON, so a confirmation prompt would break every script this
    # command exists to be used in.
    #
    # Config comes from Context#load_openproject_config!, not #load_config!: `op`
    # resolves no clone, so a malformed repos.json must not stop it.
    class Op
      Href     = Clients::OpenProject::Href
      Resource = Clients::OpenProject::Resource

      RESOURCES   = %w[me wp project status priority principal user doc attachment cf].freeze
      WP_ACTIONS  = %w[get inspect list activities reactions relations assignees attachments prs
                       schema create form update-form].freeze
      PRJ_ACTIONS = %w[get inspect list types versions].freeze
      DOC_ACTIONS = %w[list get inspect attachments download].freeze
      CF_ACTIONS  = %w[items].freeze
      GET_ACTIONS = %w[get inspect].freeze

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
      rescue Clients::OpenProject::Error => e
        # A network failure past HTTP's retries, or too many redirects. Never a
        # backtrace.
        $stderr.puts e.message
        raise OPilot::FatalError
      end

      private

      def api
        @api ||= Clients::OpenProject::Client.new(@ctx.op_url, @ctx.token)
      end

      def lookup
        @lookup ||= Clients::OpenProject::Lookup.new(api)
      end

      # A name or semantic id resolved before the real request, failing the way
      # #emit does: the status on stderr, no backtrace.
      def resolve!(label)
        yield
      rescue Clients::OpenProject::Error => e
        $stderr.puts "#{"HTTP #{e.code} — " if e.code}#{label}: #{e.message}"
        raise OPilot::FatalError
      end

      def dispatch(args)
        resource, *rest = args
        case resource
        when "me"      then no_args!("op me", rest); emit("me") { api.me }
        when "wp"      then wp(rest)
        when "project" then project(rest)
        when "status"  then status(rest)
        when "priority" then priority(rest)
        when "principal" then principal(rest)
        when "user"    then user(rest)
        when "doc"     then doc(rest)
        when "attachment" then attachment(rest)
        when "cf"      then cf(rest)
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
          wp_relations(*paged_one!("op wp relations", rest, "<work-package-id>", page_size: 100))
        when "assignees"
          id = one!("op wp assignees", rest, "<work-package-id>")
          emit("wp assignees #{id}") { api.work_package_available_assignees(id) }
        # Only what is attached to the work package; a comment's picture is read
        # by id with `op attachment get`.
        when "attachments"
          id = one!("op wp attachments", rest, "<work-package-id>")
          emit("wp attachments #{id}") { api.work_package_attachments(id) }
        # The GitHub integration's links. 403/404 when it is off for the project.
        when "prs"
          id = one!("op wp prs", rest, "<work-package-id>")
          emit("wp prs #{id}") { api.work_package_github_pull_requests(id) }
        when "schema"      then wp_schema(rest)
        when "create"      then wp_create(rest)
        when "form"        then wp_form(rest)
        when "update-form" then wp_update_form(rest)
        else unknown!("wp action", action, WP_ACTIONS)
        end
      end

      # The `involved` filter coerces to Integer, so a semantic id ("STC-162")
      # matches nothing rather than failing — an empty result reading as "no
      # relations". Resolve it first, as OpenProject::Pull#related_work_packages does.
      def wp_relations(id, page, page_size)
        numeric = resolve!("wp relations #{id}") { lookup.work_package_id(id) }
        emit("wp relations #{id}") { api.work_package_relations(numeric, page: page, page_size: page_size) }
      end

      CREATE_FLAGS = %w[project subject type description description-file parent relates
                        field link payload-json].freeze

      CREATE_SPEC = "--project <id> --type <name|id> --subject <text> " \
                    "[--description <text> | --description-file <path|->] " \
                    "[--field <name>=<value>]... [--link <name>=<href>]... " \
                    "[--relates <id>] [--parent <id>] [--payload-json <json>] [--dry-run]".freeze

      # The one write action. Every field is a flag, so nothing about the payload is
      # guessed; --payload-json is the escape hatch for anything the flags do not
      # cover, mirroring --filter-json on `wp list`.
      #
      # --type is REQUIRED, though the API would pick a default: what a type means is
      # a choice, and the payload representer only reads a custom field when the type
      # is named — the accessors come from the (project, type) pair while the default
      # type is assigned later, so an unnamed type makes a `--field`/`--link` value
      # vanish and come back as "can't be blank" (verified against a live instance).
      # One rule for every payload beats a rule that holds only when custom fields
      # are present.
      def wp_create(args)
        opts, rest = flags("op wp create", args, CREATE_FLAGS, booleans: %w[dry-run])
        usage!("op wp create", CREATE_SPEC) if rest.any?

        # Both work-package references are resolved BEFORE the POST, so a wrong id
        # fails while nothing has been created yet — the create cannot be undone.
        payload = create_payload(opts)
        relates = opts["relates"].any? ? numeric_wp_id!(opts["relates"].last, "--relates") : nil

        # --dry-run asks OPENPROJECT whether this payload works, rather than printing
        # opilot's own JSON back: the interesting failure is a required custom field
        # this project has, which only the instance knows about. Nothing is created.
        return emit_form(payload) if opts["dry-run"].any?

        # #emit prints the created work package (and a rejection's body) and returns
        # it: the create cannot be undone, so the id must reach the operator even
        # when the relation below fails.
        created = emit("wp create") { api.create_work_package(payload) }
        relate_created(created, relates) if relates
      end

      # `wp form` — what does this project and type require, and what may go in each
      # field? The answer no local check can give: required custom fields are per
      # project AND type, so a payload that works in one project 422s in another
      # with a message naming a field you have never heard of.
      #
      # It takes the same flags as `wp create` and needs the same --project and
      # --type; only --subject is optional, since being told the subject is missing
      # is part of the answer here. `op project types <id>` lists the types.
      def wp_form(args)
        opts, rest = flags("op wp form", args, CREATE_FLAGS, booleans: %w[required])
        usage!("op wp form", "--project <id> --type <name|id> [--required] [any `wp create` flag]") if rest.any?
        emit_form(create_payload(opts, require_subject: false, command: "op wp form"),
                  required_only: opts["required"].any?)
      end

      # The form endpoint, through the ordinary #emit funnel. It answers 200 even
      # for a payload it rejects — validation errors are its normal output — so the
      # body IS the answer and `_embedded.validationErrors` is what to read.
      # `_embedded.schema` carries `required` and the allowed values per field.
      def emit_form(payload, required_only: false)
        emit("wp form") do
          res = api.create_work_package_form(payload)
          next res unless required_only && res.form_answered?
          Clients::OpenProject::Response.new(res.code, required_summary(res.body), res.request)
        end
      end

      # --required: only the fields this project and type demand. A real instance
      # answers the form with several thousand lines of schema, and the question is
      # nearly always just this one — so the summary is a command rather than a jq
      # filter to remember. Still JSON, because stdout is data.
      #
      # `allowedValues` is passed through as the schema rendered it, and its SHAPE is
      # the answer to "where are the values": an array means they are right here
      # (a list field), an object with one href means they must be fetched (a
      # hierarchy, user or version field — `op cf items <id>` for the first kind).
      def required_summary(form)
        schema = form.dig("_embedded", "schema") || {}
        errors = form.dig("_embedded", "validationErrors") || {}

        fields = schema.filter_map do |name, node|
          # The schema object also holds _type, _links and _dependencies, so a
          # non-Hash value here is not a field.
          next unless node.is_a?(Hash) && node["required"] && node["writable"] != false
          { "field"         => name,
            "name"          => node["name"],
            "type"          => node["type"],
            "hasDefault"    => node["hasDefault"],
            "allowedValues" => node.dig("_links", "allowedValues"),
            "error"         => errors.dig(name, "message") }.compact
        end
        { "requiredFields" => fields }
      end

      # `wp schema` — every field of a (project, type) pair, with its key. The
      # route takes numeric ids only, so both are resolved here first.
      def wp_schema(args)
        opts, rest = flags("op wp schema", args, %w[project type])
        project = opts["project"].last
        type    = opts["type"].last
        usage!("op wp schema", "--project <id> --type <name|id>") if rest.any? || project.nil? || type.nil?

        numeric = resolve!("wp schema") { lookup.project_id(project) }
        emit("wp schema #{project} #{type}") { api.work_package_schema(numeric, type_id!(project, type, "op wp schema")) }
      end

      UPDATE_FLAGS = %w[field link payload-json].freeze

      # `wp update-form` — the dry run of an update: would OpenProject accept
      # this change? It saves nothing, so `op` stays read-only. Same answer
      # shape as `wp form`: read `_embedded.validationErrors`.
      def wp_update_form(args)
        opts, rest = flags("op wp update-form", args, UPDATE_FLAGS)
        spec = "<work-package-id> [--field <name>=<value>]... [--link <name>=<href>]... [--payload-json <json>]"
        usage!("op wp update-form", spec) unless rest.length == 1
        id = wp_id(rest.first)

        emit("wp update-form #{id}") { api.update_work_package_form(id, update_payload(opts)) }
      end

      # --payload-json alone, or the --field/--link pairs. Links go under
      # `_links`, fields at the top level, as in #create_payload.
      def update_payload(opts)
        command = "op wp update-form"
        if opts["payload-json"].any?
          reject!(command, "pass --payload-json or --field/--link, not both") if opts["field"].any? || opts["link"].any?
          return parse_payload_json!(command, opts["payload-json"].last)
        end
        reject!(command, "nothing to check — pass --field, --link or --payload-json") if opts["field"].empty? && opts["link"].empty?

        payload = custom_fields(opts, command)
        links = custom_links(opts, command)
        payload["_links"] = links if links.any?
        payload
      end

      # The NUMERIC id of a work package, for a payload link or the relations route.
      # Both resolve by primary key only — the `parent` link setter does
      # `WorkPackage.visible.find_by(id:)` and the relations route param is typed
      # Integer — so a semantic id ("PROJ-12") must be looked up here rather than
      # passed through, or it reaches the API as an unresolvable link. Every other
      # `op` command takes either form, and these two must not be the exception.
      def numeric_wp_id!(given, flag)
        resolve!("wp create #{flag} #{given}") { lookup.work_package_id(wp_id(given)) }
      end

      # --relates: link the new work package to an existing one. `to_id` is already
      # numeric (#numeric_wp_id!, resolved before the create). The new work package
      # is the relation's `from`, since the route work package becomes `from`.
      def relate_created(created, to_id)
        res = api.create_relation(created["id"], to_id)
        return if res.ok?

        $stdout.puts JSON.pretty_generate(res.body) if res.body
        $stderr.puts "HTTP #{res.code} — wp create --relates #{to_id}: " \
                     "work package #{created["id"]} is created but not linked"
        raise OPilot::FatalError
      end

      # The v3 create body. --payload-json replaces it wholesale rather than merging
      # into it: a half-overridden payload is the kind of thing you only notice
      # after the POST, and this POST cannot be undone.
      # `require_subject: false` is `wp form`, which needs only a project: the point
      # there is to be told what is missing, and a missing subject is part of that
      # answer rather than a reason to refuse the request.
      def create_payload(opts, require_subject: true, command: "op wp create")
        raw = opts["payload-json"].last if opts["payload-json"].any?
        return payload_json!(opts, raw) if raw

        project = opts["project"].last
        subject = opts["subject"].last
        type    = opts["type"].last
        if project.nil? || type.nil? || (subject.nil? && require_subject)
          usage!(command, "--project <id> --type <name|id>#{require_subject ? " --subject <text>" : ""} [flags]")
        end

        links = { "project" => Href.link(Href.project(project)),
                  "type"    => Href.link(Href.type(type_id!(project, type))) }
        if opts["parent"].any?
          parent = numeric_wp_id!(opts["parent"].last, "--parent")
          links["parent"] = Href.link(Href.work_package(parent))
        end
        custom_links(opts).each { |name, value| links[name] = value }

        payload = { "subject" => subject, "_links" => links }
        payload.delete("subject") if subject.nil?
        description = create_description(opts)
        payload["description"] = { "format" => "markdown", "raw" => description } if description
        custom_fields(opts).each { |name, value| payload[name] = value }
        payload
      end

      # --field <name>=<value>: a plain attribute, most usefully a custom field a
      # project requires (`--field customField12=whatever`). Written at the top level
      # of the payload, which is where a non-link field lives.
      def custom_fields(opts, command = "op wp create")
        opts["field"].to_h { |pair| split_pair!(command, "--field", pair) }
      end

      # --link <name>=<href>: a field whose value is a resource — every select,
      # list, hierarchy, user or version custom field. Repeat the flag for the same
      # name to send several; a single value stays an object, which the API accepts
      # for a multi-value field too (its setter does `Array([fragment].flatten)`).
      #
      # The value is an href, not an id: the namespace differs per field type
      # (/api/v3/custom_options/N for a list, /api/v3/users/N for a user), so an id
      # alone cannot be turned into a link without guessing. `op wp form` prints the
      # exact hrefs a field allows — copy one from there.
      def custom_links(opts, command = "op wp create")
        opts["link"].each_with_object({}) do |pair, out|
          name, href = split_pair!(command, "--link", pair)
          unless href.start_with?("/api/v3/")
            reject!(command, "--link #{name} needs an href like /api/v3/custom_options/12, " \
                                    "got #{href.inspect} — run `op wp form --project <id>` to see " \
                                    "what this field allows")
          end
          link = { "href" => href }
          out[name] = case out[name]
                      when nil   then link
                      when Array then out[name] << link
                      else            [out[name], link]
                      end
        end
      end

      def split_pair!(command, flag, pair)
        name, value = pair.to_s.split("=", 2)
        reject!(command, "#{flag} must look like <name>=<value>, got #{pair.inspect}") if value.nil? || name.to_s.empty?
        [name, value]
      end

      # --payload-json, and the refusal to combine it with the field flags.
      # --relates is not a payload field (it is a second request), so it rides along.
      def payload_json!(opts, raw)
        conflict = (CREATE_FLAGS - %w[payload-json]).select { |f| opts[f].any? }
        reject!("op wp create", "pass --payload-json or the field flags, not both " \
                                "(also given: #{conflict.map { |f| "--#{f}" }.join(", ")})") if conflict.any?
        parse_payload_json!("op wp create", raw)
      end

      def parse_payload_json!(command, raw)
        parsed = JSON.parse(raw)
        reject!(command, "--payload-json must be a JSON object") unless parsed.is_a?(Hash)
        parsed
      rescue JSON::ParserError => e
        reject!(command, "--payload-json is not valid JSON (#{e.message})")
      end

      # --description or --description-file; "-" reads stdin, because a markdown
      # body is painful to pass as a shell argument.
      def create_description(opts)
        text = opts["description"].last
        file = opts["description-file"].last
        reject!("op wp create", "pass --description or --description-file, not both") if text && file
        return text unless file
        return $stdin.read if file == "-"
        reject!("op wp create", "--description-file #{file}: no such file") unless File.file?(file)
        File.read(file)
      end

      # A --type given as a name is resolved against the project's own types
      # (Resource.find_named, shared with `pd init` and `@opilot create wp`), because
      # an unresolved name reaches the API as an opaque 422. A numeric one is passed
      # through.
      def type_id!(project, given, command = "op wp create")
        return given if given.match?(/\A\d+\z/)

        res = api.project_types(project)
        unless res.ok?
          $stderr.puts "HTTP #{res.code} — #{command.delete_prefix("op ")}: could not list the types of project #{project}"
          raise OPilot::FatalError
        end
        types = Resource.type_list(res.body)
        found = Resource.find_named(types, given)
        unless found
          reject!(command, "project #{project} has no type named #{given.inspect} " \
                                  "(it has: #{types.map { |t| t["name"] }.sort.join(", ")})")
        end
        found["id"]
      end

      def wp_list(args)
        list("op wp list", args, page_size: 50) { |kw| api.work_packages(**kw) }
      end

      LIST_SPEC = "[--filter <field>~<value>]... [--filter-json <json>] [--page <n>] [--page-size <n>]".freeze

      # Every paginated, filterable collection takes the same four flags.
      def list(command, args, page_size:)
        opts, rest = flags(command, args, %w[filter filter-json page page-size])
        usage!(command, LIST_SPEC) if rest.any?
        emit(command.delete_prefix("op ")) do
          yield(filters_json: filters_json(opts, command),
                page:         positive_int!(command, "--page", opts["page"]&.last, 1),
                page_size:    positive_int!(command, "--page-size", opts["page-size"]&.last, page_size))
        end
      end

      # One id plus --page/--page-size, for a paginated collection that takes no
      # filter. The body's `total` says whether there are more pages.
      def paged_one!(command, args, spec, page_size:)
        opts, rest = flags(command, args, %w[page page-size])
        [one!(command, rest, "#{spec} [--page <n>] [--page-size <n>]"),
         positive_int!(command, "--page", opts["page"]&.last, 1),
         positive_int!(command, "--page-size", opts["page-size"]&.last, page_size)]
      end

      def project(args)
        action, *rest = args
        case action
        when "get", "inspect"
          id = one!("op project get", rest, "<project-id-or-identifier>")
          emit("project get #{id}") { api.project(id) }
        when "list" then list("op project list", rest, page_size: 100) { |kw| api.projects(**kw) }
        when "types"
          id = one!("op project types", rest, "<project-id-or-identifier>")
          emit("project types #{id}") { api.project_types(id) }
        when "versions"
          id = one!("op project versions", rest, "<project-id-or-identifier>")
          emit("project versions #{id}") { api.project_versions(id) }
        else unknown!("project action", action, PRJ_ACTIONS)
        end
      end

      # `cf items <id>` — the values a hierarchy custom field allows. The last mile
      # of filling a required one: its schema gives a link rather than the values,
      # so --link has nothing to copy until this is read. Each item's self href
      # (/api/v3/custom_field_items/<id>) is what --link takes.
      def cf(args)
        action, *rest = args
        unknown!("cf action", action, CF_ACTIONS) unless CF_ACTIONS.include?(action)
        id = one!("op cf items", rest, "<custom-field-id>")
        emit("cf items #{id}") { api.custom_field_items(id) }
      end

      def status(args)
        action, *rest = args
        unknown!("status action", action, %w[list]) unless action == "list"
        no_args!("op status list", rest)
        emit("status list") { api.statuses }
      end

      def priority(args)
        action, *rest = args
        unknown!("priority action", action, %w[list]) unless action == "list"
        no_args!("op priority list", rest)
        emit("priority list") { api.priorities }
      end

      # Users, groups and placeholders, e.g. `--filter name~jane`.
      def principal(args)
        action, *rest = args
        unknown!("principal action", action, %w[list]) unless action == "list"
        list("op principal list", rest, page_size: 100) { |kw| api.principals(**kw) }
      end

      def user(args)
        action, *rest = args
        unknown!("user action", action, GET_ACTIONS) unless GET_ACTIONS.include?(action)
        id = one!("op user get", rest, "<user-id>")
        emit("user get #{id}") { api.user(id) }
      end

      # Any container's attachment, by id — the metadata, not the bytes.
      def attachment(args)
        action, *rest = args
        unknown!("attachment action", action, GET_ACTIONS) unless GET_ACTIONS.include?(action)
        id = one!("op attachment get", rest, "<attachment-id>")
        emit("attachment get #{id}") { api.attachment(id) }
      end

      def doc(args)
        action, *rest = args
        case action
        when "list"
          id, page, size = paged_one!("op doc list", rest, "<project-id-or-identifier>", page_size: 100)
          numeric = resolve!("doc list #{id}") { lookup.project_id(id) }
          emit("doc list #{id}") { api.documents(numeric, page: page, page_size: size) }
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

        res = api.download_attachment(url)
        if res.code >= 400 || res.body.nil?
          $stderr.puts "HTTP #{res.code} — doc download #{url}"
          raise OPilot::FatalError
        end
        File.binwrite(out, res.body)
        $stderr.puts "Wrote #{res.body.bytesize} bytes to #{out}"
      end

      # ── output ───────────────────────────────────────────────────────────────

      # The single funnel every action's response passes through, so the stdout
      # contract is stated once. `label` names the operation for stderr only.
      def emit(label)
        res = yield
        code, body = res.code, res.body

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
        # Returned so a caller with a second step (`wp create --relates`) can use
        # the resource it just printed, rather than repeating this funnel.
        body
      end

      # ── argument handling ────────────────────────────────────────────────────

      # Split `--name value` pairs off the positionals. Every flag collects into an
      # array, so --filter repeats and single-valued ones take .last. A flag named
      # in `booleans:` takes no value and collects "true", so `.any?` reads it.
      def flags(command, args, allowed, booleans: [])
        known = allowed + booleans
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
          unless known.include?(name)
            reject!(command, "unknown flag --#{name} (this command takes #{known.map { |a| "--#{a}" }.join(", ")})")
          end
          if booleans.include?(name)
            opts[name] << "true"
            next
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
        wp_id(args.first)
      end

      # The same normalisation for an id given as a flag value (`wp create
      # --relates`, `--parent`), so one id reads the same wherever it is typed.
      # NOT used for --project: a project identifier is lowercase kebab-case.
      def wp_id(given)
        id = given.to_s.strip.delete_prefix("#")
        id.match?(/\A[A-Za-z][A-Za-z0-9_]*-\d+\z/) ? id.upcase : id
      end

      def no_args!(command, args)
        reject!(command, "takes no arguments, got #{args.map(&:inspect).join(", ")}") if args.any?
      end

      def positive_int!(command, flag, value, default)
        return default if value.nil?
        reject!(command, "#{flag} must be a positive integer, got #{value.inspect}") unless value.match?(/\A[1-9]\d*\z/)
        value.to_i
      end

      # Giving both is named, not silently resolved. No filter sends an explicit
      # empty array: OpenProject applies its own default when `filters` is absent,
      # and an inspection command must not quietly scope its results.
      def filters_json(opts, command)
        raw    = opts["filter-json"].last if opts["filter-json"].any?
        pairs  = opts["filter"]
        reject!(command, "pass --filter or --filter-json, not both") if raw && pairs.any?
        return raw if raw
        return "[]" if pairs.empty?

        clauses = pairs.map do |pair|
          m = FILTER.match(pair)
          reject!(command, "--filter must look like <field>~<value> or <field>=<value>, got #{pair.inspect}") unless m
          JSON.parse(Clients::OpenProject::Query.filter(m[:field], m[:operator], m[:value])).first
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
end
