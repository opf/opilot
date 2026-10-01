require "json"
require "time"

module OPilot
  module OpenProject
    # The work package health check, shared by `@opilot health` (OpenProject::Agent) and
    # `./opilot dev health` (Runners::Health). Two layers:
    #
    # - Facts: rules on exact, language-independent data (status flags from
    #   /statuses, relation labels, timestamps, PR flags, commit ids). Written to
    #   health.json, and the prompt tells the model not to dispute them — so a
    #   heuristic never belongs here.
    # - Judgement: one read-only LLM call, answered in Prompts::Auditor::HEALTH_CONTRACT.
    #
    # The reply is composed here, not by the model, so it states what was checked.
    class HealthCheck
      include Helpers

      Lookup   = Clients::OpenProject::Lookup
      Resource = Clients::OpenProject::Resource

      STALE_DAYS = 60
      MAX_COMMITS = 10
      MAX_DESCENDANTS = 200
      MAX_TREE_FINDINGS = 5   # per rule; the rest are counted in the text
      SEVERITY_ORDER = Prompts::Auditor::HEALTH_SEVERITIES

      # Labels from this work package's own side (OpenProject::Pull#relation_pairs): the other
      # one must finish first.
      PREREQUISITES = %w[blocked follows requires].freeze

      def initialize(ctx, pull:, harness:, api: nil)
        @ctx     = ctx
        @pull    = pull
        @harness = harness
        @api     = api || Clients::OpenProject::Client.new(ctx.op_url, ctx.token)
      end

      # The report text, or nil when the work package cannot be fetched.
      # `internal:` is the visibility the report is posted with.
      def run(item_id, focus: "", internal: true)
        item = @pull.fetch_single_item(item_id)
        return nil unless item

        st = state_for(item["id"], item["subject"], item["type"])
        related_path = related_ref(st)
        related = related_path ? (Helpers.safe_json_read(st.related_file) || []) : []

        tree = descendants(item["id"])
        tree_file = st.item_dir / "descendants.json"
        tree_file.write(JSON.pretty_generate(tree["nodes"])) if tree["nodes"]&.any?
        tree_ref = if tree["nodes"].nil? then nil
                   elsif tree["nodes"].empty? then :none
                   else container_path(tree_file)
                   end

        facts = facts_for(item, related, status_map, linked_prs(item["id"]), commits(item["id"]), tree: tree)
        facts["inputs"]["opilot_user_href"] = opilot_user_href
        facts["inputs"]["commits_as_of"] = @commits_as_of
        facts["inputs"]["opilot_prs"] = st.repos.filter_map { |r| st.pr_url_file(r).read.strip if st.pr_url_file(r).exist? }
        facts_file = st.item_dir / "health.json"
        facts_file.write(JSON.pretty_generate(facts))

        prompt = Prompts::Auditor.health(item_id: st.item_id, subject: st.subject,
                                item: container_path(st.item_file), facts: container_path(facts_file),
                                related: related_path, descendants: tree_ref, focus: focus, internal: internal,
                                op_mcp: @ctx.op_mcp?)
        answer = ask(prompt)
        return failed_note unless answer

        report(facts, answer, item, internal: internal)
      end

      # ── facts ────────────────────────────────────────────────────────────────

      # name => { "closed", "default" }, or nil when /statuses cannot be read.
      # Status names are unique on an instance, so the lookup by name is exact.
      def status_map
        Lookup.new(@api).statuses.to_h do |s|
          [s["name"].to_s, { "closed" => s["isClosed"] == true, "default" => s["isDefault"] == true }]
        end
      rescue StandardError => e
        log_script "Health: #{e.message}"
        nil
      end

      # Every descendant at any depth, from one paginated `ancestor` query:
      # { "nodes" => [...] | nil (not read), "truncated", "code" }. Each node is
      # { id, parent, depth, subject, type, status, updated_at }, ids as displayed.
      def descendants(item_id)
        res = @api.work_package(item_id)
        return { "nodes" => nil, "truncated" => false, "code" => res.code } unless res.code == 200 && res.body
        root = res.body["id"].to_s
        filter = Clients::OpenProject::Query.filter("ancestor", "=", root)
        code, raw, total = Lookup.new(@api).all_work_packages(filter, max: MAX_DESCENDANTS)
        return { "nodes" => nil, "truncated" => false, "code" => code } unless raw
        { "nodes" => tree_nodes(raw, root, Resource.display_id(res.body)),
          "truncated" => total > MAX_DESCENDANTS, "code" => 200 }
      end

      private def tree_nodes(raw, root_numeric, root_display)
        shown = raw.to_h { |w| [w["id"].to_s, Resource.display_id(w)] }.merge(root_numeric => root_display)
        parent_of = raw.to_h { |w| [w["id"].to_s, Resource.link_id(w, "parent").to_s] }
        depth = lambda do |id, seen = 0|
          up = parent_of[id]
          up.nil? || up == root_numeric || seen > MAX_DESCENDANTS ? 1 : 1 + depth.(up, seen + 1)
        end
        raw.map do |w|
          id = w["id"].to_s
          { "id" => shown[id], "parent" => shown[parent_of[id]] || parent_of[id], "depth" => depth.(id),
            "subject" => w["subject"], "type" => Resource.link_title(w, "type"),
            "status" => Resource.link_title(w, "status"), "updated_at" => w["updatedAt"] }
        end
      end

      # So the model can tell opilot's own comments from the thread.
      private def opilot_user_href
        id = @pull.own_user_id if @pull.respond_to?(:own_user_id)
        id.to_s.empty? ? nil : "/api/v3/users/#{id}"
      rescue StandardError
        nil
      end

      # [prs, code]. The GitHub integration answers 403/404 when it is off.
      def linked_prs(item_id)
        res = @api.work_package_github_pull_requests(item_id)
        return [nil, res.code] unless res.code == 200
        prs = Resource.elements(res.body).map do |pr|
          { "url" => pr["htmlUrl"], "repository" => pr["repository"], "number" => pr["number"],
            "title" => pr["title"], "state" => pr["state"], "merged" => pr["merged"] == true,
            "merged_at" => pr["mergedAt"], "draft" => pr["draft"] == true }
        end
        [prs, res.code]
      end

      # PR numbers share the `#N` form with work package ids ("Merge pull request
      # #25183", a squash's "(#25183)"), so they are removed before matching.
      PR_NUMBER = /Merge pull request #\d+|\(#\d+\)/

      # How a commit names a work package: the id in a branch name
      # (`bug/op-123-slug`, `bug/59942-slug`), a work package URL, `[#N]`, `OP#N`.
      # Never a prefix of a longer id.
      def self.commit_pattern(item_id)
        id = Regexp.escape(item_id.to_s)
        return /(?<![A-Za-z0-9])#{id}(?!\d)/i unless item_id.to_s.match?(/\A\d+\z/)
        %r{(?:\bOP|(?<![\w&]))##{id}(?!\d)|/(?:wp|work_packages)/#{id}(?!\d)|/#{id}-}i
      end

      # git's grep is a prefilter only (BRE, case-sensitive), so letters become
      # both-case classes; the exact match is .commit_pattern.
      def self.commit_prefilter(item_id)
        item_id.to_s.gsub(/[A-Za-z]/) { |c| "[#{c.downcase}#{c.upcase}]" }
      end

      # { repo_name => [{ "sha", "subject" }] } for commits on each registry base
      # that name the work package, or { repo_name => nil } when a clone cannot
      # be read. Reads only origin/<base>, so it fetches the base alone, and only
      # when no fetch in the last COMMITS_MAX_AGE did; the repos run in parallel.
      # The fetch time per repo goes to @commits_as_of.
      COMMITS_MAX_AGE = 10 * 60

      def commits(item_id)
        exact = OpenProject::HealthCheck.commit_pattern(item_id)
        prefilter = OpenProject::HealthCheck.commit_prefilter(item_id)
        @commits_as_of = {}
        # Opened here: #worktree memoizes and must not race.
        trees = @ctx.repos.all.to_h { |repo| [repo, (worktree(repo) rescue $!)] }
        trees.map do |repo, wt|
          Thread.new do
            raise wt if wt.is_a?(Exception)
            @commits_as_of[repo.name] = fetch_base_if_stale(wt, repo, repo.base, max_age: COMMITS_MAX_AGE)&.utc&.iso8601
            found = wt.log(500).object("origin/#{repo.base}").grep(prefilter).execute
            hits = found.select { |c| c.message.to_s.gsub(PR_NUMBER, "").match?(exact) }.first(MAX_COMMITS)
            [repo.name, hits.map { |c| { "sha" => c.sha[0, 12], "subject" => c.message.to_s.lines.first.to_s.strip } }]
          rescue StandardError => e
            log_script "Health: could not read commits in #{repo.name} (#{e.message})"
            [repo.name, nil]
          end
        end.to_h(&:value)
      end

      # Pure: every input already fetched, so the rules test without HTTP or git.
      # `tree` is #descendants' answer; nil (not asked) keeps the direct-child
      # rules on related.json, which is what a failed subtree read falls back to.
      def facts_for(item, related, statuses, prs_and_code, commits, tree: nil, now: Time.now)
        prs, pr_code = prs_and_code
        findings    = []
        not_checked = []
        nodes = tree&.dig("nodes")
        if tree && nodes.nil?
          not_checked << "The descendants could not be read (HTTP #{tree["code"]}); only direct children were checked."
        elsif tree&.dig("truncated")
          not_checked << "The subtree has more than #{MAX_DESCENDANTS} work packages; only the first #{MAX_DESCENDANTS} were checked."
        end
        # Children are part of the tree, so the tree rules replace the child rules.
        related = related.reject { |r| r["relation"] == "child" } if nodes

        own = statuses && statuses[item["status"].to_s]
        if own.nil?
          not_checked << (statuses ? "The status \"#{item["status"]}\" is not in the status list, so no status rule ran." :
                                     "The status list could not be read, so no status rule ran.")
        else
          findings.concat(relation_findings(item, related, statuses, own))
          findings.concat(tree_findings(nodes, statuses, own, now)) if nodes&.any?
          findings.concat(pr_findings(item, prs, own)) if prs
          findings.concat(commit_findings(item, commits, own))
          stale = item["history"].nil? ? nil : stale_finding(item, own, now)
          findings << stale if stale
        end
        findings.concat(design_findings(item))
        if item["history"].nil?
          not_checked << "The activities could not be read: comments and field changes are missing, " \
                         "and the staleness and design rules did not run."
        end

        Array(item["pictures_skipped"]).each do |p|
          not_checked << "Attachment \"#{p["name"]}\" (#{p["where"] || "attached"}): #{p["reason"]}."
        end
        not_checked << "Linked pull requests could not be read (HTTP #{pr_code})." unless prs
        commits.each { |repo, list| not_checked << "Commits in #{repo} could not be read." if list.nil? }

        { "findings" => findings, "not_checked" => not_checked,
          "inputs" => { "status" => item["status"], "status_closed" => own&.dig("closed"),
                        "status_default" => own&.dig("default"), "pull_requests" => prs,
                        "commits" => commits, "descendant_count" => nodes&.length } }
      end

      # Rules across the whole subtree. A node whose status is not in the list
      # is neither open nor closed, so no rule uses it.
      private def tree_findings(nodes, statuses, own, now)
        closed = ->(n) { statuses.dig(n["status"].to_s, "closed") }
        open_nodes = nodes.select { |n| closed.(n) == false }
        ids = ->(list) { list.first(MAX_TREE_FINDINGS).map { |n| wp_label(n["id"]) }.join(", ") + (list.length > MAX_TREE_FINDINGS ? ", …" : "") }
        out = []

        if own["closed"] && open_nodes.any?
          out << fact("high", "relations", "This work package is closed, but #{open_nodes.length} descendant(s) are still open.", ids.(open_nodes))
        elsif !own["closed"] && nodes.all? { |n| closed.(n) == true }
          out << fact("low", "status", "All #{nodes.length} descendants are closed, but this work package is still open.", ids.(nodes))
        end

        # A closed node inside the tree with an open node under it.
        by_id = nodes.to_h { |n| [n["id"], n] }
        ancestors = lambda do |n|
          chain = []
          while (up = by_id[n["parent"]]) && chain.length <= nodes.length
            chain << up
            n = up
          end
          chain
        end
        closed_over_open = open_nodes.flat_map { |n| ancestors.(n).select { |a| closed.(a) == true } }.uniq
        closed_over_open.first(MAX_TREE_FINDINGS).each do |a|
          out << fact("medium", "relations", "Descendant #{wp_label(a["id"])} is closed, but a work package under it is still open.", wp_label(a["id"]))
        end

        stale = open_nodes.select { |n| (t = parse_time(n["updated_at"])) && (now - t) > STALE_DAYS * 86_400 }
        if stale.any?
          out << fact("low", "status", "#{stale.length} open descendant(s) did not change for #{STALE_DAYS} days.", ids.(stale))
        end
        out
      end

      private def relation_findings(item, related, statuses, own)
        id = ->(r) { wp_label(r["id"]) }
        closed = ->(r) { statuses.dig(r["status"].to_s, "closed") }
        children = related.select { |r| r["relation"] == "child" }
        out = []

        if own["closed"]
          related.each do |r|
            next unless closed.(r) == false
            if PREREQUISITES.include?(r["relation"])
              out << fact("medium", "relations", "This work package is closed, but #{id.(r)} (#{r["relation"]}) is still open.", id.(r))
            elsif r["relation"] == "child"
              out << fact("high", "relations", "This work package is closed, but its child #{id.(r)} is still open.", id.(r))
            end
          end
        else
          if children.any? && children.all? { |r| closed.(r) == true }
            out << fact("low", "status", "All children are closed, but this work package is still open.",
                        children.map(&id).join(", "))
          end
          related.select { |r| r["relation"] == "duplicates" && closed.(r) == true }.each do |r|
            out << fact("medium", "relations", "This work package duplicates #{id.(r)}, which is closed, but it is still open.", id.(r))
          end
        end
        out
      end

      # Only the DEFAULT status (the one a new work package starts in) is a clear
      # contradiction: "Developed" or "In testing" is open and has merged PRs.
      private def pr_findings(_item, prs, own)
        out = []
        prs.each do |pr|
          if pr["merged"] && own["default"]
            out << fact("high", "prs", "A linked pull request is merged, but the status is still the initial one.", pr["url"])
          elsif pr["state"] == "open" && !pr["draft"] && own["closed"]
            out << fact("medium", "prs", "This work package is closed, but a linked pull request is still open.", pr["url"])
          end
        end
        out
      end

      private def commit_findings(_item, commits, own)
        return [] unless own["default"]
        hits = commits.flat_map { |repo, list| Array(list).map { |c| "#{repo}@#{c["sha"]}" } }
        return [] if hits.empty?
        [fact("low", "status", "Commits name this work package, but the status is still the initial one.", hits.first(3).join(", "))]
      end

      private def stale_finding(item, own, now)
        return nil if own["closed"]
        times = [item["created_at"], *Array(item["comments"]).map { |c| c["created_at"] },
                 *Array(item["history"]).map { |h| h["created_at"] }]
        last = times.filter_map { |t| parse_time(t) }.max
        return nil unless last && (now - last) > STALE_DAYS * 86_400
        fact("low", "status", "This work package is open, but nothing changed for #{((now - last) / 86_400).floor} days.",
             "last activity #{last.utc.iso8601}")
      end

      # A picture in the description arrives with that same edit, so only one in a
      # comment or attached on its own can be newer than the text.
      private def design_findings(item)
        edited = parse_time(item["description_changed_at"])
        return [] unless edited
        Array(item["pictures"]).filter_map do |p|
          next if p["where"] == "description"
          added = parse_time(p["created_at"])
          next unless added && added > edited
          fact("medium", "designs", "The picture \"#{p["name"]}\" was added after the last description edit.",
               "#{p["name"]}, #{added.utc.iso8601} (#{p["where"]})")
        end
      end

      private def fact(severity, area, text, evidence)
        { "severity" => severity, "area" => area, "text" => text, "evidence" => evidence.to_s }
      end

      private def parse_time(value)
        value.to_s.empty? ? nil : Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      # ── judgement ────────────────────────────────────────────────────────────

      RETRY_NOTE = "\n\nYour last answer had no complete BEGIN HEALTH … END HEALTH block. " \
                   "Answer again, and end with that block exactly as described."

      private def ask(prompt)
        answer = Helpers.parse_health(llm(:auditor, prompt))
        answer || Helpers.parse_health(llm(:auditor, prompt + RETRY_NOTE))
      end

      private def failed_note
        "The health check did not finish: the answer had no report that I could read. " \
          "Ask again with `@opilot health`."
      end

      # ── report ───────────────────────────────────────────────────────────────

      # The whole reply. A public reply drops a finding whose evidence cites an
      # internal comment: the evidence is printed verbatim.
      def report(facts, answer, item, internal: true)
        findings = facts["findings"] + answer["findings"]
        hidden = 0
        unless internal
          stamps = Array(item["comments"]).select { |c| c["internal"] }.filter_map { |c| c["created_at"].to_s[0, 16] }
          stamps.reject!(&:empty?)
          kept = findings.reject { |f| stamps.any? { |s| f["evidence"].include?(s) } }
          hidden = findings.length - kept.length
          findings = kept
        end
        findings = findings.sort_by.with_index { |f, i| [SEVERITY_ORDER.index(f["severity"]), i] }

        gaps = answer["gaps"].reject { |g| already_not_checked?(g, facts["not_checked"]) }
        not_checked = facts["not_checked"] + gaps.map { |g| g["why"].empty? ? "#{g["what"]}." : "#{g["what"]}: #{g["why"]}" }
        not_checked << "#{hidden} finding(s) cite an internal comment and are not shown in this public reply." if hidden.positive?

        lines = [summary_line(findings)]
        SEVERITY_ORDER.each do |sev|
          group = findings.select { |f| f["severity"] == sev }
          next if group.empty?
          lines << "" << "**#{sev.capitalize}**"
          group.each { |f| lines << "- #{f["text"]} (#{f["evidence"]})" }
        end
        unless not_checked.empty?
          lines << "" << "**Not checked**"
          not_checked.each { |n| lines << "- #{n}" }
        end
        lines.join("\n")
      end

      # The prompt forbids a GAP that repeats not_checked, and a real run wrote one
      # anyway. A gap is a repeat when a fact line holds every word of its subject.
      private def already_not_checked?(gap, lines)
        words = gap["what"].to_s.downcase.scan(/[[:alnum:]]{4,}/)
        return false if words.empty?
        lines.any? { |line| words.all? { |w| line.downcase.include?(w) } }
      end

      private def summary_line(findings)
        return "**Health check: no findings.**" if findings.empty?
        counts = SEVERITY_ORDER.filter_map do |sev|
          n = findings.count { |f| f["severity"] == sev }
          "#{n} #{sev}" if n.positive?
        end
        noun = findings.length == 1 ? "finding" : "findings"
        "**Health check: #{findings.length} #{noun}** (#{counts.join(", ")})"
      end
    end
  end
end
