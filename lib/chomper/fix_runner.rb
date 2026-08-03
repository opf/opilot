require "json"

module Chomper
  # The terminal `ship`, `build`, and `plan` commands: plan/approve/(optionally
  # build and ship) one or more work packages named by id, outside any filter
  # set. Each WP is fetched live; `ship` (alias `fix`) publishes an approved
  # plan as a draft PR, `build` stops after committing the fix locally, and
  # `plan` stops once the plan is approved.
  class FixRunner
    include Helpers

    # `ship` publishes as the CONTRIBUTOR bot, like every other mode: the fix
    # branch goes to the bot's fork and a cross-repo draft PR is opened against
    # upstream, so a maintainer merges it or nothing lands.
    def initialize(ctx, pull: Pull.new(ctx), claude: Claude.new(ctx), publish: nil)
      @ctx     = ctx
      @pull    = pull
      @claude  = claude
      @publish = publish || Publish.new(ctx)
    end

    # Plan/approve/implement/ship one or more work packages by id. Each WP is
    # fetched live; an already-shipped WP is reported and skipped. With several
    # ids a failure on one (bad id, Claude error) is logged and the rest still
    # run; with a single id the failure is fatal since there is nothing else to do.
    def ship_ids(*wp_ids)
      require_publish_token!
      process_ids(wp_ids, mode: :ship)
    end

    # Like `ship`, but stops after committing the fix locally — nothing is
    # pushed and no PR is opened; `wp ship <id>` later publishes the built branch.
    def build_ids(*wp_ids)
      process_ids(wp_ids, mode: :build)
    end

    # Like `ship`, but stops once each plan is approved instead of building.
    def plan_ids(*wp_ids)
      process_ids(wp_ids, mode: :plan)
    end

    private

    # `wp ship` ends in a push and a PR, and it only gets there after a full plan and
    # implement pass — so a missing token has to fail before that Claude work, not
    # after it (`Publish#open_pr` reported it at the very end). `pr` has always
    # checked its token up front; this brings its sibling into line.
    #
    # Deliberately not in the constructor: `build` and `plan` publish nothing and
    # must keep working with no GitHub token at all.
    def require_publish_token!
      return if @publish.author_token
      raise Chomper::FatalError,
            "No GitHub token — set #{@publish.token_env_var} in .env to ship. " \
            "(`wp build` and `wp plan` need no token: they stop before publishing.)"
    end

    def process_ids(wp_ids, mode:)
      ensure_claude!
      total = wp_ids.length
      wp_ids.each_with_index do |wp_id, idx|
        counter = total > 1 ? "#{Rainbow("[#{idx + 1}/#{total}]").dimgray} " : ""

        log_script "Fetching work package #{wp_label(wp_id)}…"
        item = @pull.fetch_single_item(wp_id)
        unless item
          msg = "could not fetch work package #{wp_label(wp_id)} — check the id and OPENPROJECT_TOKEN"
          raise Chomper::FatalError, msg if total == 1
          log_script "#{wp_label(wp_id)} — #{msg}"
          next
        end

        puts ""
        puts "  #{counter}#{wp_label(item["id"])} — #{item["subject"]}"
        puts "  #{item["url"]}"

        if already_shipped?(item)
          puts "  Already shipped: #{(Helpers.item_dir(@ctx, item["id"]) / "pr_url.txt").read.strip}"
          next
        end

        begin
          process_item(item, mode: mode)
        rescue Claude::Error => e
          raise Chomper::FatalError, "Claude run failed: #{e.message}" if total == 1
          log_script "#{wp_label(wp_id)} — Claude run failed: #{e.message}"
        end
      end
    end

    def already_shipped?(item_data)
      (Helpers.item_dir(@ctx, item_data["id"]) / "pr_url.txt").exist?
    end

    def process_item(item_data, mode:)
      id      = item_data["id"].to_s
      subject = item_data["subject"].to_s
      type    = item_data["type"].to_s
      st      = state_for(id, subject, type)
      # One model for every session-bound phase of this WP (plan, chat, replan,
      # implement, PR description) — switching mid-session would drop the context.
      model   = Claude::MODEL_WORK

      replan_feedback = nil
      loop do
        just_generated = false
        # Sync before reading, for the same reason as Agent#produce_plan: the
        # clone is otherwise wherever the last run left it. Only when a plan is
        # actually about to be written — a `ship` of an already-approved plan has
        # nothing to re-read, and the [c]hat option below runs in this same
        # process, on the tree this sync established.
        if replan_feedback || !Helpers.file_has_content?(st.plan_file)
          sync_bases_for_reading(@ctx.repos.all)
        end
        # On Claude::Error the failure was already shown in red; both branches
        # fall through so the loop can recover instead of crashing the run.
        if replan_feedback
          log_script "Re-planning #{wp_label(id)} — #{subject}"
          begin
            # Read-only across all repos; Claude re-declares the target repo(s) in
            # the revised plan. Branch checkout waits until #ship.
            @claude.capture(
              Prompts.replan(repos_summary: @ctx.repos.summary, repos: repos_for_prompt(@ctx.repos.all),
                             item: container_path(st.item_file),
                             plan: container_path(st.plan_file), feedback: replan_feedback,
                             item_id: id, title: subject, resumed: session_resumable?(st),
                             related: related_ref(st)),
              tools: Claude::TOOLS_READ, model: model, outfile: st.plan_file, session_file: st.session_file
            )
            record_chosen_repos(st)
          rescue Claude::Error
            # capture didn't write the outfile, so the previous plan survives;
            # the user just saw the error and can retry from the prompt below.
          end
          replan_feedback = nil
          just_generated = true
        elsif !Helpers.file_has_content?(st.plan_file)
          log_script "Planning #{wp_label(id)} — #{subject}"
          begin
            # Pass session_file so a prior chat's context carries into the (re-)plan.
            @claude.capture(
              Prompts.plan(repos_summary: @ctx.repos.summary, repos: repos_for_prompt(@ctx.repos.all),
                           item: container_path(st.item_file),
                           item_id: id, title: subject, related: related_ref(st)),
              tools: Claude::TOOLS_READ, model: model, outfile: st.plan_file, session_file: st.session_file
            )
            record_chosen_repos(st) if plan_present?(st)
          rescue Claude::Error
            # capture didn't write the outfile; the no-plan check below recovers.
          end
          just_generated = true
        end

        # A run that dies mid-way (denied tool, max turns, timeout) can leave
        # preamble text ("Let me look at…") but no actual plan — don't offer to
        # implement that. The session survives, so a retry resumes with context.
        unless plan_present?(st)
          safe_rm(st.plan_file)
          puts ""
          puts "  ⚠ Plan generation failed — no plan came back."
          case prompt_plan_failed(id)
          when :retry then next   # plan.md is gone, so the loop regenerates it
          when :chat  then run_chat(st, model); next
          when :skip  then log_script "#{wp_label(id)} skipped."; break
          when :drop  then log_script "#{wp_label(id)} dropped."; break
          end
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
          case prompt_needs_info(id)
          when :chat
            run_chat(st, model)
            next   # retry planning — chat session carries context forward
          when :skip
            log_script "#{wp_label(id)} skipped (needs info)."
            break
          when :drop
            log_script "#{wp_label(id)} dropped."
            break
          end
          break
        end

        # Re-show plan from file only when it was not just streamed (resumed from
        # a prior run, or returning from a chat loop on a subsequent iteration).
        unless just_generated
          puts ""
          puts render_markdown(st.plan_file.read)
        end
        puts ""
        case prompt_approval(id, mode: mode)
        when :approve
          case mode
          when :plan
            # Leave the approved plan.md in place (no outcome marker) so a later
            # `build`/`ship` picks it up.
            log_script "#{wp_label(id)} — plan approved; build or ship it later with " \
                       "`wp build #{id}` / `wp ship #{id}`."
          when :build then build(st, model)
          when :ship  then ship(st, model)
          end
          break
        when :chat    then run_chat(st, model)
        when :replan  then replan_feedback = prompt_replan_feedback
        when :skip    then log_script "#{wp_label(id)} skipped."; break
        when :drop    then safe_rm(st.plan_file); log_script "#{wp_label(id)} dropped."; break
        end
      end
    end

    # A usable generation is either a structured plan (any markdown heading,
    # possibly after a preamble sentence) or a NEEDS_INFO block (handled
    # separately). Anything else — missing file, bare preamble from a run that
    # died ("Let me look at…") — is a failed generation.
    def plan_present?(st)
      st.plan_file.exist? && st.plan_file.read.match?(/^#+ |\bNEEDS_INFO\b/)
    end

    def prompt_plan_failed(id)
      ping_terminal("chomper: plan for #{wp_label(id)} failed — input needed")
      loop do
        print "  [r]etry / [c]hat / [s]kip / [d]rop: "
        response = $stdin.gets&.chomp&.downcase || ""
        case response
        when "r", "retry" then return :retry
        when "c", "chat"  then return :chat
        when "s", "skip"  then return :skip
        when "d", "drop"  then return :drop
        else puts "  Please enter r, c, s, or d."
        end
      end
    end

    def prompt_needs_info(id)
      ping_terminal("chomper: #{wp_label(id)} needs more info before planning")
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

    def prompt_approval(id, mode: :ship)
      ping_terminal("chomper: plan for #{wp_label(id)} ready for review")
      yes = { plan: "[y]es accept plan", build: "[y]es build", ship: "[y]es ship" }.fetch(mode)
      loop do
        print "  #{yes} / [s]kip / [d]rop / [c]hat / [r]e-plan: "
        response = $stdin.gets&.chomp&.downcase || ""
        case response
        when "", "y", "yes"  then return :approve
        when "s", "skip"     then return :skip
        when "d", "drop"     then return :drop
        when "c", "chat"     then return :chat
        when "r", "replan"   then return :replan
        else puts "  Please enter y, s, d, c, or r."
        end
      end
    end

    # Feedback for a re-plan. Empty input means "fold in what we discussed in
    # chat" — the Claude session already carries that conversation.
    def prompt_replan_feedback
      print "  Feedback (empty = revise per the chat above): "
      msg = $stdin.gets&.chomp.to_s
      msg.empty? ? "Revise the plan to incorporate the changes requested in the preceding conversation." : msg
    end

    def run_chat(st, model = Claude::MODEL_WORK)
      # The session already holds the plan (just generated/revised), so pass its
      # path as a fallback rather than re-embedding the full text on every turn.
      plan_ref = st.plan_file.exist? ? container_path(st.plan_file) : "(no plan yet)"
      puts ""
      loop do
        print "\n  You (empty line to exit): "
        msg = $stdin.gets&.chomp
        break if msg.nil? || msg.empty?
        prompt = Prompts.plan_chat(
          item_id: st.item_id, subject: st.subject,
          item: container_path(st.item_file), plan: plan_ref, message: msg
        )
        @claude.run(prompt, tools: Claude::TOOLS_READ, model: model, session_file: st.session_file)
        # Ring after the reply, not before the first message: the user just
        # chose [c]hat and is present; it's Claude's answers they wander off on.
        ping_terminal("chomper: chat reply for #{wp_label(st.item_id)} ready")
        puts ""
      end
    end

    # Implement the approved plan once across every target worktree (the resumed
    # planning session carries its exploration in; --allowedTools just adds the
    # write tools) and commit per repo. Skipped when every fix branch already
    # has commits — a prior `build` — so `ship` then only publishes. Returns the
    # repos that actually changed ([] when the plan turned out to be a no-op).
    def implement(st, model = Claude::MODEL_WORK)
      st.repos.each { |r| checkout_branch(st, r) }

      unless st.repos.all? { |r| branch_has_commits?(st, r) }
        log_script "Implementing #{wp_label(st.item_id)} in #{st.repos.map(&:name).join(", ")}"
        @claude.run(
          Prompts.implement(repos: repos_for_prompt(st.repos), plan: container_path(st.plan_file),
                            resumed: session_resumable?(st)),
          tools: Claude::TOOLS_IMPL, model: model, session_file: st.session_file
        )
        st.repos.each { |r| commit(st, r) }
      end

      changed = st.repos.select { |r| branch_has_commits?(st, r) }
      if changed.empty?
        log_script "#{wp_label(st.item_id)} — no changes produced."
        puts "  ⚠ No changes produced — plan may be a no-op or already applied."
      end
      changed
    end

    # `build`: implement and commit, then stop — nothing is pushed and no PR is
    # opened. The committed branch sits in the local clone for review; a later
    # `wp ship <id>` finds it via branch_has_commits? and goes straight to publish.
    def build(st, model = Claude::MODEL_WORK)
      return if report_already_shipped(st)
      implement(st, model).each do |repo|
        record_progress(st.item_id, st.branch, "built:#{repo.name}")
        puts "  ✓ Built #{st.branch} (#{repo.name}) — review it in the clone, then ship it with `./chomper wp ship #{st.item_id}`"
      end
    end

    def ship(st, model = Claude::MODEL_WORK)
      return if report_already_shipped(st)
      implement(st, model).each do |repo|
        generate_pr_description(st, repo, model: model)
        url = @publish.open_pr(st.item_id, st.subject, st.branch, repo)
        if url
          record_progress(st.item_id, st.branch, "shipped:#{repo.name}")
          puts "  ✓ Draft PR (#{repo.name}): #{url}"
        else
          puts "  ⚠ Implemented on #{st.branch} (#{repo.name}) but couldn't open the PR — is a GitHub token set?"
        end
      end
    end

    # True (with the URLs reported) when every target repo already has a PR —
    # there is nothing left to build or ship for this WP.
    def report_already_shipped(st)
      return false unless st.repos.all? { |r| Helpers.file_has_content?(st.pr_url_file(r)) }
      st.repos.each { |r| puts "  Already shipped (#{r.name}): #{st.pr_url_file(r).read.strip}" }
      true
    end
  end
end
