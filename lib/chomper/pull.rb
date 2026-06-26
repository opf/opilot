require "json"
require "tempfile"
require "time"
require_relative "clients"

module Chomper
  # `project_ids` / `project_idents` / `project_names` are parallel arrays.
  # `project_ids` (numeric) scope the query; `project_idents` are the semantic
  # identifiers, used for display when present (see Pull#describe_filters).
  FilterSet = Struct.new(:project_ids, :project_idents, :project_names,
                         :type_ids, :status_ids, :version_ids,
                         :type_names, :status_names, :version_names, :scan_from_at, keyword_init: true)

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

    # Poll OpenProject for the watched work packages and turn any unacted
    # @chomper comment into a Chomper::Intent. De-duplication is by
    # `last_acted_comment_at` in item.json, which the agent sets only AFTER a
    # handle succeeds — so an unprocessed trigger is re-emitted on the next poll
    # (at-least-once delivery). Every matching WP is scanned each poll so a
    # re-fire after a crash is not missed.
    def poll_intents(filters)
      @scan_from_at = filters.scan_from_at
      fj = filters_json(filters)

      intents = []
      changed = 0
      processed = 0; progressed = false; reached_floor = false
      page = 1; page_size = 50; total_written = 0; total = 0
      loop do
        break if Chomper.stopping?
        code, resp = @api.work_packages(filters_json: fj, page: page, page_size: page_size)
        raise Chomper::FatalError, "API returned HTTP #{code} fetching work packages" if code != 200
        raise Chomper::FatalError, "API returned unparseable response fetching work packages" if resp.nil?

        count = resp["count"].to_i
        total = resp["total"].to_i
        break if count == 0

        (resp.dig("_embedded", "elements") || []).each do |wp|
          break if Chomper.stopping?
          # Results are sorted updatedAt desc, and posting a @chomper comment bumps
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
          intent = intent_from_comments(wp, comments)
          intents << intent if intent
        end

        break if reached_floor || Chomper.stopping?
        total_written += count
        break if total_written >= total
        page += 1
      end
      print "\r\033[K" if progressed   # clear the heartbeat before the poll summary

      @scanned_count = processed
      @changed_count = changed
      intents
    end

    # Record that a trigger comment has been fully handled, so it is not
    # re-emitted on later polls. Called by the agent after a successful handle.
    def mark_acted(item_id, comment_at)
      mark_chomper_acted(item_id, comment_at)
    end

    # Record the ID of a note posted by chomper so it is never re-detected as a
    # trigger. Called by the agent after successfully posting a reply.
    def record_chomper_comment(wp_id, comment_id)
      item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
      return unless item_path.exist?
      data = JSON.parse(item_path.read)
      data["last_chomper_comment_id"] = comment_id.to_s
      item_path.write(JSON.generate(data))
    end

    # Agent mode acts only on explicit @chomper triggers, so it does not narrow
    # by type/status/version (a user may @chomper a WP of any kind). It needs
    # only the project scope plus the scan window.
    def load_or_prompt_agent_filters
      if (saved = read_agent_filters)
        puts "  Saved filters: #{describe_filters(saved)}"
        print "  Reuse saved filters? [Y/n]: "
        if $stdin.gets.chomp.downcase != "n"
          # The scan window is a per-session choice, but persist whatever was
          # picked so the next run can offer it as the default and resume from
          # where this session started rather than skipping ahead to now.
          saved.scan_from_at = prompt_scan_from(saved.scan_from_at)
          save_agent_filters(saved)
          return saved
        end
      end
      filters = prompt_agent_filters
      save_agent_filters(filters)
      filters
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
    # let Claude read the full detail on demand. Returns an array of
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

    # Prompt for the project scope only (plus the scan window) — the agent-mode
    # filter. Produces a FilterSet with no type/status/version, so #filters_json
    # scopes the poll to the chosen projects and nothing else.
    def prompt_agent_filters
      puts ""
      puts "=== Search filters ==="
      puts ""
      project_ids, project_idents, project_names = prompt_projects
      scan_from_at = prompt_scan_from(saved_scan_from_at)
      puts ""
      FilterSet.new(
        project_ids:    project_ids,
        project_idents: project_idents,
        project_names:  project_names,
        scan_from_at:   scan_from_at
      )
    end

    # Prompt for one or more projects, validating each and resolving it to the
    # numeric id the project_id filter requires while keeping the semantic
    # identifier (and name) for display. Returns [ids, idents, names].
    def prompt_projects
      loop do
        print "  Project(s), comma-separated [TTP2]: "
        reply = $stdin.gets.chomp
        reply = "TTP2" if reply.empty?
        idents = reply.split(",").map(&:strip).reject(&:empty?).uniq

        resolved = idents.map { |ident| [ident, *@api.project(ident)] }   # [ident, code, data]
        bad = resolved.select { |_ident, code, _| code != 200 }.map(&:first)
        unless bad.empty?
          puts "  Project(s) not found: #{bad.join(", ")} — please try again."
          next
        end
        ids    = resolved.map { |_ident, _code, data| data["id"].to_s }
        # Prefer the canonical identifier; fall back to whatever the user typed.
        idents = resolved.map { |ident, _code, data| data["identifier"] || ident }
        names  = resolved.map { |_ident, _code, data| data["name"] }
        return [ids, idents, names]
      end
    end

    # Ask how far back the comment scanner should look, returning the parsed
    # floor timestamp (nil = from now). Shared by the fresh-filter flow and the
    # reuse-saved-filters flow, so the window is always chosen interactively.
    # `previous` (the last session's chosen floor, if any) becomes the offered
    # default, so pressing Enter resumes from where the previous run left off
    # instead of jumping forward to now.
    def prompt_scan_from(previous = nil)
      print %(  How far back should the comment scanner look? (e.g. "2h", "3 days", "1 week", "1 month")\n  Scan from [#{previous || "now"}]: )
      reply = $stdin.gets.chomp
      return previous if previous && reply.strip.empty?
      parse_scan_from_input(reply)
    end

    private

    # The scan floor chosen on the last run, read straight from the saved
    # filters file. Offered as the default when re-prompting (even when the user
    # declines to reuse the rest of the saved filters), so a fresh session resumes
    # from where the previous one stopped rather than skipping ahead to now.
    def saved_scan_from_at
      return nil unless agent_filters_path.exist?
      JSON.parse(agent_filters_path.read)["scan_from_at"]
    rescue JSON::ParserError
      nil
    end

    # Saved filters for agent mode: only the project scope (and scan window)
    # matter, so this tolerates a file that has no type/status.
    def read_agent_filters
      return nil unless agent_filters_path.exist?
      data = JSON.parse(agent_filters_path.read)
      project_ids, project_idents, project_names = saved_projects(data)
      return nil if project_ids.empty?
      FilterSet.new(
        project_ids:    project_ids,
        project_idents: project_idents,
        project_names:  project_names,
        scan_from_at:   data["scan_from_at"]
      )
    rescue JSON::ParserError
      nil
    end

    # The saved project selection as [ids, idents, names]. Upgrades the
    # pre-multi-project format on the fly: an old file stored a single
    # `project_id` identifier, but the project_id filter now needs a numeric id,
    # so resolve it via the API. Returns [[], [], []] when nothing usable is
    # saved (caller then re-prompts).
    def saved_projects(data)
      if data["project_ids"]
        ids = Array(data["project_ids"])
        # Older multi-project files predate project_idents — resolve each id to
        # its semantic identifier so the display matches a fresh selection.
        idents = data["project_idents"] ? Array(data["project_idents"]) : ids.map { |id| resolve_ident(id) }
        return [ids, idents, Array(data["project_names"])]
      end

      ident = data["project_id"]
      return [[], [], []] if ident.to_s.empty?
      code, project = @api.project(ident)
      return [[], [], []] unless code == 200 && project
      [[project["id"].to_s], [project["identifier"] || ident], [project["name"]]]
    rescue => e
      puts "  Warning: could not upgrade saved project filter (#{e.message}); please re-select."
      [[], [], []]
    end

    # The semantic identifier for a project, looked up by its (numeric) id.
    # Falls back to the id itself if the lookup fails, so a hiccup only costs the
    # nicer label, never the saved filter.
    def resolve_ident(id)
      code, project = @api.project(id)
      (code == 200 && project && project["identifier"]) || id
    rescue
      id
    end

    def describe_filters(f)
      # Show the semantic identifier when we have it, else the numeric id.
      labels = Array(f.project_idents).empty? ? Array(f.project_ids) : Array(f.project_idents)
      projects = labels.zip(Array(f.project_names))
        .map { |id, name| name ? "#{id} — #{name}" : id }.join("; ")
      # Agent-mode filters carry no type/status/version, so show only the parts
      # that are actually set.
      parts = ["projects=[#{projects}]"]
      parts << "types=[#{f.type_names}]"       if present?(f.type_names)
      parts << "statuses=[#{f.status_names}]"  if present?(f.status_names)
      parts << "versions=[#{f.version_names}]" if present?(f.version_names)
      parts.join("  ")
    end

    def present?(str)
      !str.nil? && !str.empty?
    end

    # Detect the latest unacted @chomper trigger on a WP and turn it into an
    # Intent. Acknowledges receipt with 👀 and enforces the user-id allowlist
    # (a non-allowlisted trigger is marked acted and dropped, never emitted).
    def intent_from_comments(wp, comments)
      trigger = chomper_trigger_comment(wp_display_id(wp), comments)
      return nil unless trigger

      if @ctx.allowed_op_user_ids.any?
        user_id = trigger_user_id(trigger)
        unless user_id && @ctx.allowed_op_user_ids.include?(user_id)
          puts "  [@chomper] Ignoring trigger from user #{user_id || "unknown"} — not in allowlist"
          mark_chomper_acted(wp_display_id(wp), trigger["created_at"])
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

    # Map @chomper trigger text to a [command, free-text] pair. Anything that is
    # not a known command word becomes a :chat carrying the message body.
    def parse_command(raw)
      text = strip_mention(raw)
      case text
      when /\A@chomper\s+plan\b\s*(.*)/im    then [:plan,    $1.strip]
      when /\A@chomper\s+fix\b\s*(.*)/im      then [:fix,     $1.strip]
      when /\A@chomper\s+approve\b/i          then [:approve, nil]
      else [:chat, text.sub(/@chomper\s*/i, "").strip]
      end
    end

    # OpenProject's CKEditor wraps the @chomper handle in mention markup, e.g.
    #   <mention ... data-text="🤖">@Chomper 🤖</mention> approve
    # Normalise a leading mention to a plain "@chomper" token (so display is
    # robust even when it renders as just an emoji), drop other mentions to their
    # visible text, and strip any remaining HTML so the command word is exposed.
    def strip_mention(raw)
      text = raw.to_s.sub(%r{\A\s*<mention\b[^>]*>.*?</mention>}im, "@chomper")
      text = text.gsub(%r{<mention\b[^>]*>(.*?)</mention>}im) { $1 }
      text.gsub(/<[^>]+>/, " ").gsub("&nbsp;", " ").gsub(/\s+/, " ").strip
    end

    # Builds the raw filters JSON for a FilterSet. The `project_id` filter scopes
    # the global work-packages endpoint to the selected projects; its values must
    # be NUMERIC project ids (OpenProject coerces them with to_i — identifiers
    # would match nothing). The status/type/version clauses are each emitted only
    # when the FilterSet carries values for them; agent mode sets none and so
    # polls the projects unfiltered.
    def filters_json(filters)
      clauses = [%Q({"project_id":{"operator":"=","values":#{JSON.generate(Array(filters.project_ids))}}})]
      clauses << %Q({"status":{"operator":"=","values":#{JSON.generate(Array(filters.status_ids))}}})   unless Array(filters.status_ids).empty?
      clauses << %Q({"type":{"operator":"=","values":#{JSON.generate(Array(filters.type_ids))}}})        unless Array(filters.type_ids).empty?
      clauses << %Q({"version":{"operator":"=","values":#{JSON.generate(Array(filters.version_ids))}}})  unless Array(filters.version_ids).empty?
      "[#{clauses.join(",")}]"
    end

    # The user-facing work package id: semantic ("PROJ-123") when the instance
    # runs in semantic mode, numeric otherwise. The API accepts either form in
    # work-package routes, so this is the only id chomper needs to keep.
    # Falls back to "id" for instances that predate the displayId field.
    def wp_display_id(wp)
      id = wp["displayId"]
      (id.nil? || id.to_s.empty? ? wp["id"] : id).to_s
    end

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
        full["last_acted_comment_at"]  = prev["last_acted_comment_at"]  if prev.key?("last_acted_comment_at")
        full["last_chomper_comment_id"] = prev["last_chomper_comment_id"] if prev.key?("last_chomper_comment_id")
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
        "url"         => "#{@ctx.op_url}/work_packages/#{wp_display_id(wp)}",
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

    def agent_filters_path
      @ctx.state_dir / "op_agent_filters.json"
    end

    # Persist agent-mode filters. They carry no type/status/version (those fields
    # are nil), so those keys are only written when the FilterSet actually sets
    # them — any keys already in the file are merged through, not clobbered.
    def save_agent_filters(filters)
      existing = (agent_filters_path.exist? && Helpers.safe_json_read(agent_filters_path)) || {}
      data = existing.merge(
        "project_ids"    => filters.project_ids,
        "project_idents" => filters.project_idents,
        "project_names"  => filters.project_names,
        "scan_from_at"   => filters.scan_from_at
      )
      {
        "type_ids"      => filters.type_ids,
        "status_ids"    => filters.status_ids,
        "version_ids"   => filters.version_ids,
        "type_names"    => filters.type_names,
        "status_names"  => filters.status_names,
        "version_names" => filters.version_names
      }.each { |k, v| data[k] = v unless v.nil? }
      Helpers.write_json_atomic(agent_filters_path, data, "agent_filters")
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
      @api.post_emoji_reaction(activity_id, reaction: "eyes")
    rescue => e
      puts "  Warning: could not post 👀 reaction: #{e.message}"
    end

    def chomper_trigger_comment(wp_id, comments)
      item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
      saved = Helpers.safe_json_read(item_path) || {}
      cutoff = [saved["last_acted_comment_at"], @scan_from_at].compact.max
      last_chomper_id = saved["last_chomper_comment_id"]
      comments
        .reject { |c| last_chomper_id && c["id"] == last_chomper_id }
        .select { |c| chomper_mentioned?(c["text"]) }
        .select { |c| cutoff.nil? || c["created_at"] > cutoff }
        .max_by { |c| c["created_at"] }
    end

    # A comment triggers chomper when it either contains the literal text
    # "@chomper" (case-insensitive) or carries an OpenProject CKEditor mention
    # element whose data-id is chomper's own user id. The literal match covers
    # plain-text references and mentions that render the handle as text; the
    # data-id match covers the OP-native @-mention (made via the editor's picker),
    # which holds even when the bot's display name renders as a bare emoji and so
    # contains no "chomper" text at all.
    def chomper_mentioned?(text)
      str = text.to_s
      return true if str.match?(/\@chomper\b/i)
      id = own_user_id
      return false if id.empty?
      str.match?(%r{<mention\b[^>]*\bdata-id="#{Regexp.escape(id)}"})
    end

    # Chomper's own OpenProject user id, derived from /users/me and memoized for
    # the lifetime of this Pull (the nil result is cached too, so a failed lookup
    # is not retried every comment). Used to recognise an OP-native @-mention of
    # the bot. Returns "" when it can't be resolved, so detection falls back to
    # the literal "@chomper" match.
    def own_user_id
      return @own_user_id if defined?(@own_user_id)
      @own_user_id = begin
        _, me = @api.me
        me&.dig("_links", "self", "href").to_s.split("/").last.to_s
      rescue => e
        puts "  Warning: could not resolve chomper's own user id: #{e.message}"
        ""
      end
    end

    def mark_chomper_acted(wp_id, created_at)
      item_path = Helpers.item_dir(@ctx, wp_id) / "item.json"
      return unless item_path.exist?
      data = JSON.parse(item_path.read)
      data["last_acted_comment_at"] = created_at
      item_path.write(JSON.generate(data))
    end

  end
end
