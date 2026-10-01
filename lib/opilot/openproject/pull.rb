require "json"
require "time"

module OPilot
  module OpenProject
    class Pull
      Resource = Clients::OpenProject::Resource

      # Stats from the most recent poll (for logging): total scanned, and how many
      # had changed (were re-fetched rather than served from cache).
      attr_reader :scanned_count, :changed_count

      def initialize(ctx)
        @ctx = ctx
        @api = Clients::OpenProject::Client.new(ctx.op_url, ctx.token)
        @scanned_count = 0
        @changed_count = 0
      end

      # Poll OpenProject for work packages whose comments mention opilot's own
      # account (OpenProject's server-side `comment` filter, keyed on the bot's
      # real display name — see #mention_filter_json) and turn any unacted
      # @opilot comment into a OPilot::OpenProject::Intent. De-duplication is by
      # `last_acted_comment_at` in item.json, which the agent sets only AFTER a
      # handle succeeds — so an unprocessed trigger is re-emitted on the next poll
      # (at-least-once delivery). Every matching WP is scanned each poll so a
      # re-fire after a crash is not missed.
      def poll_intents(scan_from_at)
        ensure_bot_identity!
        intents = []
        each_page(mention_filter_json, scan_from_at) do |wp, _cached, comments|
          intent = intent_from_comments(wp, comments)
          intents << intent if intent
        end
        intents
      end

      # Record that a trigger comment has been fully handled, so it is not
      # re-emitted on later polls. Called by the agent after a successful handle.
      def mark_acted(item_id, comment_at)
        mark_opilot_acted(item_id, comment_at)
      end

      # Tell a non-allowlisted commenter, once per work package, that their trigger
      # was not acted on. Silence reads as a bug or as opilot ignoring the person,
      # and it is worst where it matters most: opilot offers implementation options
      # to anyone who can comment, but only an allowlisted user may choose one.
      #
      # One comment per WP, ever (`refusal_noted_at`), because the reply is the one
      # thing an unlisted user can make opilot do — a per-comment answer would let
      # anyone fill the activity tab. Mirrors the trigger's visibility, and needs no
      # 👀 (the note is the acknowledgement).
      def note_refused_trigger(wp_id, trigger)
        item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
        return unless item_path.exist?
        data = Helpers.safe_json_read(item_path) || {}
        return if data["refusal_noted_at"]

        # The note also names no command word. #own_comment? already keeps opilot
        # from reading its own text as a trigger, so this is belt-and-braces —
        # but it costs nothing, and the one comment this path may ever post is
        # the worst place to depend on a single guard.
        who  = Helpers.mention(trigger["user"], trigger["user_href"])
        body = "#{who} I do not act on this comment. On this instance only the users in " \
               "opilot's allowlist can trigger me. Ask one of them to comment, or ask an " \
               "administrator to add you.".strip
        code, _body = @api.add_comment(wp_id, comment: body, internal: trigger["internal"] == true)
        return unless code == 201

        data["refusal_noted_at"] = Time.now.utc.iso8601
        Helpers.write_item(item_path, data)
      end

      # The scan window op-agent resumes from, prompted interactively and
      # persisted so the next run offers it as the default. No project scope any
      # more (see #poll_intents) — the API token's own project access is the
      # trust boundary.
      def load_or_prompt_scan_from
        scan_from_at = prompt_scan_from(saved_scan_from_at)
        save_scan_from(scan_from_at)
        scan_from_at
      end

      # Raise unless BOTH halves of opilot's own OpenProject identity are known.
      # There is no project-scope fallback left underneath the poll, so a failed
      # /users/me lookup must stop it rather than degrade quietly. Called from
      # OpenProject::Agent#setup (so a broken identity fails loudly once, before the loop
      # starts, instead of being silently retried forever by guarded_tick) and
      # from #poll_intents itself (so a direct call is guarded too).
      #
      # Both halves are required, because each one is load-bearing on its own:
      #
      # - the display name is the poll's ONLY search term (#mention_filter_json),
      #   so without it the filter value is empty or malformed;
      # - the user id is what tells opilot's own comments apart from a trigger
      #   (#own_comment?). Missing, that guard silently becomes a no-op and opilot
      #   can read its own text back as an instruction — a loop nothing stops.
      #
      # Both come from one #own_user call, so in practice they fail together; the
      # message names which half is missing for the case where the response is
      # merely malformed.
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

      # Fetch one work package by id (ignoring filters), refresh its item.json,
      # and return the item data — or nil when the WP can't be fetched.
      def fetch_single_item(wp_id)
        code, wp = @api.work_package(wp_id)
        return nil unless code == 200 && wp

        fetch_work_package_item(wp)
        path = Helpers.item_dir(@ctx, wp_display_id(wp)) / "item.json"
        Helpers.safe_json_read(path)
      end

      # Work packages related to `wp_id` — its explicit relations (relates, blocks,
      # precedes, duplicates, …) plus its parent and direct children — each
      # materialised to its own item.json (via fetch_single_item) so a handler can
      # let the LLM read the full detail on demand. Returns an array of
      # { "id", "relation", "subject", "status" } refs (display ids).
      #
      # Best-effort: any failure yields [] (or drops the offending WP) so it can
      # never break the ping it's enriching. Unreachable WPs are naturally excluded
      # — the relations endpoint omits relations to invisible WPs, and a parent/
      # child we can't fetch returns nil from fetch_single_item and is skipped.
      MAX_RELATED = 15

      def related_work_packages(wp_id)
        code, wp = @api.work_package(wp_id)
        return [] unless code == 200 && wp
        numeric_id = wp["id"].to_s

        pairs = relation_pairs(numeric_id) + hierarchy_pairs(wp)
        pairs.uniq! { |id, _label| id }
        if pairs.length > MAX_RELATED
          puts "  #{Helpers.wp_label(wp_id)}: #{pairs.length} related WPs found — using the first #{MAX_RELATED}."
          pairs = pairs.first(MAX_RELATED)
        end

        pairs.filter_map do |id, label|
          data = fetch_single_item(id)
          next unless data
          { "id" => data["id"], "relation" => label, "subject" => data["subject"], "status" => data["status"] }
        end
      rescue => e
        puts "  Warning: could not gather related WPs for #{Helpers.wp_label(wp_id)} (#{e.message})."
        []
      end

      # [related_numeric_id, relation_label] for each explicit relation involving
      # the WP. The label is taken from the WP's own perspective: `type` when it is
      # the relation's `from`, `reverseType` when it is the `to`.
      private def relation_pairs(numeric_id)
        code, resp = @api.work_package_relations(numeric_id)
        return [] unless code == 200 && resp
        Resource.elements(resp).filter_map do |rel|
          from = Resource.href_id(rel.dig("_links", "from", "href"))
          to   = Resource.href_id(rel.dig("_links", "to", "href"))
          if from == numeric_id
            [to, rel["type"]]
          else
            [from, rel["reverseType"]]
          end
        end
      end

      # [related_numeric_id, label] for the WP's parent and direct children, read
      # straight from the WP resource's _links (no extra request).
      private def hierarchy_pairs(wp)
        pairs = []
        if (parent = Resource.href_id(wp.dig("_links", "parent", "href")))
          pairs << [parent, "parent"]
        end
        Array(wp.dig("_links", "children")).each do |child|
          id = Resource.href_id(child["href"])
          pairs << [id, "child"] if id
        end
        pairs
      end

      private

      # Ask how far back the comment scanner should look, returning the parsed
      # floor timestamp (nil = from now). `previous` (the last session's chosen
      # floor, if any) becomes the offered default, so pressing Enter resumes
      # from where the previous run left off instead of jumping forward to now.
      def prompt_scan_from(previous = nil)
        print %(  How far back should the comment scanner look? (e.g. "2h", "3 days", "1 week", "1 month")\n  Scan from [#{previous || "now"}]: )
        reply = $stdin.gets.chomp
        return previous if previous && reply.strip.empty?
        parse_scan_from_input(reply)
      end

      # Paginate the filtered work-package list (raw filters JSON `fj`), refresh
      # each WP's item.json, and yield [wp, cached, comments]. Stops at the
      # scan-window floor (results are updatedAt desc) and records scan/change
      # stats in @scanned_count / @changed_count.
      def each_page(fj, scan_from_at)
        @scan_from_at = scan_from_at

        changed = 0
        processed = 0; progressed = false; reached_floor = false
        page = 1; page_size = 50; total_written = 0; total = 0
        loop do
          code, resp = @api.work_packages(filters_json: fj, page: page, page_size: page_size)
          raise OPilot::FatalError, "API returned HTTP #{code} fetching work packages" if code != 200
          raise OPilot::FatalError, "API returned unparseable response fetching work packages" if resp.nil?

          count = resp["count"].to_i
          total = resp["total"].to_i
          break if count == 0

          Resource.elements(resp).each do |wp|
            # Results are sorted updatedAt desc, and posting a @opilot comment bumps
            # the WP's updatedAt — so a WP last touched before the scan floor can't
            # carry a trigger newer than the floor, and neither can any WP after it.
            # Stop here instead of re-listing every work package every cycle.
            if @scan_from_at && wp["updatedAt"] && wp["updatedAt"] < @scan_from_at
              reached_floor = true
              break
            end
            cached, comments = fetch_work_package_item(wp)
            changed += 1 unless cached
            processed += 1
            # Each changed WP costs two more API calls; on a first or large poll
            # that's a long, silent stretch. Show a self-clearing heartbeat (only the
            # moment we actually hit the network, and only on a tty) so it's clearly
            # working rather than hung.
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

      # The scan floor chosen on the last run, read straight from the saved
      # scan-window file. Offered as the default when re-prompting, so a fresh
      # session resumes from where the previous one stopped rather than skipping
      # ahead to now.
      def saved_scan_from_at
        (Helpers.safe_json_read(agent_filters_path) || {})["scan_from_at"]
      end

      def save_scan_from(scan_from_at)
        agent_filters_path.dirname.mkpath
        Helpers.write_json_atomic(agent_filters_path, { "scan_from_at" => scan_from_at }, "op_agent_scan")
      end

      # op-agent's scan-window watermark lives alongside the WP mirror, under the
      # per-instance work_packages/<op_host>/ dir: a scan floor is only valid on
      # the instance it was chosen on, so it must not bleed across instances.
      def agent_filters_path
        Helpers.items_dir(@ctx) / "op_agent_scan.json"
      end

      # Detect the latest unacted @opilot trigger on a WP and turn it into an
      # OpenProject::Intent. Acknowledges receipt with 👀 and enforces the user-id allowlist
      # (a non-allowlisted trigger is marked acted and dropped, never emitted).
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

      # Map @opilot trigger text to a [command, free-text] pair. A command word
      # counts only right after a leading @opilot (CommandWords); anything else
      # becomes a :chat carrying the message body.
      def parse_command(raw)
        text = strip_mention(raw)
        body = text[/\A@opilot\s+(.*)/im, 1]
        if (cmd = CommandWords.match(body))
          return [:chat, Prompts::Advisor.lens(cmd[:word], cmd[:rest])] if cmd[:verb] == :lens
          return [cmd[:verb], cmd[:rest]]
        end
        [:chat, text.sub(/@opilot\s*/i, "").strip]
      end

      # OpenProject's CKEditor wraps the @opilot handle in mention markup, e.g.
      #   <mention ... data-text="🤖">@OPilot 🤖</mention> approve
      # Normalise a leading mention to a plain "@opilot" token (so display is
      # robust even when it renders as just an emoji), drop other mentions to their
      # visible text, and strip any remaining HTML so the command word is exposed.
      def strip_mention(raw)
        text = raw.to_s.sub(%r{\A\s*<mention\b[^>]*>.*?</mention>}im, "@opilot")
        text = text.gsub(%r{<mention\b[^>]*>(.*?)</mention>}im) { $1 }
        text.gsub(/<[^>]+>/, " ").gsub("&nbsp;", " ").gsub(/\s+/, " ").strip
      end

      # The user-facing work package id — see Resource.display_id, which the agent's
      # `create wp` reply shares.
      def wp_display_id(wp)
        Resource.display_id(wp)
      end

      # The keys a refreshed item.json keeps. Everything else in the file is a
      # mirror of the API and is rebuilt from the response, but these are opilot's
      # own bookkeeping and exist nowhere else.
      #
      # The two "noted once" markers are here for the same reason they exist at all:
      # both promise ONE comment per work package, ever, and dropping the marker on
      # the next refresh would turn that into one comment per change to the work
      # package — which a commenter can cause at will.
      CARRIED_KEYS = %w[
        last_acted_comment_at
        refusal_noted_at
        create_wp_refusal_noted_at
      ].freeze

      # Carried the same way, under a weaker rule — which is why they are not in
      # CARRIED_KEYS, whose promise is "never dropped". These are derived, and
      # OpenProject::ItemPictures REPLACES both whenever it finishes; they survive only so that
      # a refresh whose attachment read failed does not lose the index (and, with
      # it, the files) the last complete run produced.
      PICTURE_KEYS = %w[pictures pictures_skipped].freeze

      # item.json's shape. The updated_at cache below would otherwise keep a work
      # package opilot has already seen on the old shape forever — which is how a
      # mirror gains a field (3: "history", "description_changed_at", and each
      # picture's "created_at", for the health check; 4: "custom_fields"; 5: user
      # names on comments and history; 6: pretty-printed, see Helpers.write_item).
      ITEM_VERSION = 6

      # A work package is served from cache only when the mirror is COMPLETE.
      # `pictures_pending` says an attachment read failed, and updated_at cannot
      # notice that: the work package did not change, so an incomplete index would
      # read as current until somebody edited it.
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

        acts_code, acts = @api.work_package_activities(wp_id)
        acts = { "_embedded" => { "elements" => [] } } unless acts_code == 200

        rxns_code, rxns = @api.work_package_emoji_reactions(wp_id)
        rxns = { "_embedded" => { "elements" => [] } } unless rxns_code == 200

        activities = Resource.elements(acts)
        comments = build_comments(activities, Resource.elements(rxns))

        full = build_full_item(wp, comments)
        full["custom_fields"] = custom_fields(wp)
        # nil, not empty, when the read failed: "no changes" would be a false fact.
        full["history"] = acts_code == 200 ? build_history(activities) : nil
        full["description_changed_at"] = acts_code == 200 ? description_changed_at(activities, wp) : nil
        if item_path.exist?
          prev = cached || {}
          (CARRIED_KEYS + PICTURE_KEYS).each { |key| full[key] = prev[key] if prev.key?(key) }
        end
        item_dir.mkpath
        full["item_version"] = ITEM_VERSION
        full = OpenProject::ItemPictures.mirror(full, dir: item_dir, api: @api, ctx: @ctx)
        Helpers.write_item(item_path, full)

        # The mirrored comments, not the ones just built: the mirror rewrites the
        # picture URLs in them, and the cached branch above returns the rewritten
        # text — one shape whichever way this returns.
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

      # The activity's author by name. The activities route renders only the
      # user's href, so #read_user_names reads the names first.
      def activity_user(activity)
        activity.dig("_embedded", "user", "name") || activity.dig("_links", "user", "title") ||
          user_names[Resource.href_id(activity.dig("_links", "user", "href"))]
      end

      def user_names = @user_names ||= {}

      # One read per user per process, in parallel: a long thread has 20+
      # authors. Not `/principals` with an `id` filter: one id the token cannot
      # see fails the whole query. A 404 is cached as nil; a network failure is
      # not, so the next refresh asks again.
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
        code, body = @api.user(id)
        code == 200 ? body["name"] : nil
      rescue Clients::OpenProject::NetworkError
        :failed
      end

      # Field changes (status, assignee, description, …), which build_comments
      # drops. `changes` are the instance's own rendered sentences, so they are
      # language-dependent: input for the LLM, never for a Ruby rule.
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

      # When the description last changed, or the creation time if it never did.
      # The detail links to the journals diff route
      # (`/journals/<id>/diff/description`), which is language-independent.
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

      # Custom field values by display name ("Acceptance criteria" => "…"). The
      # work package carries only `customField400` keys; the names are in its
      # schema. nil, not {}, when the schema read failed.
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
        code, body = @api.work_package_schema(project_id, type_id)
        code == 200 ? @schemas[href] = body : nil
      end

      def parse_scan_from_input(input)
        Helpers.parse_scan_from(input)
      end

      # The comment author's OpenProject user id, taken straight from the activity's
      # `_links.user.href` (e.g. "/api/v3/users/534" → "534"). No API call: an
      # activity never carries the author's email or name, only this id, and a
      # non-admin token can't read another user's email anyway.
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

      # Did opilot write this comment? Read off the AUTHOR, never off a record of
      # what opilot posted.
      #
      # This guard has to be complete, because the cutoff underneath it cannot
      # help: opilot's reply is always posted AFTER the trigger it answers, so its
      # timestamp is always above `last_acted_comment_at`. The author is the only
      # thing between opilot and its own text.
      #
      # An earlier version remembered one comment id instead. That covered the
      # single-reply case and nothing else — a handler that posts two comments
      # (#post_approach_note, then the pull-request links) left the first one
      # unguarded, and every comment OpenProject::Pull itself posts was never recorded at all.
      # The author is already on every cached comment (#build_comments), and
      # #ensure_bot_identity! guarantees `own_user_id` is present, so this needs
      # no bookkeeping and cannot fall behind.
      def own_comment?(comment)
        Resource.href_id(comment["user_href"]) == own_user_id
      end

      # A comment triggers opilot when it either contains the literal text
      # "@opilot" (case-insensitive) or carries an OpenProject CKEditor mention
      # element whose data-id is opilot's own user id. The literal match covers
      # plain-text references and mentions that render the handle as text; the
      # data-id match covers the OP-native @-mention (made via the editor's picker),
      # which holds even when the bot's display name renders as a bare emoji and so
      # contains no "opilot" text at all.
      def opilot_mentioned?(text)
        str = text.to_s
        return true if str.match?(/\@opilot\b/i)
        id = own_user_id
        return false if id.empty?
        str.match?(%r{<mention\b[^>]*\bdata-id="#{Regexp.escape(id)}"})
      end

      # The raw filters JSON for the poll: one `comment` clause (operator `~`,
      # "contains"), keyed on opilot's own OpenProject display name. There is no
      # OR across independent terms for this filter type (OpenProject's `contains`
      # operator takes only the first value and ANDs its whitespace-split tokens),
      # so this is deliberately the bot's one real name rather than trying to also
      # match a literal "@opilot"/"@chomper" — see CLAUDE.md for the accepted
      # narrowing this implies.
      def mention_filter_json
        Clients::OpenProject::Query.filter("comment", "~", bot_display_name)
      end

      # OPilot's own OpenProject identity, resolved from /users/me and memoized
      # for the lifetime of this OpenProject::Pull (a failed lookup is cached too, so it's not
      # retried every comment/poll). `id` does two jobs — it recognises an
      # OP-native @-mention by data-id (#opilot_mentioned?) and it recognises
      # opilot's own comments by author (#own_comment?); `name` is the poll's
      # search term (#mention_filter_json). Both fall back to "" when the lookup
      # fails, which #ensure_bot_identity! turns into a hard stop.
      def own_user
        return @own_user if defined?(@own_user)
        @own_user = begin
          _, me = @api.me
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
