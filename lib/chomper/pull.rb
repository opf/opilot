require "json"

module Chomper
  FilterSet = Struct.new(:project_id, :type_ids, :status_ids, :version_ids, keyword_init: true)

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
          item = fetch_work_package_item(wp)
          new_items << item
          printf_item(item["id"], item["subject"])
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
        item = fetch_work_package_item(wp)
        new_items << item
        printf_item(item["id"], item["subject"])
      end
      @backlog.merge_fetched_items(new_items)
    end

    private

    def prompt_search_filters
      puts ""
      puts "=== Search filters ==="
      puts ""

      print "  Project: "
      project_id = $stdin.gets.chomp
      raise Chomper::FatalError, "Project identifier is required." if project_id.empty?

      _code, types_data = HTTP.get_json!("#{@ctx.op_url}/api/v3/projects/#{project_id}/types", token: @ctx.token)
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

      version_ids = []
      ver_code, versions_data = HTTP.get_json("#{@ctx.op_url}/api/v3/projects/#{project_id}/versions", token: @ctx.token)
      if ver_code == 200
        ver_names = versions_data.dig("_embedded", "elements")&.map { |e| e["name"] }&.join(", ") || ""
        puts "  Versions available: #{ver_names}"
        print "  Version(s), comma-separated [17.5.0]: "
        sel_versions = $stdin.gets.chomp
        sel_versions = "17.5.0" if sel_versions.empty?
        sel_ver_names = sel_versions.split(",").map(&:strip).map(&:downcase)
        version_ids = (versions_data.dig("_embedded", "elements") || [])
          .select { |e| sel_ver_names.include?(e["name"].downcase) }
          .map { |e| e["id"].to_s }
        raise Chomper::FatalError, "None of the specified versions found: #{sel_ver_names.join(", ")}" if version_ids.empty?
      else
        puts "  Warning: could not fetch versions (HTTP #{ver_code}) — skipping version filter"
      end

      puts ""
      FilterSet.new(project_id: project_id, type_ids: type_ids, status_ids: status_ids, version_ids: version_ids)
    end

    def fetch_work_package_item(wp)
      wp_id = wp["id"]

      acts_code, acts = HTTP.get_json("#{@ctx.op_url}/api/v3/work_packages/#{wp_id}/activities", token: @ctx.token)
      acts = { "_embedded" => { "elements" => [] } } unless acts_code == 200

      rxns_code, rxns = HTTP.get_json("#{@ctx.op_url}/api/v3/work_packages/#{wp_id}/activities_emoji_reactions", token: @ctx.token)
      rxns = { "_embedded" => { "elements" => [] } } unless rxns_code == 200

      comments = build_comments(
        acts.dig("_embedded", "elements") || [],
        rxns.dig("_embedded", "elements") || []
      )

      full = build_full_item(wp, comments)
      item_dir = @ctx.state_dir / "items" / full["id"]
      item_dir.mkpath
      (item_dir / "item.json").write(JSON.generate(full))

      build_backlog_entry(wp)
    end

    def build_comments(activities, reactions)
      rxn_index = reactions
        .group_by { |r| r.dig("_links", "reactable", "href")&.split("/")&.last }
        .transform_values { |rs| rs.map { |r| [r["reaction"], r["reactionsCount"]] }.to_h }

      activities
        .select { |a| a.dig("comment", "raw").to_s.strip != "" }
        .map do |a|
          {
            "user"       => a.dig("_embedded", "user", "name"),
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

    def printf_item(wp_id, subject)
      puts "  ##{wp_id} #{subject}"
    end
  end
end
