require "json"
require_relative "clients"

module Chomper
  class BacklogRunner
    include Helpers

    TRIAGE_BATCH    = 20
    COMPLEXITY_ORDER  = { "trivial" => 0, "simple" => 1, "moderate" => 2, "complex" => 3 }.freeze
    COMPLEXITY_COLORS = { "trivial" => :green, "simple" => :cyan, "moderate" => :yellow, "complex" => :red }.freeze

    def initialize(ctx, pull: Pull.new(ctx), claude: Claude.new(ctx), publish: Publish.new(ctx))
      @ctx     = ctx
      @pull    = pull
      @claude  = claude
      @publish = publish
      @api     = Clients::OpenProject.new(ctx.op_url, ctx.token)
    end

    def run
      filters = @pull.load_or_prompt_backlog_filters
      queue = build_queue(filters, triage_mode: :interactive)
      return unless queue

      walk_queue(*queue)
    end

    # Work the queue from the cached snapshot without re-fetching — the third
    # backlog phase (`triage` → `show` → `process`). The per-item approval loop
    # is identical to a full run. Fails when there is no snapshot: this command
    # never fetches, so `backlog triage` must have run first.
    def process
      filters = @pull.saved_backlog_filters
      raise Chomper::FatalError, "no saved backlog filters — run `./chomper backlog triage` first" unless filters

      queue = offline_queue(filters)
      raise Chomper::FatalError, "no cached queue for these filters — run `./chomper backlog triage` first" unless queue

      walk_queue(*queue)
    end

    # Preview the queue exactly as `run` would walk it — clusters, order,
    # complexity, prior outcomes — without processing anything. Renders from
    # the on-disk caches when possible; only fetches when there is no snapshot.
    def show
      filters = @pull.saved_backlog_filters || @pull.load_or_prompt_backlog_filters
      clusters, complexity_map, module_key, total =
        offline_queue(filters) || build_queue(filters, triage_mode: :preview)
      return unless clusters

      index = 0; shipped = 0; dropped = 0
      clusters.each do |mod_name, cluster_items|
        print_cluster_header(mod_name, cluster_items) if module_key

        cluster_items.each do |item_data|
          index += 1
          complexity = complexity_map[item_data["id"].to_s] || "?"
          line = "  #{Rainbow("[#{index}/#{total}]").dimgray} ##{item_data["id"]} — #{item_data["subject"]}  #{complexity_label(complexity)}"
          if (prior = prior_outcome(item_data))
            prior == "shipped" ? shipped += 1 : dropped += 1
            line += "  ↩ #{prior}"
          end
          url = item_data["url"].to_s
          line += Rainbow("  #{url}").dimgray unless url.empty?
          puts line
        end
      end

      puts ""
      log_script "#{total - shipped - dropped} to process, #{shipped} shipped, #{dropped} dropped."
    end

    # Pull + triage only: refresh the WP cache and the complexity map, then stop.
    # A later `backlog` / `backlog show` reuses the saved triage.
    def triage
      filters = @pull.load_or_prompt_backlog_filters
      items, module_key = fetch_items(filters)
      return unless items

      map = load_or_run_triage(items, filters, module_key: module_key)
      counts = items.group_by { |i| map[i["id"].to_s] || "?" }
      summary = (COMPLEXITY_ORDER.keys + ["?"]).filter_map do |c|
        counts[c] && "#{counts[c].length} #{c}"
      end.join(", ")
      log_script "Triage complete: #{summary}."
    end

    private

    # The interactive per-item approval loop shared by `run` and `process`.
    def walk_queue(clusters, complexity_map, module_key, total)
      index = 0
      clusters.each do |mod_name, cluster_items|
        break if Chomper.stopping?
        print_cluster_header(mod_name, cluster_items) if module_key

        cluster_items.each do |item_data|
          break if Chomper.stopping?
          index += 1
          complexity = complexity_map[item_data["id"].to_s] || "?"
          puts ""
          puts "  #{Rainbow("[#{index}/#{total}]").dimgray} ##{item_data["id"]} — #{item_data["subject"]}  #{complexity_label(complexity)}"

          if (prior = prior_outcome(item_data))
            puts "  ↩ #{prior} — skipping"
            next
          end

          puts "  #{item_data["url"]}"
          desc = item_data["description"].to_s.strip.lines.first(2).map(&:strip).reject(&:empty?).join(" ")
          puts "  #{desc[0, 120]}" unless desc.empty?
          process_item(item_data)
        end
      end

      puts ""
      log_script "Backlog run complete."
    end

    # Module field → fetch. Returns [items, module_key]; items is nil when
    # nothing matched.
    def fetch_items(filters)
      module_key = cached_module_field(filters)
      if module_key == :miss
        log_script "Resolving Module field…"
        module_key = resolve_module_field(filters)
      elsif module_key
        log_script "Module field: #{module_key} (cached)."
      end

      log_script "Fetching work packages…"
      items = @pull.fetch_all_items(filters, module_field_key: module_key)

      if items.empty?
        puts "  No work packages found."
        return [nil, module_key]
      end

      log_script "Found #{items.length} work package(s)."
      [items, module_key]
    end

    # The module field key is schema-derived and stable for a given filter set,
    # so it rides along in the triage cache. Returns the cached key (possibly
    # nil = "looked up before, project has no Module field") or :miss when the
    # cache is absent, stale, or predates module_field.
    def cached_module_field(filters)
      cached = load_triage_cache(filters)
      return :miss unless cached&.key?("module_field")
      cached["module_field"]
    end

    # Shared prep for run/show: fetch → triage → clusters.
    # Returns [clusters, complexity_map, module_key, total], or nil when no WPs match.
    def build_queue(filters, triage_mode:)
      items, module_key = fetch_items(filters)
      return nil unless items

      complexity_map = load_or_run_triage(items, filters, module_key: module_key, mode: triage_mode)
      [group_and_sort(items, complexity_map), complexity_map, module_key, items.length]
    end

    # Rebuild the queue from the last fetch without touching the API: the triage
    # cache records which item ids were fetched, and each item's data (incl.
    # module) lives in items/<id>/item.json. Returns nil when the cache is
    # absent, stale, or predates item_ids — callers fall back to a live fetch.
    def offline_queue(filters)
      cached = load_triage_cache(filters)
      return nil unless cached && cached["item_ids"].is_a?(Array)

      items = cached["item_ids"].filter_map do |id|
        path = @ctx.state_dir / "items" / id.to_s / "item.json"
        JSON.parse(path.read) rescue nil
      end
      return nil if items.empty?

      missing = cached["item_ids"].length - items.length
      log_script "Using cached queue: #{items.length} work package(s) from #{cached["created_at"]}" \
                 "#{" (#{missing} missing on disk)" if missing > 0}."
      map = cached["complexity"] || {}
      [group_and_sort(items, map), map, cached["module_field"], items.length]
    end

    def complexity_label(complexity)
      label = "[#{complexity}]"
      color = COMPLEXITY_COLORS[complexity]
      color ? Rainbow(label).color(color) : Rainbow(label).dimgray
    end

    def print_cluster_header(mod_name, cluster_items)
      puts ""
      label = "  ── #{mod_name} (#{cluster_items.length} item#{cluster_items.length == 1 ? "" : "s"}) "
      puts Rainbow(label).bold + Rainbow("─" * [2, 62 - mod_name.length].max).dimgray
    end

    # Find the field named "Module" (case-insensitive) in the WP schemas of the
    # filtered types. Custom fields are activated per project AND type, so each
    # /work_packages/schemas/<project>-<type> pair is checked until one has the
    # field. Returns the customFieldN key or nil (no module grouping).
    def resolve_module_field(filters)
      Array(filters.type_ids).each do |type_id|
        code, schema = @api.work_package_schema(filters.project_id, type_id)
        unless code == 200 && schema
          log_script "Warning: could not fetch WP schema for type #{type_id} (HTTP #{code})."
          next
        end
        key = schema.keys.find { |k| schema[k].is_a?(Hash) && schema[k]["name"].to_s.match?(/\Amodule\z/i) }
        if key
          log_script "Module field: #{key} (\"#{schema[key]["name"]}\")"
          return key
        end
      end
      log_script "Module field not found in WP schemas — processing without module grouping."
      nil
    rescue => e
      log_script "Warning: module field lookup failed (#{e.message}) — no module grouping."
      nil
    end

    # Ask Claude to classify all items by complexity. Returns { id => complexity }.
    # Falls back to an empty map on failure (all items treated as "moderate" by the sorter).
    def classify(items)
      complexity_map  = {}
      total_batches   = (items.length.to_f / TRIAGE_BATCH).ceil

      items.each_slice(TRIAGE_BATCH).with_index(1) do |batch, n|
        log_script "Triage batch #{n}/#{total_batches}…"
        paths = batch.map { |i| container_path(@ctx.state_dir / "items" / i["id"].to_s / "item.json") }.join("\n")
        text  = @claude.run(Prompts.triage(paths: paths), tools: Claude::TOOLS_READ)
        json_str = text[/---BEGIN JSON---\n(.*?)---END JSON---/m, 1]
        next unless json_str
        parsed = JSON.parse(json_str) rescue nil
        next unless parsed.is_a?(Array)
        parsed.each { |t| complexity_map[t["id"].to_s] = t["complexity"].to_s.downcase }
      end

      complexity_map
    rescue => e
      log_script "Warning: triage failed (#{e.message}) — processing without complexity ordering."
      {}
    end

    # Load cached triage if it exists and matches the current filters; otherwise run fresh.
    # Incrementally triages any items not in the cache (new items added since last run).
    #
    # mode :interactive — normal run: prompt to reuse a cache, triage what's missing.
    # mode :preview     — `backlog show`: reuse a valid cache silently (uncached items
    #                     show as "?"); with no cache, offer to triage, default no.
    def load_or_run_triage(items, filters, module_key: nil, mode: :interactive)
      cached = load_triage_cache(filters)

      if mode == :preview
        if cached
          log_script "Using cached triage from #{cached["created_at"]}."
          return cached["complexity"]
        end
        puts "  No triage cache — `./chomper backlog triage` builds it (show alone doesn't start the Claude container)."
        print "  Run triage now? [y/N]: "
        return {} unless $stdin.gets.to_s.chomp.downcase.start_with?("y")
      end

      map = {}
      if cached
        log_script "Cached triage from #{cached["created_at"]}."
        print "  Reuse cached complexity? [Y/n]: "
        if $stdin.gets.chomp.downcase != "n"
          map = cached["complexity"]
          fresh = items.reject { |i| map.key?(i["id"].to_s) }
          unless fresh.empty?
            log_script "Triaging #{fresh.length} new item(s)…"
            map = map.merge(classify(fresh))
          end
        else
          log_script "Triaging…"
          map = classify(items)
        end
      else
        log_script "Triaging…"
        map = classify(items)
      end
      save_triage_cache(map, filters, module_key, items.map { |i| i["id"].to_s })
      map
    end

    def load_triage_cache(filters)
      return nil unless triage_cache_path.exist?
      data = JSON.parse(triage_cache_path.read) rescue nil
      return nil unless data.is_a?(Hash) && data["complexity"].is_a?(Hash)
      return nil unless data["filter_fingerprint"] == filter_fingerprint(filters)
      data
    end

    def save_triage_cache(complexity_map, filters, module_key, item_ids)
      tmp = Tempfile.new("backlog_triage", @ctx.state_dir)
      tmp.write(JSON.generate(
        "created_at"         => Time.now.utc.iso8601,
        "filter_fingerprint" => filter_fingerprint(filters),
        "module_field"       => module_key,
        "item_ids"           => item_ids,
        "complexity"         => complexity_map
      ))
      tmp.close
      File.rename(tmp.path, triage_cache_path.to_s)
    rescue => e
      log_script "Warning: could not save triage cache (#{e.message})"
      tmp&.unlink
    end

    def triage_cache_path
      @ctx.state_dir / "backlog_triage.json"
    end

    def filter_fingerprint(filters)
      [
        filters.project_id,
        Array(filters.type_ids).sort.join(","),
        Array(filters.status_ids).sort.join(","),
        Array(filters.version_ids).sort.join(",")
      ].join("|")
    end

    def prior_outcome(item_data)
      dir = @ctx.state_dir / "items" / item_data["id"].to_s
      return "shipped"       if (dir / "pr_url.txt").exist?
      f = dir / "backlog_done.txt"
      return f.read.strip    if f.exist?
      nil
    end

    def mark_backlog_done(st, outcome)
      (st.item_dir / "backlog_done.txt").write(outcome)
    rescue => e
      log_script "Warning: could not persist backlog outcome (#{e.message})"
    end

    # Group items by module (alphabetically; multi-module WPs carry their first
    # module only), sort within each group by complexity.
    def group_and_sort(items, complexity_map)
      groups = items.group_by { |i| i["module"].to_s.then { |m| m.empty? ? "(unassigned)" : m } }
      groups.sort_by { |name, _| name }.each_with_object({}) do |(name, group), h|
        h[name] = group.sort_by { |i| COMPLEXITY_ORDER.fetch(complexity_map[i["id"].to_s] || "moderate", 2) }
      end
    end

    def process_item(item_data)
      id      = item_data["id"].to_s
      subject = item_data["subject"].to_s
      type    = item_data["type"].to_s
      st      = state_for(id, subject, type)

      loop do
        just_generated = false
        unless st.plan_file.exist? && st.plan_file.size > 0
          log_script "Planning ##{id} — #{subject}"
          checkout_branch(st)
          # Pass session_file so a prior chat's context carries into the (re-)plan.
          @claude.capture(
            Prompts.plan(repo: @ctx.worktree_container, item: container_path(st.item_file),
                         item_id: id, title: subject),
            tools: Claude::TOOLS_READ, outfile: st.plan_file, session_file: st.session_file
          )
          just_generated = true
        end

        # Preamble-tolerant NEEDS_INFO check: Claude sometimes writes a sentence
        # before the sentinel when it can't proceed.
        if st.plan_file.read.match?(/\bNEEDS_INFO\b/)
          questions = st.plan_file.read.sub(/.*\bNEEDS_INFO\b\s*\n?/m, "").strip
          safe_rm(st.plan_file)
          puts ""
          puts "  ⚠ More information needed before planning:"
          puts questions.lines.map { |l| "    #{l}" }.join unless questions.empty?
          puts ""
          case prompt_needs_info
          when :chat
            run_chat(st)
            next   # retry planning — chat session carries context forward
          when :skip
            log_script "##{id} skipped (needs info) — will reappear next run."
            break
          when :drop
            mark_backlog_done(st, "dropped")
            log_script "##{id} dropped."
            break
          end
          break
        end

        # Re-show plan from file only when it was not just streamed (resumed from
        # a prior run, or returning from a chat loop on a subsequent iteration).
        unless just_generated
          puts ""
          puts st.plan_file.read.lines.map { |l| "    #{l}" }.join
        end
        puts ""
        case prompt_approval
        when :approve then ship(st); break
        when :chat    then run_chat(st)
        when :skip    then log_script "##{id} skipped — will reappear next run."; break
        when :drop    then safe_rm(st.plan_file); mark_backlog_done(st, "dropped"); log_script "##{id} dropped."; break
        end
      end
    end

    def prompt_needs_info
      loop do
        print "  [c]hat to provide context / [s]kip / [d]rop: "
        response = $stdin.gets&.chomp&.downcase || ""
        case response
        when "c", "chat"  then return :chat
        when "s", "skip"  then return :skip
        when "d", "drop"  then return :drop
        else puts "  Please enter c, s, or d."
        end
      end
    end

    def prompt_approval
      loop do
        print "  [y]es implement / [s]kip / [d]rop / [c]hat: "
        response = $stdin.gets&.chomp&.downcase || ""
        case response
        when "", "y", "yes"  then return :approve
        when "s", "skip"     then return :skip
        when "d", "drop"     then return :drop
        when "c", "chat"     then return :chat
        else puts "  Please enter y, s, d, or c."
        end
      end
    end

    def run_chat(st)
      plan_text = st.plan_file.exist? ? st.plan_file.read : "(no plan yet)"
      puts ""
      loop do
        print "\n  You (empty line to exit): "
        msg = $stdin.gets&.chomp
        break if msg.nil? || msg.empty?
        prompt = Prompts.backlog_chat(
          item_id: st.item_id, subject: st.subject,
          item: container_path(st.item_file), plan: plan_text, message: msg
        )
        @claude.run(prompt, tools: Claude::TOOLS_READ, session_file: st.session_file)
        puts ""
        plan_text = st.plan_file.exist? ? st.plan_file.read : plan_text
      end
    end

    def ship(st)
      if st.pr_url_file.exist? && st.pr_url_file.size > 0
        puts "  Already shipped: #{st.pr_url_file.read.strip}"
        return
      end

      checkout_branch(st)
      unless branch_has_commits?(st)
        log_script "Implementing ##{st.item_id}"
        @claude.run(
          Prompts.implement(repo: @ctx.worktree_container, plan: container_path(st.plan_file)),
          tools: Claude::TOOLS_IMPL
        )
        commit(st)
      end

      unless branch_has_commits?(st)
        log_script "##{st.item_id} — no changes produced."
        puts "  ⚠ No changes produced — plan may be a no-op or already applied."
        return
      end

      generate_pr_description(st)
      url = @publish.open_pr(st.item_id, st.subject, st.branch)
      if url
        record_progress(st.item_id, st.branch, "shipped")
        st.pr_url_file.write(url)
        puts "  ✓ Draft PR: #{url}"
        post_note(st.item_id, "draft PR opened from backlog run: #{url}")
      else
        puts "  ⚠ Implemented on #{st.branch} but couldn't open the PR — is GITHUB_TOKEN set?"
      end
    end

    def post_note(item_id, text)
      code, _body = @api.post_activity(item_id, comment: text)
      log_script "Note posted to WP ##{item_id}" if code == 201
    end

    def checkout_branch(st)
      if local_branch_exists?(worktree, st.branch)
        worktree.checkout(st.branch)
      else
        worktree.checkout(st.branch, new_branch: true, start_point: "origin/dev")
      end
    end

    def branch_has_commits?(st)
      worktree.log.between("origin/dev", st.branch).execute.any?
    end

    def commit(st)
      worktree.add(all: true)
      diff = worktree.diff("HEAD")
      return if diff.entries.empty?
      diff.stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      worktree.commit("fix: #{st.subject} (WP ##{st.item_id})")
      c = worktree.log(1).first
      log_script "Committed: #{c.sha[0, 7]} #{c.message}"
      record_progress(st.item_id, st.branch, "committed")
    end

    def generate_pr_description(st)
      return if st.pr_desc_file.exist? && st.pr_desc_file.size > 0
      template_file    = @ctx.repo_path / ".github" / "pull_request_template.md"
      template_section = template_file.exist? ? "Fill in this PR template exactly: #{template_file}" : ""
      diff_stat = worktree.diff("HEAD~1", "HEAD").stats[:files]
        .map { |f, s| "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
        .join("\n")
      prompt = Prompts.pr_description(
        item: container_path(st.item_file), plan: container_path(st.plan_file),
        diff_stat: diff_stat, template_section: template_section
      )
      pr_text = @claude.run(prompt, tools: Claude::TOOLS_READ)
      pr_body = pr_text[/^#.*/m] || pr_text
      st.pr_desc_file.write(strip_ansi(pr_body))
    end

    def state_for(id, subject, type)
      dir = @ctx.state_dir / "items" / id.to_s
      dir.mkpath
      Agent::ItemState.new(
        item_id:      id.to_s,
        subject:      subject.to_s,
        branch:       branch_slug(id, type, subject),
        item_dir:     dir,
        plan_file:    dir / "plan.md",
        item_file:    dir / "item.json",
        review_file:  dir / "review.txt",
        pr_desc_file: dir / "pr.md",
        pr_url_file:  dir / "pr_url.txt",
        session_file: dir / "session_id"
      )
    end

    def container_path(host_path)
      host_path.to_s.sub(@ctx.state_dir.to_s, @ctx.state_container)
    end
  end
end
