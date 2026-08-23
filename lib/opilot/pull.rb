require "json"
require "time"
require_relative "clients"

module OPilot
  class Pull
    # Stats from the most recent poll (for logging): total scanned, and how many
    # had changed (were re-fetched rather than served from cache).
    attr_reader :scanned_count, :changed_count

    def initialize(ctx)
      @ctx = ctx
      @api = Clients::OpenProject.new(ctx.op_url, ctx.token)
      @scanned_count = 0
      @changed_count = 0
    end

    # Poll OpenProject for work packages whose comments mention opilot's own
    # account (OpenProject's server-side `comment` filter, keyed on the bot's
    # real display name — see #mention_filter_json) and turn any unacted
    # @opilot comment into a OPilot::Intent. De-duplication is by
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
      item_path.write(JSON.generate(data))
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
    # Agent#setup (so a broken identity fails loudly once, before the loop
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
      path.exist? ? JSON.parse(path.read) : nil
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
      (resp.dig("_embedded", "elements") || []).filter_map do |rel|
        from = href_id(rel.dig("_links", "from", "href"))
        to   = href_id(rel.dig("_links", "to", "href"))
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
      if (parent = href_id(wp.dig("_links", "parent", "href")))
        pairs << [parent, "parent"]
      end
      Array(wp.dig("_links", "children")).each do |child|
        id = href_id(child["href"])
        pairs << [id, "child"] if id
      end
      pairs
    end

    # The trailing id of a work-package href ("/api/v3/work_packages/108" → "108").
    private def href_id(href)
      id = href.to_s.split("/").last
      id.to_s.empty? ? nil : id
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

        (resp.dig("_embedded", "elements") || []).each do |wp|
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
      return nil unless agent_filters_path.exist?
      JSON.parse(agent_filters_path.read)["scan_from_at"]
    rescue JSON::ParserError
      nil
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
    # Intent. Acknowledges receipt with 👀 and enforces the user-id allowlist
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
      Intent.new(
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

    # Map @opilot trigger text to a [command, free-text] pair. Anything that is
    # not a known command word becomes a :chat carrying the message body.
    def parse_command(raw)
      text = strip_mention(raw)
      case text
      # `build`, alias `fix` — the same pair `./opilot dev` takes. The list is
      # deliberately short: an unknown word still gets an answer, falling through
      # to :chat, whose prompt names the real command. The intent stays `:ship`
      # because publishing is what the handler does.
      when /\A@opilot\s+(?:build|fix)\b\s*(.*)/im
        [:ship, $1.strip]
      # The second command word. Two words, because `create` alone would read as
      # a request to create anything at all — a branch, a PR, a comment — and the
      # noun is what makes it one operation. #strip_mention has already collapsed
      # the whitespace, so "create   wp" arrives normalised.
      when /\A@opilot\s+create\s+(?:wp|work\s+package)\b\s*(.*)/im
        [:create_wp, $1.strip]
      # Chat lenses: a preset instruction over the ordinary chat path, with any
      # trailing text folded in as a focus hint (see Prompts::LENSES).
      when /\A@opilot\s+(grill|summarize)\b\s*(.*)/im then [:chat, Prompts.lens($1, $2)]
      else [:chat, text.sub(/@opilot\s*/i, "").strip]
      end
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

    # The user-facing work package id — see Helpers.display_id, which the agent's
    # `create wp` reply shares.
    def wp_display_id(wp)
      Helpers.display_id(wp)
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

    def fetch_work_package_item(wp)
      wp_id = wp_display_id(wp)
      item_dir  = Helpers.item_dir(@ctx, wp_id)
      item_path = item_dir / "item.json"

      if item_path.exist?
        cached = JSON.parse(item_path.read)
        if cached["updated_at"] == wp["updatedAt"]
          return [true, cached["comments"] || []]
        end
      end

      acts_code, acts = @api.work_package_activities(wp_id)
      acts = { "_embedded" => { "elements" => [] } } unless acts_code == 200

      rxns_code, rxns = @api.work_package_emoji_reactions(wp_id)
      rxns = { "_embedded" => { "elements" => [] } } unless rxns_code == 200

      comments = build_comments(
        acts.dig("_embedded", "elements") || [],
        rxns.dig("_embedded", "elements") || []
      )

      full = build_full_item(wp, comments)
      if item_path.exist?
        prev = Helpers.safe_json_read(item_path) || {}
        CARRIED_KEYS.each { |key| full[key] = prev[key] if prev.key?(key) }
      end
      item_dir.mkpath
      item_path.write(JSON.generate(full))

      [false, comments]
    end

    def build_comments(activities, reactions)
      rxn_index = reactions
        .group_by { |r| r.dig("_links", "reactable", "href")&.split("/")&.last }
        .transform_values { |rs| rs.map { |r| [r["reaction"], r["reactionsCount"]] }.to_h }

      activities
        .select { |a| a.dig("comment", "raw").to_s.strip != "" }
        .map do |a|
          {
            "id"         => a["id"].to_s,
            "user"       => a.dig("_embedded", "user", "name") || a.dig("_links", "user", "title"),
            "user_href"  => a.dig("_links", "user", "href"),
            "created_at" => a["createdAt"],
            "text"       => a.dig("comment", "raw"),
            "internal"   => a["internal"] == true,
            "reactions"  => rxn_index[a["id"].to_s] || {}
          }
        end
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

    def parse_scan_from_input(input)
      Helpers.parse_scan_from(input)
    end

    # The comment author's OpenProject user id, taken straight from the activity's
    # `_links.user.href` (e.g. "/api/v3/users/534" → "534"). No API call: an
    # activity never carries the author's email or name, only this id, and a
    # non-admin token can't read another user's email anyway.
    def trigger_user_id(comment)
      href = comment["user_href"].to_s
      href.empty? ? nil : href.split("/").last
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
    # unguarded, and every comment Pull itself posts was never recorded at all.
    # The author is already on every cached comment (#build_comments), and
    # #ensure_bot_identity! guarantees `own_user_id` is present, so this needs
    # no bookkeeping and cannot fall behind.
    def own_comment?(comment)
      href_id(comment["user_href"]) == own_user_id
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
      Clients::OpenProject.filter("comment", "~", bot_display_name)
    end

    # OPilot's own OpenProject identity, resolved from /users/me and memoized
    # for the lifetime of this Pull (a failed lookup is cached too, so it's not
    # retried every comment/poll). `id` does two jobs — it recognises an
    # OP-native @-mention by data-id (#opilot_mentioned?) and it recognises
    # opilot's own comments by author (#own_comment?); `name` is the poll's
    # search term (#mention_filter_json). Both fall back to "" when the lookup
    # fails, which #ensure_bot_identity! turns into a hard stop.
    def own_user
      return @own_user if defined?(@own_user)
      @own_user = begin
        _, me = @api.me
        { "id" => me&.dig("_links", "self", "href").to_s.split("/").last.to_s,
          "name" => me&.dig("name").to_s }
      rescue => e
        puts "  Warning: could not resolve opilot's own OpenProject identity: #{e.message}"
        { "id" => "", "name" => "" }
      end
    end

    def own_user_id;      own_user["id"];   end
    def bot_display_name; own_user["name"]; end

    def mark_opilot_acted(wp_id, created_at)
      item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
      return unless item_path.exist?
      data = JSON.parse(item_path.read)
      data["last_acted_comment_at"] = created_at
      item_path.write(JSON.generate(data))
    end

  end
end
