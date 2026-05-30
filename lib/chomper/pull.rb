require "json"
require "tempfile"

module Chomper
  FilterSet = Struct.new(:project_id, :project_name, :type_ids, :status_ids, :version_ids,
                         :type_names, :status_names, :version_names, keyword_init: true)

  class Pull
    # Stats from the most recent poll (for logging): total scanned, and how many
    # had changed (were re-fetched rather than served from cache).
    attr_reader :scanned_count, :changed_count

    def initialize(ctx)
      @ctx = ctx
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
      encoded = encoded_filters(filters)
      sort    = HTTP.encode_filters('[["updatedAt","desc"]]')

      intents = []
      changed = 0
      page = 1; page_size = 50; total_written = 0; total = 0
      loop do
        url = "#{@ctx.op_url}/api/v3/projects/#{filters.project_id}/work_packages" \
              "?pageSize=#{page_size}&offset=#{page}&filters=#{encoded}&sortBy=#{sort}"
        code, resp = HTTP.get_json(url, token: @ctx.token)
        raise Chomper::FatalError, "API returned HTTP #{code} — URL: #{url}" if code != 200
        raise Chomper::FatalError, "API returned unparseable response — URL: #{url}" if resp.nil?

        count = resp["count"].to_i
        total = resp["total"].to_i
        break if count == 0

        (resp.dig("_embedded", "elements") || []).each do |wp|
          cached, comments = fetch_work_package_item(wp)
          changed += 1 unless cached
          intent = intent_from_comments(wp, comments)
          intents << intent if intent
        end

        total_written += count
        break if total_written >= total
        page += 1
      end

      @scanned_count = total_written
      @changed_count = changed
      intents
    end

    # Record that a trigger comment has been fully handled, so it is not
    # re-emitted on later polls. Called by the agent after a successful handle.
    def mark_acted(item_id, comment_at)
      mark_chomper_acted(item_id, comment_at)
    end

    def load_or_prompt_agent_filters
      if agent_filters_path.exist?
        data = JSON.parse(agent_filters_path.read)
        if data["type_names"] && data["status_names"]
          saved = FilterSet.new(
            project_id:    data["project_id"],
            project_name:  data["project_name"],
            type_ids:      data["type_ids"],
            status_ids:    data["status_ids"],
            version_ids:   data["version_ids"],
            type_names:    data["type_names"],
            status_names:  data["status_names"],
            version_names: data["version_names"]
          )
          version_label = saved.version_names ? "  versions=[#{saved.version_names}]" : ""
          project_label = saved.project_name ? "#{saved.project_id} — #{saved.project_name}" : saved.project_id
          puts "  Saved filters: project=[#{project_label}]  types=[#{saved.type_names}]  statuses=[#{saved.status_names}]#{version_label}"
          print "  Reuse saved filters? [Y/n]: "
          return saved unless $stdin.gets.chomp.downcase == "n"
        end
      end
      filters = prompt_search_filters
      save_agent_filters(filters)
      filters
    end

    def prompt_search_filters
      puts ""
      puts "=== Search filters ==="
      puts ""

      project_id = nil
      types_data = nil
      loop do
        print "  Project [TTP2]: "
        project_id = $stdin.gets.chomp
        project_id = "TTP2" if project_id.empty?
        code, types_data = HTTP.get_json("#{@ctx.op_url}/api/v3/projects/#{project_id}/types", token: @ctx.token)
        break if code == 200
        puts "  Project '#{project_id}' not found (HTTP #{code}) — please try again."
      end
      _pc, project_data = HTTP.get_json("#{@ctx.op_url}/api/v3/projects/#{project_id}", token: @ctx.token)
      project_name = project_data&.dig("name")
      type_names = types_data.dig("_embedded", "elements")&.map { |e| e["name"] }&.join(", ") || ""
      puts "  Types available: #{type_names}"
      print "  Type(s), comma-separated [bug]: "
      sel_types = $stdin.gets.chomp
      sel_types = "bug" if sel_types.empty?

      sel_names = sel_types.split(",").map(&:strip).map(&:downcase)
      type_ids = (types_data.dig("_embedded", "elements") || [])
        .select { |e| sel_names.include?(e["name"].downcase) }
        .map { |e| e["id"].to_s }
      raise Chomper::FatalError, "None of the specified types found: #{sel_names.join(", ")}" if type_ids.empty?

      _code, statuses_data = HTTP.get_json!("#{@ctx.op_url}/api/v3/statuses", token: @ctx.token)
      status_names = statuses_data.dig("_embedded", "elements")&.map { |e| e["name"] }&.join(", ") || ""
      puts "  Statuses available: #{status_names}"
      print "  Status(es), comma-separated [new, confirmed]: "
      sel_statuses = $stdin.gets.chomp
      sel_statuses = "new, confirmed" if sel_statuses.empty?

      sel_status_names = sel_statuses.split(",").map(&:strip).map(&:downcase)
      status_ids = (statuses_data.dig("_embedded", "elements") || [])
        .select { |e| sel_status_names.include?(e["name"].downcase) }
        .map { |e| e["id"].to_s }
      raise Chomper::FatalError, "None of the specified statuses found: #{sel_status_names.join(", ")}" if status_ids.empty?

      version_ids = []; sel_ver_names = []
      ver_code, versions_data = HTTP.get_json("#{@ctx.op_url}/api/v3/projects/#{project_id}/versions", token: @ctx.token)
      if ver_code == 200
        ver_names = versions_data.dig("_embedded", "elements")&.map { |e| e["name"] }&.join(", ") || ""
        puts "  Versions available: #{ver_names}"
        print "  Version(s), comma-separated (leave blank to skip): "
        sel_versions = $stdin.gets.chomp
        unless sel_versions.empty?
          sel_ver_names = sel_versions.split(",").map(&:strip).map(&:downcase)
          version_ids = (versions_data.dig("_embedded", "elements") || [])
            .select { |e| sel_ver_names.include?(e["name"].downcase) }
            .map { |e| e["id"].to_s }
          raise Chomper::FatalError, "None of the specified versions found: #{sel_ver_names.join(", ")}" if version_ids.empty?
        end
      else
        puts "  Warning: could not fetch versions (HTTP #{ver_code}) — skipping version filter"
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
        version_names: sel_ver_names.empty? ? nil : sel_ver_names.join(", ")
      )
    end

    private

    # Detect the latest unacted @chomper trigger on a WP and turn it into an
    # Intent. Acknowledges receipt with 👀 and enforces the email allowlist
    # (a non-allowlisted trigger is marked acted and dropped, never emitted).
    def intent_from_comments(wp, comments)
      trigger = chomper_trigger_comment(wp["id"], comments)
      return nil unless trigger

      if @ctx.allowed_emails.any?
        email = resolve_user_email(trigger)
        unless @ctx.allowed_emails.include?(email.to_s)
          puts "  [@chomper] Ignoring trigger from #{trigger["user"]} (#{email || "unknown"}) — not in allowlist"
          mark_chomper_acted(wp["id"], trigger["created_at"])
          return nil
        end
      end

      react_eyes(trigger["id"])
      command, text = parse_command(trigger["text"].to_s)
      Intent.new(
        item_id:    wp["id"].to_s,
        subject:    wp["subject"],
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

    # Builds the URL-encoded OpenProject `filters=` query from a FilterSet
    # (status + type, plus an optional version clause).
    def encoded_filters(filters)
      version_filter = filters.version_ids.empty? ? "" :
        %Q(,{"version":{"operator":"=","values":#{JSON.generate(filters.version_ids)}}})
      filters_json = %Q([{"status":{"operator":"=","values":#{JSON.generate(filters.status_ids)}}},{"type":{"operator":"=","values":#{JSON.generate(filters.type_ids)}}}#{version_filter}])
      HTTP.encode_filters(filters_json)
    end

    def fetch_work_package_item(wp)
      wp_id = wp["id"]
      item_dir  = @ctx.state_dir / "items" / wp_id.to_s
      item_path = item_dir / "item.json"

      if item_path.exist?
        cached = JSON.parse(item_path.read)
        if cached["updated_at"] == wp["updatedAt"]
          return [true, cached["comments"] || []]
        end
      end

      acts_code, acts = HTTP.get_json("#{@ctx.op_url}/api/v3/work_packages/#{wp_id}/activities", token: @ctx.token)
      acts = { "_embedded" => { "elements" => [] } } unless acts_code == 200

      rxns_code, rxns = HTTP.get_json("#{@ctx.op_url}/api/v3/work_packages/#{wp_id}/activities_emoji_reactions", token: @ctx.token)
      rxns = { "_embedded" => { "elements" => [] } } unless rxns_code == 200

      comments = build_comments(
        acts.dig("_embedded", "elements") || [],
        rxns.dig("_embedded", "elements") || []
      )

      full = build_full_item(wp, comments)
      if item_path.exist?
        prev = JSON.parse(item_path.read) rescue {}
        full["last_acted_comment_at"] = prev["last_acted_comment_at"] if prev.key?("last_acted_comment_at")
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
        "id"          => wp["id"].to_s,
        "subject"     => wp["subject"],
        "url"         => "#{@ctx.op_url}/work_packages/#{wp["id"]}",
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
      @ctx.state_dir / "agent_filters.json"
    end

    def save_agent_filters(filters)
      tmp = Tempfile.new("agent_filters", @ctx.state_dir)
      tmp.write(JSON.generate(
        "project_id"    => filters.project_id,
        "project_name"  => filters.project_name,
        "type_ids"      => filters.type_ids,
        "status_ids"    => filters.status_ids,
        "version_ids"   => filters.version_ids,
        "type_names"    => filters.type_names,
        "status_names"  => filters.status_names,
        "version_names" => filters.version_names
      ))
      tmp.close
      File.rename(tmp.path, agent_filters_path.to_s)
    rescue
      tmp&.unlink
      raise
    end

    def resolve_user_email(comment)
      href = comment["user_href"].to_s
      return nil if href.empty?
      user_id = href.split("/").last
      _, user = HTTP.get_json("#{@ctx.op_url}/api/v3/users/#{user_id}", token: @ctx.token)
      user&.dig("email")&.downcase
    rescue => e
      puts "  Warning: could not resolve email for #{comment["user"]}: #{e.message}"
      nil
    end

    def react_eyes(activity_id)
      return unless activity_id.to_s.length > 0
      HTTP.patch_json(
        "#{@ctx.op_url}/api/v3/activities/#{activity_id}/emoji_reactions",
        { "reaction" => "eyes" },
        token: @ctx.token
      )
    rescue => e
      puts "  Warning: could not post 👀 reaction: #{e.message}"
    end

    def own_user_href
      @own_user_href ||= begin
        _, me = HTTP.get_json("#{@ctx.op_url}/api/v3/users/me", token: @ctx.token)
        me&.dig("_links", "self", "href")
      end
    end

    def chomper_trigger_comment(wp_id, comments)
      item_path = @ctx.state_dir / "items" / wp_id.to_s / "item.json"
      last_acted = item_path.exist? ? (JSON.parse(item_path.read)["last_acted_comment_at"] rescue nil) : nil
      comments
        .reject { |c| c["user_href"] == own_user_href }
        .select { |c| chomper_mentioned?(c["text"]) }
        .select { |c| last_acted.nil? || c["created_at"] > last_acted }
        .max_by { |c| c["created_at"] }
    end

    # A comment triggers chomper only when it carries a CKEditor mention of
    # chomper's own user — i.e. a <mention> element whose data-id is our user id.
    # Matching the literal "@chomper" text would misfire on quotes, plain-text
    # references, or mentions of similarly-named users.
    def chomper_mentioned?(text)
      id = own_user_href.to_s.split("/").last.to_s
      return false if id.empty?
      text.to_s.match?(%r{<mention\b[^>]*\bdata-id="#{Regexp.escape(id)}"})
    end

    def mark_chomper_acted(wp_id, created_at)
      item_path = @ctx.state_dir / "items" / wp_id.to_s / "item.json"
      return unless item_path.exist?
      data = JSON.parse(item_path.read)
      data["last_acted_comment_at"] = created_at
      item_path.write(JSON.generate(data))
    end

  end
end
