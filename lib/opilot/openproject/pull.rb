require "json"
require "time"

module OPilot
  module OpenProject
    class Pull
      Resource = Clients::OpenProject::Resource
      Lookup   = Clients::OpenProject::Lookup

      # Last poll's stats: scanned, and re-fetched rather than cached.
      attr_reader :scanned_count, :changed_count

      def initialize(ctx)
        @ctx = ctx
        @api = Clients::OpenProject::Client.new(ctx.op_url, ctx.token)
        @scanned_count = 0
        @changed_count = 0
      end

      # Unacted @opilot comments as Intents. `last_acted_comment_at` is set only
      # after a handle succeeds, so delivery is at-least-once. See CLAUDE.md, "op-agent".
      def poll_intents(scan_from_at)
        ensure_bot_identity!
        intents = []
        each_page(mention_filter_json, scan_from_at) do |wp, _cached, comments|
          intent = intent_from_comments(wp, comments)
          intents << intent if intent
        end
        intents
      end

      def mark_acted(item_id, comment_at)
        mark_opilot_acted(item_id, comment_at)
      end

      # Once per WP ever (`refusal_noted_at`): a per-comment answer would let
      # anyone fill the activity tab. See CLAUDE.md, "op-agent".
      def note_refused_trigger(wp_id, trigger)
        item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
        return unless item_path.exist?
        data = Helpers.safe_json_read(item_path) || {}
        return if data["refusal_noted_at"]

        # Names no command word, as a second guard beside #own_comment?.
        who  = Helpers.mention(trigger["user"], trigger["user_href"])
        body = "#{who} I do not act on this comment. On this instance only the users in " \
               "opilot's allowlist can trigger me. Ask one of them to comment, or ask an " \
               "administrator to add you.".strip
        res = @api.add_comment(wp_id, comment: body, internal: trigger["internal"] == true)
        return unless res.ok?

        data["refusal_noted_at"] = Time.now.utc.iso8601
        Helpers.write_item(item_path, data)
      end

      # Prompted, and saved as the next run's default.
      def load_or_prompt_scan_from
        scan_from_at = prompt_scan_from(saved_scan_from_at)
        save_scan_from(scan_from_at)
        scan_from_at
      end

      # The name is the poll's only search term. Without the id, #own_comment?
      # is a no-op and opilot can answer its own text in a loop.
      def ensure_bot_identity!
        missing = []
        missing << "display name" if bot_display_name.empty?
        missing << "user id"      if own_user_id.empty?
        return if missing.empty?

        raise OPilot::FatalError,
              "could not resolve opilot's own OpenProject identity (GET /users/me) — no " \
              "#{missing.join(" and no ")}. op-agent needs the display name to search for its " \
              "own @mentions, and the user id to tell its own comments from a trigger."
      end

      # Refreshes item.json and returns it, or nil.
      def fetch_single_item(wp_id)
        res = @api.work_package(wp_id)
        return nil unless res.ok?

        fetch_work_package_item(res.body)
        path = Helpers.item_dir(@ctx, wp_display_id(res.body)) / "item.json"
        Helpers.safe_json_read(path)
      end

      # Relations, parent and children, each mirrored to its own item.json.
      # Best-effort: a failure gives []. `mirror: false` is the light index for
      # MCP: no read per WP, refs carry `numeric_id` and no status.
      MAX_RELATED = 15

      def related_work_packages(wp_id, mirror: true)
        res = @api.work_package(wp_id)
        return [] unless res.ok?
        numeric_id = res.body["id"].to_s

        pairs = relation_pairs(numeric_id) + hierarchy_pairs(res.body)
        pairs.uniq! { |id, _label| id }
        if pairs.length > MAX_RELATED
          puts "  #{Helpers.wp_label(wp_id)}: #{pairs.length} related WPs found — using the first #{MAX_RELATED}."
          pairs = pairs.first(MAX_RELATED)
        end

        unless mirror
          return pairs.map { |id, label, title| { "numeric_id" => id, "relation" => label, "subject" => title }.compact }
        end

        pairs.filter_map do |id, label, _title|
          data = fetch_single_item(id)
          next unless data
          { "id" => data["id"], "relation" => label, "subject" => data["subject"], "status" => data["status"] }
        end
      rescue => e
        puts "  Warning: could not gather related WPs for #{Helpers.wp_label(wp_id)} (#{e.message})."
        []
      end

      # [id, label, title]; the label is from this WP's side of the relation.
      private def relation_pairs(numeric_id)
        _code, relations, _total = Lookup.new(@api).all_pages do |page, size|
          @api.work_package_relations(numeric_id, page: page, page_size: size)
        end
        Array(relations).filter_map do |rel|
          from = Resource.href_id(rel.dig("_links", "from", "href"))
          to   = Resource.href_id(rel.dig("_links", "to", "href"))
          if from == numeric_id
            [to, rel["type"], rel.dig("_links", "to", "title")]
          else
            [from, rel["reverseType"], rel.dig("_links", "from", "title")]
          end
        end
      end

      # [id, label, title] from _links, with no extra request.
      private def hierarchy_pairs(wp)
        pairs = []
        if (parent = Resource.href_id(wp.dig("_links", "parent", "href")))
          pairs << [parent, "parent", wp.dig("_links", "parent", "title")]
        end
        Array(wp.dig("_links", "children")).each do |child|
          id = Resource.href_id(child["href"])
          pairs << [id, "child", child["title"]] if id
        end
        pairs
      end

      private

      # nil means "from now". Enter keeps `previous`.
      def prompt_scan_from(previous = nil)
        print %(  How far back should the comment scanner look? (e.g. "2h", "3 days", "1 week", "1 month")\n  Scan from [#{previous || "now"}]: )
        reply = $stdin.gets.chomp
        return previous if previous && reply.strip.empty?
        parse_scan_from_input(reply)
      end

      # Yields [wp, cached, comments] for each WP down to the scan floor.
      def each_page(fj, scan_from_at)
        @scan_from_at = scan_from_at

        changed = 0
        processed = 0; progressed = false; reached_floor = false
        page = 1; page_size = 50; total_written = 0; total = 0
        loop do
          res = @api.work_packages(filters_json: fj, page: page, page_size: page_size)
          raise OPilot::FatalError, "API returned HTTP #{res.code} fetching work packages" if res.code != 200
          raise OPilot::FatalError, "API returned unparseable response fetching work packages" if res.body.nil?

          count = res.body["count"].to_i
          total = res.body["total"].to_i
          break if count == 0

          Resource.elements(res.body).each do |wp|
            # Sorted by updatedAt desc, and a comment bumps it: nothing older holds a trigger.
            if @scan_from_at && wp["updatedAt"] && wp["updatedAt"] < @scan_from_at
              reached_floor = true
              break
            end
            cached, comments = fetch_work_package_item(wp)
            changed += 1 unless cached
            processed += 1
            # A heartbeat on a tty, so a long first poll does not look hung.
            if !cached && $stdout.tty?
              print "\r  Polling OpenProject — #{processed} work package(s)…"
              $stdout.flush
              progressed = true
            end
            yield wp, cached, comments
          end

          break if reached_floor
          total_written += count
          break if total_written >= total
          page += 1
        end
        print "\r\033[K" if progressed   # clear the heartbeat before the summary

        @scanned_count = processed
        @changed_count = changed
      end

      def saved_scan_from_at
        (Helpers.safe_json_read(agent_filters_path) || {})["scan_from_at"]
      end

      def save_scan_from(scan_from_at)
        agent_filters_path.dirname.mkpath
        Helpers.write_json_atomic(agent_filters_path, { "scan_from_at" => scan_from_at }, "op_agent_scan")
      end

      # Per instance: a scan floor is valid only where it was chosen.
      def agent_filters_path
        Helpers.items_dir(@ctx) / "op_agent_scan.json"
      end

      # The latest unacted trigger as an Intent. An unlisted trigger is marked acted and dropped.
      def intent_from_comments(wp, comments)
        trigger = opilot_trigger_comment(wp_display_id(wp), comments)
        return nil unless trigger

        if @ctx.allowed_op_user_ids.any?
          user_id = trigger_user_id(trigger)
          unless user_id && @ctx.allowed_op_user_ids.include?(user_id)
            puts "  [@opilot] Ignoring trigger from user #{user_id || "unknown"} — not in allowlist"
            note_refused_trigger(wp_display_id(wp), trigger)
            mark_opilot_acted(wp_display_id(wp), trigger["created_at"])
            return nil
          end
        end

        react_eyes(trigger["id"])
        command, text = parse_command(trigger["text"].to_s)
        OpenProject::Intent.new(
          item_id:    wp_display_id(wp),
          subject:    wp["subject"],
          type:       wp.dig("_embedded", "type", "name").to_s,
          command:    command,
          text:       text,
          comment_at: trigger["created_at"],
          user:       trigger["user"],
          user_href:  trigger["user_href"],
          internal:   trigger["internal"] == true
        )
      end

      # A command word counts only right after a leading @opilot; the rest is :chat.
      def parse_command(raw)
        text = strip_mention(raw)
        body = text[/\A@opilot\s+(.*)/im, 1]
        if (cmd = CommandWords.match(body))
          return [:chat, Prompts::Advisor.lens(cmd[:word], cmd[:rest])] if cmd[:verb] == :lens
          return [cmd[:verb], cmd[:rest]]
        end
        [:chat, text.sub(/@opilot\s*/i, "").strip]
      end

      # CKEditor wraps mentions in <mention> markup. A leading one becomes "@opilot",
      # even when its display name is only an emoji.
      def strip_mention(raw)
        text = raw.to_s.sub(%r{\A\s*<mention\b[^>]*>.*?</mention>}im, "@opilot")
        text = text.gsub(%r{<mention\b[^>]*>(.*?)</mention>}im) { $1 }
        text.gsub(/<[^>]+>/, " ").gsub("&nbsp;", " ").gsub(/\s+/, " ").strip
      end

      def wp_display_id(wp)
        Resource.display_id(wp)
      end

      # opilot's own bookkeeping, never dropped on refresh. Losing a "noted once"
      # marker would turn one comment per WP into one per change.
      CARRIED_KEYS = %w[
        last_acted_comment_at
        refusal_noted_at
        create_wp_refusal_noted_at
      ].freeze

      # Carried only so a failed attachment read keeps the last index. ItemPictures
      # replaces them on a complete run.
      PICTURE_KEYS = %w[pictures pictures_skipped].freeze

      # Bump on a shape change, or a quiet WP keeps the old shape forever.
      ITEM_VERSION = 6

      # `pictures_pending` blocks the cache: updated_at cannot show a failed attachment read.
      def item_current?(cached, wp)
        cached["updated_at"] == wp["updatedAt"] &&
          cached["item_version"] == ITEM_VERSION &&
          !cached["pictures_pending"]
      end

      def fetch_work_package_item(wp)
        wp_id = wp_display_id(wp)
        item_dir  = Helpers.item_dir(@ctx, wp_id)
        item_path = item_dir / "item.json"

        cached = Helpers.safe_json_read(item_path) if item_path.exist?
        return [true, cached["comments"] || []] if cached && item_current?(cached, wp)

        acts_res = @api.work_package_activities(wp_id)
        acts = acts_res.ok? ? acts_res.body : { "_embedded" => { "elements" => [] } }

        rxns_res = @api.work_package_emoji_reactions(wp_id)
        rxns = rxns_res.ok? ? rxns_res.body : { "_embedded" => { "elements" => [] } }

        activities = Resource.elements(acts)
        comments = build_comments(activities, Resource.elements(rxns))

        full = build_full_item(wp, comments)
        full["custom_fields"] = custom_fields(wp)
        # nil, not empty, when the read failed: "no changes" would be a false fact.
        full["history"] = acts_res.ok? ? build_history(activities) : nil
        full["description_changed_at"] = acts_res.ok? ? description_changed_at(activities, wp) : nil
        if item_path.exist?
          prev = cached || {}
          (CARRIED_KEYS + PICTURE_KEYS).each { |key| full[key] = prev[key] if prev.key?(key) }
        end
        item_dir.mkpath
        full["item_version"] = ITEM_VERSION
        full = OpenProject::ItemPictures.mirror(full, dir: item_dir, api: @api, ctx: @ctx)
        Helpers.write_item(item_path, full)

        # The mirrored comments, whose picture URLs are rewritten, as the cached branch returns.
        [false, full["comments"] || []]
      end

      def build_comments(activities, reactions)
        read_user_names(activities)
        rxn_index = reactions
          .group_by { |r| Resource.href_id(r.dig("_links", "reactable", "href")) }
          .transform_values { |rs| rs.map { |r| [r["reaction"], r["reactionsCount"]] }.to_h }

        activities
          .select { |a| a.dig("comment", "raw").to_s.strip != "" }
          .map do |a|
            {
              "id"         => a["id"].to_s,
              "user"       => activity_user(a),
              "user_href"  => a.dig("_links", "user", "href"),
              "created_at" => a["createdAt"],
              "text"       => a.dig("comment", "raw"),
              "internal"   => a["internal"] == true,
              "reactions"  => rxn_index[a["id"].to_s] || {}
            }
          end
      end

      # The activities route renders only the href, so #read_user_names runs first.
      def activity_user(activity)
        activity.dig("_embedded", "user", "name") || activity.dig("_links", "user", "title") ||
          user_names[Resource.href_id(activity.dig("_links", "user", "href"))]
      end

      def user_names = @user_names ||= {}

      # Not `/principals` by id: one hidden id fails the whole query. A 404 is
      # cached as nil; a network failure is not.
      USER_READ_THREADS = 8

      def read_user_names(activities)
        ids = activities.filter_map do |a|
          next if a.dig("_embedded", "user", "name") || a.dig("_links", "user", "title")
          Resource.href_id(a.dig("_links", "user", "href"))
        end.uniq.reject { |id| id.to_s.empty? || user_names.key?(id) }

        ids.each_slice(USER_READ_THREADS) do |slice|
          slice.map { |id| Thread.new { [id, read_user_name(id)] } }.each do |t|
            id, name = t.value
            user_names[id] = name unless name == :failed
          end
        end
      end

      def read_user_name(id)
        res = @api.user(id)
        res.ok? ? res.body["name"] : nil
      rescue Clients::OpenProject::NetworkError
        :failed
      end

      # `changes` are rendered, language-dependent text: for the LLM, never for a Ruby rule.
      def build_history(activities)
        read_user_names(activities)
        activities.filter_map do |a|
          changes = Array(a["details"]).map { |d| d["raw"].to_s.strip }.reject(&:empty?)
          next if changes.empty?
          { "id" => a["id"].to_s,
            "user" => activity_user(a),
            "created_at" => a["createdAt"], "changes" => changes }
        end
      end

      # The journals diff route is language-independent. Falls back to createdAt.
      DESCRIPTION_DIFF = %r{/diff/description\b}

      def description_changed_at(activities, wp)
        edits = activities.select do |a|
          Array(a["details"]).any? { |d| "#{d["raw"]} #{d["html"]}".match?(DESCRIPTION_DIFF) }
        end
        edits.map { |a| a["createdAt"].to_s }.max || wp["createdAt"]
      end

      def build_full_item(wp, comments)
        {
          "id"          => wp_display_id(wp),
          "subject"     => wp["subject"],
          "type"        => wp.dig("_embedded", "type", "name"),
          "url"         => Helpers.wp_url(@ctx, wp_display_id(wp)),
          "status"      => wp.dig("_embedded", "status", "name"),
          "priority"    => wp.dig("_embedded", "priority", "name"),
          "assignee"    => wp.dig("_embedded", "assignee", "name") || "unassigned",
          "responsible" => wp.dig("_embedded", "responsible", "name") || "unassigned",
          "author"      => wp.dig("_embedded", "author", "name"),
          "version"     => wp.dig("_embedded", "version", "name"),
          "category"    => wp.dig("_embedded", "category", "name"),
          "created_at"  => wp["createdAt"],
          "updated_at"  => wp["updatedAt"],
          "description" => wp.dig("description", "raw") || "",
          "comments"    => comments
        }
      end

      # Values by display name, read from the schema. nil when the schema read failed.
      def custom_fields(wp)
        values = wp.select { |k, _| k.start_with?("customField") }
          .merge((wp["_links"] || {}).select { |k, _| k.start_with?("customField") })
          .transform_values { |v| custom_field_value(v) }
          .reject { |_, v| v.nil? || v == "" || v == [] }
        return {} if values.empty?

        schema = work_package_schema(wp.dig("_links", "schema", "href"))
        return nil unless schema
        values.to_h { |key, v| [schema.dig(key, "name") || key, v] }
      end

      def custom_field_value(value)
        case value
        when Array then value.map { |v| custom_field_value(v) }.compact
        when Hash  then value.key?("raw") ? value["raw"].to_s.strip : value["title"]
        else value
        end
      end

      # Schemas are few and rarely change, so one read per href per process.
      def work_package_schema(href)
        @schemas ||= {}
        return @schemas[href] if @schemas.key?(href)
        project_id, type_id = href.to_s[%r{/schemas/(\d+-\d+)\z}, 1]&.split("-")
        return nil unless project_id
        res = @api.work_package_schema(project_id, type_id)
        res.ok? ? @schemas[href] = res.body : nil
      end

      def parse_scan_from_input(input)
        Helpers.parse_scan_from(input)
      end

      # From the user href. A non-admin token cannot read emails.
      def trigger_user_id(comment)
        Resource.href_id(comment["user_href"])
      end

      def react_eyes(activity_id)
        return unless activity_id.to_s.length > 0
        @api.react(activity_id, reaction: "eyes")
      rescue => e
        puts "  Warning: could not post 👀 reaction: #{e.message}"
      end

      def opilot_trigger_comment(wp_id, comments)
        item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
        saved = Helpers.safe_json_read(item_path) || {}
        cutoff = [saved["last_acted_comment_at"], @scan_from_at].compact.max
        comments
          .reject { |c| own_comment?(c) }
          .select { |c| opilot_mentioned?(c["text"]) }
          .select { |c| cutoff.nil? || c["created_at"] > cutoff }
          .max_by { |c| c["created_at"] }
      end

      # By author, never by a record of posts. The cutoff cannot help: a reply is
      # always newer than its trigger. See CLAUDE.md, "Per-work-package state machine".
      def own_comment?(comment)
        Resource.href_id(comment["user_href"]) == own_user_id
      end

      # Literal "@opilot", or a mention whose data-id is opilot's user id (the
      # display name may be only an emoji).
      def opilot_mentioned?(text)
        str = text.to_s
        return true if str.match?(/\@opilot\b/i)
        id = own_user_id
        return false if id.empty?
        str.match?(%r{<mention\b[^>]*\bdata-id="#{Regexp.escape(id)}"})
      end

      # `~` cannot OR terms, so only the display name is searched. See CLAUDE.md, "op-agent".
      def mention_filter_json
        Clients::OpenProject::Query.filter("comment", "~", bot_display_name)
      end

      # Memoized, a failure too. "" on failure, which #ensure_bot_identity! makes fatal.
      def own_user
        return @own_user if defined?(@own_user)
        @own_user = begin
          me = @api.me.body
          { "id" => (me && Resource.link_id(me, "self")).to_s,
            "name" => me&.dig("name").to_s }
        rescue => e
          puts "  Warning: could not resolve opilot's own OpenProject identity: #{e.message}"
          { "id" => "", "name" => "" }
        end
      end

      def own_user_id;      own_user["id"];   end
      def bot_display_name; own_user["name"]; end
      # The health check tells the model which comments are opilot's own.
      public :own_user_id

      def mark_opilot_acted(wp_id, created_at)
        item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
        return unless item_path.exist?
        data = JSON.parse(item_path.read)
        data["last_acted_comment_at"] = created_at
        Helpers.write_item(item_path, data)
      end

    end
  end
end
