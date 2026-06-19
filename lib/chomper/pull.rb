require "json"
require "tempfile"
require "time"
require_relative "clients"

module Chomper
  FilterSet = Struct.new(:project_id, :project_name, :type_ids, :status_ids, :version_ids,
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
        code, resp = @api.work_packages(filters.project_id, filters_json: fj, page: page, page_size: page_size)
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
        code, resp = @api.work_packages(filters.project_id, filters_json: fj, page: page, page_size: page_size)
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

      project_id = nil
      types_data = nil
      loop do
        print "  Project [TTP2]: "
        project_id = $stdin.gets.chomp
        project_id = "TTP2" if project_id.empty?
        code, types_data = @api.project_types(project_id)
        break if code == 200
        puts "  Project '#{project_id}' not found (HTTP #{code}) — please try again."
      end
      _pc, project_data = @api.project(project_id)
      project_name = project_data&.dig("name")

      type_ids, sel_names = select_by_name(
        types_data.dig("_embedded", "elements") || [],
        label: "Types", prompt: "Type(s), comma-separated [bug]", default: "bug"
      )

      _code, statuses_data = @api.statuses
      status_ids, sel_status_names = select_by_name(
        statuses_data.dig("_embedded", "elements") || [],
        label: "Statuses", prompt: "Status(es), comma-separated [new, confirmed]", default: "new, confirmed"
      )

      version_ids = []; sel_ver_names = []
      ver_code, versions_data = @api.project_versions(project_id)
      if ver_code == 200
        version_ids, sel_ver_names = select_by_name(
          versions_data.dig("_embedded", "elements") || [],
          label: "Versions", prompt: "Version(s), comma-separated (leave blank to skip)", default: ""
        )
      else
        puts "  Warning: could not fetch versions (HTTP #{ver_code}) — skipping version filter"
      end

      scan_from_at = nil
      if ask_scan_from
        puts "  How far back should the comment scanner look?"
        puts "  Formats: \"1h\", \"2 days\", \"1 week\""
        print "  Scan from [now]: "
        scan_from_at = parse_scan_from_input($stdin.gets.chomp)
      end

      puts ""
      FilterSet.new(
        project_id:    project_id,
        project_name:  project_name,
        type_ids:      type_ids,
        status_ids:    status_ids,
        version_ids:   version_ids,
        type_names:    sel_names.join(", "),
        status_names:  sel_status_names.join(", "),
        version_names: sel_ver_names.empty? ? nil : sel_ver_names.join(", "),
        scan_from_at:  scan_from_at
      )
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
        return saved unless $stdin.gets.chomp.downcase == "n"
      end
      filters = prompt_search_filters(ask_scan_from: ask_scan_from)
      save_agent_filters(filters)
      filters
    end

    def read_saved_filters
      return nil unless agent_filters_path.exist?
      data = JSON.parse(agent_filters_path.read)
      return nil unless data["type_names"] && data["status_names"]
      FilterSet.new(
        project_id:    data["project_id"],
        project_name:  data["project_name"],
        type_ids:      data["type_ids"],
        status_ids:    data["status_ids"],
        version_ids:   data["version_ids"],
        type_names:    data["type_names"],
        status_names:  data["status_names"],
        version_names: data["version_names"],
        scan_from_at:  data["scan_from_at"]
      )
    rescue JSON::ParserError
      nil
    end

    def describe_filters(f)
      version_label = f.version_names ? "  versions=[#{f.version_names}]" : ""
      project_label = f.project_name ? "#{f.project_id} — #{f.project_name}" : f.project_id
      "project=[#{project_label}]  types=[#{f.type_names}]  statuses=[#{f.status_names}]#{version_label}"
    end

    # Detect the latest unacted @chomper trigger on a WP and turn it into an
    # Intent. Acknowledges receipt with 👀 and enforces the email allowlist
    # (a non-allowlisted trigger is marked acted and dropped, never emitted).
    def intent_from_comments(wp, comments)
      trigger = chomper_trigger_comment(wp_display_id(wp), comments)
      return nil unless trigger

      if @ctx.allowed_emails.any?
        email = resolve_user_email(trigger)
        unless @ctx.allowed_emails.include?(email.to_s)
          puts "  [@chomper] Ignoring trigger from #{trigger["user"]} (#{email || "unknown"}) — not in allowlist"
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

    # Builds the raw filters JSON for a FilterSet (status + type, optional version).
    def filters_json(filters)
      version_clause = filters.version_ids.empty? ? "" :
        %Q(,{"version":{"operator":"=","values":#{JSON.generate(filters.version_ids)}}})
      %Q([{"status":{"operator":"=","values":#{JSON.generate(filters.status_ids)}}},{"type":{"operator":"=","values":#{JSON.generate(filters.type_ids)}}}#{version_clause}])
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
        "project_id"    => filters.project_id,
        "project_name"  => filters.project_name,
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

    def resolve_user_email(comment)
      href = comment["user_href"].to_s
      return nil if href.empty?
      user_id = href.split("/").last
      _, user = @api.user(user_id)
      user&.dig("email")&.downcase
    rescue => e
      puts "  Warning: could not resolve email for #{comment["user"]}: #{e.message}"
      nil
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

    # A comment triggers chomper when it contains the literal text "@chomper"
    # (case-insensitive), either as plain text or inside a CKEditor mention element.
    def chomper_mentioned?(text)
      text.to_s.match?(/\@chomper\b/i)
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
