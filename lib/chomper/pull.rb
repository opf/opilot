require "json"

module Chomper
  FilterSet = Struct.new(:project_id, :type_ids, :status_ids, :version_ids,
                         :type_names, :status_names, :version_names, keyword_init: true)

  class Pull
    def initialize(ctx, backlog)
      @ctx     = ctx
      @backlog = backlog
    end

    def run_pull_stage
      filters = prompt_search_filters

      version_filter = filters.version_ids.empty? ? "" :
        %Q(,{"version":{"operator":"=","values":#{JSON.generate(filters.version_ids)}}})
      filters_json = %Q([{"status":{"operator":"=","values":#{JSON.generate(filters.status_ids)}}},{"type":{"operator":"=","values":#{JSON.generate(filters.type_ids)}}}#{version_filter}])
      encoded = HTTP.encode_filters(filters_json)

      new_items = []
      page = 1; page_size = 50; total_written = 0; total = 0

      loop do
        url = "#{@ctx.op_url}/api/v3/projects/#{filters.project_id}/work_packages" \
              "?pageSize=#{page_size}&offset=#{page}&filters=#{encoded}"
        code, resp = HTTP.get_json(url, token: @ctx.token)
        if code != 200
          raise Chomper::FatalError, "API returned HTTP #{code} — URL: #{url}"
        end

        if resp.nil?
          raise Chomper::FatalError, "API returned unparseable response (HTTP #{code}) — URL: #{url}"
        end

        count = resp["count"].to_i
        total = resp["total"].to_i
        break if count == 0

        puts "  Fetching #{total} work packages..." if page == 1

        (resp.dig("_embedded", "elements") || []).each do |wp|
          item, cached, comments = fetch_work_package_item(wp)
          new_items << item
          printf_item(item["id"], item["subject"], cached: cached)
          print_comments(comments)
        end

        total_written += count
        puts "  ── Page #{page} — #{total_written} / #{total}"
        break if total_written >= total
        page += 1
      end

      if @backlog.exist?
        @backlog.merge_new_items(new_items)
      else
        @backlog.replace_with_new_items(new_items.map { |i| i.merge("state" => Backlog::STATE_UNTRIAGED) })
      end
    end

    def run_fetch_ids_stage(ids)
      new_items = []
      ids.each do |id|
        code, wp = HTTP.get_json("#{@ctx.op_url}/api/v3/work_packages/#{id}", token: @ctx.token)
        if code != 200
          puts "  Warning: WP ##{id} returned HTTP #{code} — skipping"
          next
        end
        item, cached, comments = fetch_work_package_item(wp)
        new_items << item
        printf_item(item["id"], item["subject"], cached: cached)
        print_comments(comments)
      end
      @backlog.merge_fetched_items(new_items)
    end

    def load_or_prompt_agent_filters
      if agent_filters_path.exist?
        data = JSON.parse(agent_filters_path.read)
        if data["type_names"] && data["status_names"]
          saved = FilterSet.new(
            project_id:    data["project_id"],
            type_ids:      data["type_ids"],
            status_ids:    data["status_ids"],
            version_ids:   data["version_ids"],
            type_names:    data["type_names"],
            status_names:  data["status_names"],
            version_names: data["version_names"]
          )
          version_label = saved.version_names ? "  versions=[#{saved.version_names}]" : ""
          puts "  Saved filters: project=[#{saved.project_id}]  types=[#{saved.type_names}]  statuses=[#{saved.status_names}]#{version_label}"
          print "  Reuse saved filters? [Y/n]: "
          return saved unless $stdin.gets.chomp.downcase == "n"
        end
      end
      filters = prompt_search_filters
      save_agent_filters(filters)
      filters
    end

    def run_agent_poll(filters)
      version_filter = filters.version_ids.empty? ? "" :
        %Q(,{"version":{"operator":"=","values":#{JSON.generate(filters.version_ids)}}})
      filters_json = %Q([{"status":{"operator":"=","values":#{JSON.generate(filters.status_ids)}}},{"type":{"operator":"=","values":#{JSON.generate(filters.type_ids)}}}#{version_filter}])
      encoded = HTTP.encode_filters(filters_json)
      sort    = HTTP.encode_filters('[["updatedAt","desc"]]')

      new_items = []
      triggered_ids = []
      refinement_ids = []
      fix_approved_ids = []
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

        puts "  Fetching #{total} work packages..." if page == 1

        page_all_cached = true
        (resp.dig("_embedded", "elements") || []).each do |wp|
          item, cached, comments = fetch_work_package_item(wp)
          new_items << item
          printf_item(item["id"], item["subject"], cached: cached)
          print_comments(comments)
          page_all_cached = false unless cached

          unless cached
            trigger = chomper_trigger_comment(item["id"], comments)
            if trigger
              react_eyes(trigger["id"])
              mark_chomper_acted(item["id"], trigger["created_at"])
              if trigger["text"].to_s.match?(/\A@chomper\s+proceed\b/i)
                plan_file = @ctx.state_dir / "items" / item["id"].to_s / "plan.md"
                fix_approved_ids << item["id"] if plan_file.exist? && plan_file.size > 0
              elsif (@ctx.state_dir / "items" / item["id"].to_s / "gist.txt").exist?
                feedback = trigger["text"].to_s.sub(/@chomper\s*/i, "").strip
                (@ctx.state_dir / "items" / item["id"].to_s / "feedback.txt").write(feedback)
                refinement_ids << item["id"]
              else
                triggered_ids << item["id"]
              end
            end
          end
        end

        total_written += count
        puts "  ── Page #{page} — #{total_written} / #{total}"

        if page_all_cached
          puts "  ── All cached — stopping early"
          break
        end

        break if total_written >= total
        page += 1
      end

      @backlog.merge_new_items(new_items) unless new_items.empty?
      triggered_ids.each { |id| @backlog.set_state(id, Backlog::STATE_REQUESTED) }
      refinement_ids.each do |id|
        (@ctx.state_dir / "items" / id / "gist.txt").delete rescue nil
        @backlog.set_state(id, Backlog::STATE_REFINEMENT_REQUESTED)
      end
      fix_approved_ids.each { |id| @backlog.set_state(id, Backlog::STATE_FIX_APPROVED) }
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
        type_ids:      type_ids,
        status_ids:    status_ids,
        version_ids:   version_ids,
        type_names:    sel_names.join(", "),
        status_names:  sel_status_names.join(", "),
        version_names: sel_ver_names.empty? ? nil : sel_ver_names.join(", ")
      )
    end

    private

    def fetch_work_package_item(wp)
      wp_id = wp["id"]
      item_dir  = @ctx.state_dir / "items" / wp_id.to_s
      item_path = item_dir / "item.json"

      if item_path.exist?
        cached = JSON.parse(item_path.read)
        if cached["updated_at"] == wp["updatedAt"]
          return [build_backlog_entry(wp), true, cached["comments"] || []]
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

      [build_backlog_entry(wp), false, comments]
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

    def build_backlog_entry(wp)
      {
        "id"             => wp["id"].to_s,
        "subject"        => wp["subject"],
        "url"            => "#{@ctx.op_url}/work_packages/#{wp["id"]}",
        "state"          => Backlog::STATE_PENDING,
        "locality_group" => nil,
        "complexity"     => nil,
        "files_touched"  => [],
        "ai_category"    => nil
      }
    end

    def agent_filters_path
      @ctx.state_dir / "agent_filters.json"
    end

    def save_agent_filters(filters)
      tmp = Tempfile.new("agent_filters", @ctx.state_dir)
      tmp.write(JSON.generate(
        "project_id"    => filters.project_id,
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

    def chomper_trigger_comment(wp_id, comments)
      item_path = @ctx.state_dir / "items" / wp_id.to_s / "item.json"
      last_acted = item_path.exist? ? (JSON.parse(item_path.read)["last_acted_comment_at"] rescue nil) : nil
      comments
        .select { |c| c["text"].to_s.downcase.include?("@chomper") }
        .select { |c| last_acted.nil? || c["created_at"] > last_acted }
        .max_by { |c| c["created_at"] }
    end

    def mark_chomper_acted(wp_id, created_at)
      item_path = @ctx.state_dir / "items" / wp_id.to_s / "item.json"
      return unless item_path.exist?
      data = JSON.parse(item_path.read)
      data["last_acted_comment_at"] = created_at
      item_path.write(JSON.generate(data))
    end

    def printf_item(wp_id, subject, cached: false)
      suffix = cached ? " (cached)" : ""
      puts "  ##{wp_id} #{subject}#{suffix}"
    end

    def print_comments(comments)
      comments.each do |c|
        text = c["text"].to_s.gsub(/\s+/, " ").strip
        text = "#{text[0, 120]}..." if text.length > 120
        rxns = (c["reactions"] || {}).map { |k, v| "#{k}: #{v}" }.join(", ")
        rxns_str = rxns.empty? ? "" : "  [#{rxns}]"
        puts "      #{c["user"]}: #{text}#{rxns_str}"
      end
    end
  end
end
