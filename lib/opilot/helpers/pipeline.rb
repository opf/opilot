require "json"

module OPilot
  module Helpers
    # The LLM call and the plan -> implement -> commit -> PR steps built on it.

    private

    # Fail with Harness#ensure_available!'s "start the container" message before a
    # command that will call the LLM does any work — interactive prompts, WP
    # fetches — rather than mid-run with a connection error.
    # `respond_to?` because every runner's tests inject a fake harness.
    def ensure_harness!
      @harness.ensure_available! if @harness.respond_to?(:ensure_available!)
    end

    # The one way to call the model: the role decides tools and model.
    # A stateless role refuses a session, so its independence is structural.
    def llm(role, prompt, session_file: nil, outfile: nil)
      r = Harness.role(role)
      raise ArgumentError, "role #{r.name} is stateless" if r.stateless && session_file
      if prompt.is_a?(Prompts::Prompt) && prompt.role != r.name
        raise ArgumentError, "a #{prompt.role} prompt sent as #{r.name}"
      end
      opts = { role: r.name, tools: r.tools(@ctx), model: r.model, session_file: session_file }
      outfile ? @harness.capture(prompt, outfile: outfile, **opts) : @harness.run(prompt, **opts)
    end

    # One-time, best-effort report of what the instance's MCP server actually
    # offers. Call once per process — OpenProject::Agent#setup, GitHub::Agent#setup, and once at
    # the start of each `dev` verb that grants the tool — never inside
    # guarded_tick/#tick.
    #
    # It WARNS; it never raises. That is the opposite of #ensure_harness! and
    # OpenProject::Pull#ensure_bot_identity!, which raise on purpose because a run without a
    # model or an identity cannot work — this one has a working fallback (the
    # mirrors), so a 404, an unreachable gateway, or a malformed answer just
    # leaves the OpenProject tools absent for the run.
    def report_mcp_status
      return unless @ctx.op_mcp?
      return unless Helpers.first_mcp_report?
      unless @ctx.mcp_gw_url
        log_script "OpenProject MCP: OPILOT_OP_MCP is set but OPILOT_MCP_GW_URL is not — is this running through ./opilot?"
        return
      end
      log_script "OpenProject MCP: #{Clients::OpMcp.new(@ctx.mcp_gw_url, @ctx.gw_token).summary}"
    rescue Clients::OpMcp::Unavailable
      # The common case now that OPILOT_OP_MCP defaults on: most instances have
      # no Enterprise MCP server enabled. Quiet by design: pi's connection
      # fails the same way and the tools are simply absent.
      log_script "OpenProject MCP: not available on this instance — the OpenProject tools will be absent."
    rescue StandardError => e
      log_script "OpenProject MCP: startup check failed (#{e.message}) — the OpenProject tools may be absent."
    end

    # True once per process — `./opilot agent` sets up every loop.
    def self.first_mcp_report?
      return false if @op_mcp_reported
      @op_mcp_reported = true
    end

    # Fetch a WP's related work packages (relations + parent/children) via the
    # injected @pull, write the index to related.json, and return its container
    # path — or nil when there are none, so the prompt omits the RELATED section.
    # Each related WP is also cached to its own item.json (by @pull) so the LLM can
    # read the full detail on demand via the item_path in the index. Shared by the
    # op-agent (OpenProject::Agent) and the terminal fix/plan flow (Runners::Fix).
    def related_ref(st)
      related = @pull.related_work_packages(st.item_id)
      return nil if related.empty?
      indexed = related.map do |r|
        r.merge("item_path" => container_path(Helpers.item_dir(@ctx, r["id"]) / "item.json"))
      end
      st.related_file.write(JSON.generate(indexed))
      container_path(st.related_file)
    end

    # Shape Repo objects for a prompt's repo listing — name, container path (where
    # the LLM reads/edits the files), and the one-line description.
    def repos_for_prompt(repos)
      repos.map { |r| { name: r.name, path: r.worktree_container, description: r.description } }
    end

    # Read the `REPOS:` line the LLM put at the top of a fresh plan, validate the
    # names against the registry, record the chosen repos, and strip the line from
    # the saved plan. Falls back to the default repo when the line is absent or
    # names nothing valid (so single-repo plans need no REPOS line).
    def record_chosen_repos(st)
      text    = st.plan_file.read
      m       = text.match(/^[ \t]*REPOS:[ \t]*(.+?)[ \t]*$/i)
      entries = m ? m[1].split(",").map(&:strip).reject(&:empty?) : []
      # Each entry is "<name>" or "<name>@<base>"; split on the first @ so a base
      # like "release/17.6" survives intact.
      names = []
      bases = {}
      entries.each do |entry|
        name, base = entry.split("@", 2).map(&:strip)
        next if name.to_s.empty?
        names << name
        bases[name] = base if base && !base.empty?
      end
      set_target_repos(st, names, bases)
      st.plan_file.write(text.sub(/^[ \t]*REPOS:.*\R?/i, "")) if m
    end

    # Check out the fix branch in every target repo, implement the plan once
    # across all their worktrees, and commit per repo. Returns the repos that
    # ended up with commits — [] when the plan turned out to be a no-op.
    #
    # One implementation pass covers every repo: the planning session is resumed,
    # so it carries its exploration in and the write tools are simply added. The
    # whole step is skipped when every fix branch already holds commits (an
    # earlier `dev commit`, or a re-run), so publishing then costs no LLM call.
    #
    # Reporting the result is deliberately left to the caller — a work-package
    # comment and a console line are not the same message.
    def implement_plan(st)
      st.repos.each { |r| checkout_branch(st, r) }

      unless st.repos.all? { |r| branch_has_commits?(st, r) }
        log_script "Implementing #{wp_label(st.item_id)} in #{st.repos.map(&:name).join(", ")}"
        llm(:implementer,
            Prompts::Implementer.implement(repos: repos_for_prompt(st.repos), plan: container_path(st.plan_file),
                              resumed: session_resumable?(st)),
            session_file: st.session_file)
        st.repos.each { |r| commit(st, r) }
      end

      st.repos.select { |r| branch_has_commits?(st, r) }
    end

    # Commit the worktree changes for one repo. Returns true when a commit was
    # made, false when this repo had no changes (so the caller can skip its PR).
    def commit(st, repo)
      Helpers.adopt_github_author!(@publish.author_token)
      wt = worktree(repo)
      return false unless stage_all(wt)
      commit_and_log(wt, pr_title(st.item_id, st.subject), repo.name)
      record_progress(st.item_id, st.branch, "committed:#{repo.name}")
      true
    end

    # Ask a cheap model for a one-line commit subject from the diff (stateless —
    # no session to resume), then sanitise it to a single bare line. Returns ""
    # on any failure so the caller can fall back to a generic subject. Shared by
    # gh-agent's follow-up commits and the terminal `pr` refresh.
    def generate_commit_subject(diff)
      prompt = Prompts::Scribe.commit_subject(diff: diff.patch.to_s[0, 6000])
      reply = llm(:scribe, prompt)
      strip_ansi(reply.to_s).lines.map(&:strip).find { |l| !l.empty? }.to_s
        .gsub(/\A["'`]+|["'`]+\z/, "")   # strip wrapping quotes/backticks
        .sub(/\A\[[^\]]*\]\s*/, "")       # drop any "[label]" the LLM prepended anyway
        .gsub(/\s+/, " ")
        .slice(0, 72).to_s.strip
    rescue => e
      log_script "Commit-subject generation failed: #{e.message}"
      ""
    end

    # Stateless — a fresh, cheap-model call rather than a resumed session, since
    # the item/plan/diff are all passed as file paths or plain text the model can
    # read itself, with nothing depending on the implement session's history.
    def generate_pr_description(st, repo)
      pr_desc_file = st.pr_desc_file(repo)
      return if Helpers.file_has_content?(pr_desc_file)
      wt               = worktree(repo)
      template_file    = repo.worktree_host / ".github" / "pull_request_template.md"
      template_section = template_file.exist? ? "Fill in this PR template exactly: #{container_path_for(repo, template_file)}" : ""
      diff_stat = wt.diff("HEAD~1", "HEAD").stats[:files]
        .map { |f, s| "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
        .join("\n")
      prompt = Prompts::Scribe.pr_description(
        item: container_path(st.item_file), plan: container_path(st.plan_file),
        diff_stat: diff_stat, template_section: template_section
      )
      pr_text = llm(:scribe, prompt)
      pr_body = pr_text[/^#.*/m] || pr_text
      pr_desc_file.write(strip_ansi(pr_body))
    end
  end
end
