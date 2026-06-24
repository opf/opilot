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
          # Stop here instead of re-listing the whole backlog every cycle.
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

    def load_or_prompt_agent_filters
      load_or_prompt_filters(ask_scan_from: true)
    end

    def load_or_prompt_backlog_filters
      load_or_prompt_filters(ask_scan_from: false)
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

    # Saved filters without the reuse prompt, or nil when none are saved.
    # `backlog show` presents cached data, so it takes whatever is on disk.
    def saved_backlog_filters
      saved = read_saved_filters
      puts "  Filters: #{describe_filters(saved)}" if saved
      saved
    end

    # Fetch all work packages matching filters (without requiring @chomper triggers).
    # Saves each WP to item.json (same cache as poll_intents). When module_field_key
    # is given, enriches item.json with a "module" key holding the first module
    # title from that _links entry.
    def fetch_all_items(filters, module_field_key: nil)
      fj = filters_json(filters)
      items = []
      page = 1; page_size = 50; total_written = 0
      processed = 0; from_cache = 0
      loop do
        code, resp = @api.work_packages(filters_json: fj, page: page, page_size: page_size)
        raise Chomper::FatalError, "API returned HTTP #{code} fetching work packages" if code != 200
        raise Chomper::FatalError, "API returned unparseable response" if resp.nil?
        count = resp["count"].to_i; total = resp["total"].to_i
        break if count == 0
        (resp.dig("_embedded", "elements") || []).each do |wp|
          cached, = fetch_work_package_item(wp)
          processed += 1
          from_cache += 1 if cached
          print "\r  #{processed}/#{total} work packages (#{from_cache} cached)…"
          $stdout.flush
          path = Helpers.item_dir(@ctx, wp_display_id(wp)) / "item.json"
          next unless path.exist?
          data = JSON.parse(path.read)
          if module_field_key
            data["module"] = first_module_title(wp, module_field_key)
            path.write(JSON.generate(data))
          end
          items << data
        end
        total_written += count
        break if total_written >= total
        page += 1
      end
      puts "" if processed > 0
      items
    end

    def prompt_search_filters(ask_scan_from: true)
      puts ""
      puts "=== Search filters ==="
      puts ""

      # One or more projects. Each is validated (and resolved to its numeric id,
      # which the project_id filter requires) while also keeping its semantic
      # identifier for display. The type list is drawn from the first project —
      # types are defined per project but typically shared across an instance,
      # and a single source keeps the prompt simple.
      project_ids = nil; project_idents = nil; project_names = nil; types_data = nil
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
        project_ids    = resolved.map { |_ident, _code, data| data["id"].to_s }
        # Prefer the canonical identifier; fall back to whatever the user typed.
        project_idents = resolved.map { |ident, _code, data| data["identifier"] || ident }
        project_names  = resolved.map { |_ident, _code, data| data["name"] }
        _tc, types_data = @api.project_types(idents.first)
        break
      end

      type_ids, sel_names = select_by_name(
        types_data.dig("_embedded", "elements") || [],
        label: "Types", prompt: "Type(s), comma-separated [bug]", default: "bug"
      )

      _code, statuses_data = @api.statuses
      status_ids, sel_status_names = select_by_name(
        statuses_data.dig("_embedded", "elements") || [],
        label: "Statuses", prompt: "Status(es), comma-separated [new, confirmed]", default: "new, confirmed"
      )

      # Versions are project-scoped, so the candidate list is only well-defined
      # for a single project. With several selected, skip the version filter.
      version_ids = []; sel_ver_names = []
      if project_ids.length == 1
        ver_code, versions_data = @api.project_versions(project_ids.first)
        if ver_code == 200
          version_ids, sel_ver_names = select_by_name(
            versions_data.dig("_embedded", "elements") || [],
            label: "Versions", prompt: "Version(s), comma-separated (leave blank to skip)", default: ""
          )
        else
          puts "  Warning: could not fetch versions (HTTP #{ver_code}) — skipping version filter"
        end
      else
        puts "  Versions: skipped (version filtering is only offered for a single project)."
      end

      scan_from_at = ask_scan_from ? prompt_scan_from : nil

      puts ""
      FilterSet.new(
        project_ids:    project_ids,
        project_idents: project_idents,
        project_names:  project_names,
        type_ids:       type_ids,
        status_ids:     status_ids,
        version_ids:    version_ids,
        type_names:     sel_names.join(", "),
        status_names:   sel_status_names.join(", "),
        version_names:  sel_ver_names.empty? ? nil : sel_ver_names.join(", "),
        scan_from_at:   scan_from_at
      )
    end

    # Ask how far back the comment scanner should look, returning the parsed
    # floor timestamp (nil = from now). Shared by the fresh-filter flow and the
    # reuse-saved-filters flow, so the window is always chosen interactively.
    def prompt_scan_from
      print %(  How far back should the comment scanner look? (e.g. "2h", "3 days", "1 week", "1 month")\n  Scan from [now]: )
      parse_scan_from_input($stdin.gets.chomp)
    end

    private

    # Prompt for a comma-separated subset of named API `elements` (types,
    # statuses, versions). Prints the available names, reads a reply (falling
    # back to `default`), and returns [selected_ids, selected_names_downcased].
    # An empty effective reply returns [[], []] (only reachable when `default`
    # is blank, i.e. the optional version filter); otherwise no match is fatal.
    def select_by_name(elements, label:, prompt:, default:)
      puts "  #{label} available: #{elements.map { |e| e["name"] }.join(", ")}"
      print "  #{prompt}: "
      reply = $stdin.gets.chomp
      reply = default if reply.empty?
      return [[], []] if reply.empty?

      selected = reply.split(",").map(&:strip).map(&:downcase)
      ids = elements.select { |e| selected.include?(e["name"].downcase) }.map { |e| e["id"].to_s }
      raise Chomper::FatalError, "None of the specified #{label.downcase} found: #{selected.join(", ")}" if ids.empty?
      [ids, selected]
    end

    def load_or_prompt_filters(ask_scan_from:)
      if (saved = read_saved_filters)
        puts "  Saved filters: #{describe_filters(saved)}"
        print "  Reuse saved filters? [Y/n]: "
        if $stdin.gets.chomp.downcase != "n"
          # The scan window is a per-session choice, not part of the saved set,
          # so still ask for it when relevant (op-agent) even on reuse.
          saved.scan_from_at = prompt_scan_from if ask_scan_from
          return saved
        end
      end
      filters = prompt_search_filters(ask_scan_from: ask_scan_from)
      save_agent_filters(filters)
      filters
    end

    def read_saved_filters
      return nil unless agent_filters_path.exist?
      data = JSON.parse(agent_filters_path.read)
      return nil unless data["type_names"] && data["status_names"]
      project_ids, project_idents, project_names = saved_projects(data)
      return nil if project_ids.empty?
      FilterSet.new(
        project_ids:    project_ids,
        project_idents: project_idents,
        project_names:  project_names,
        type_ids:       data["type_ids"],
        status_ids:     data["status_ids"],
        version_ids:    data["version_ids"],
        type_names:     data["type_names"],
        status_names:   data["status_names"],
        version_names:  data["version_names"],
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
      version_label = f.version_names ? "  versions=[#{f.version_names}]" : ""
      # Show the semantic identifier when we have it, else the numeric id.
      labels = Array(f.project_idents).empty? ? Array(f.project_ids) : Array(f.project_idents)
      projects = labels.zip(Array(f.project_names))
        .map { |id, name| name ? "#{id} — #{name}" : id }.join("; ")
      "projects=[#{projects}]  types=[#{f.type_names}]  statuses=[#{f.status_names}]#{version_label}"
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
        user_href:  trigger["user_href"]
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

    # Builds the raw filters JSON for a FilterSet (project + status + type,
    # optional version). The `project_id` filter scopes the global work-packages
    # endpoint to the selected projects; its values must be NUMERIC project ids
    # (OpenProject coerces them with to_i — identifiers would match nothing).
    def filters_json(filters)
      project_clause = %Q({"project_id":{"operator":"=","values":#{JSON.generate(Array(filters.project_ids))}}})
      status_clause  = %Q({"status":{"operator":"=","values":#{JSON.generate(filters.status_ids)}}})
      type_clause    = %Q({"type":{"operator":"=","values":#{JSON.generate(filters.type_ids)}}})
      version_clause = filters.version_ids.empty? ? "" :
        %Q(,{"version":{"operator":"=","values":#{JSON.generate(filters.version_ids)}}})
      %Q([#{project_clause},#{status_clause},#{type_clause}#{version_clause}])
    end

    # Multi-value Module custom field: a WP can carry several modules; we group
    # by the first one only.
    def first_module_title(wp, module_field_key)
      links = wp.dig("_links", module_field_key)
      links = [links] unless links.is_a?(Array)
      links.filter_map { |l| l["title"] if l.is_a?(Hash) }.first.to_s
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

    def save_agent_filters(filters)
      Helpers.write_json_atomic(agent_filters_path, {
        "project_ids"    => filters.project_ids,
        "project_idents" => filters.project_idents,
        "project_names"  => filters.project_names,
        "type_ids"      => filters.type_ids,
        "status_ids"    => filters.status_ids,
        "version_ids"   => filters.version_ids,
        "type_names"    => filters.type_names,
        "status_names"  => filters.status_names,
        "version_names" => filters.version_names,
        "scan_from_at"  => filters.scan_from_at
      }, "agent_filters")
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
