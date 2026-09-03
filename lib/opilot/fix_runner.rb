require "json"

module OPilot
  # The terminal `dev build`, `dev commit`, and `dev plan` commands: plan,
  # approve, then optionally implement and publish one or more work packages
  # named by id, outside any filter set. Each WP is fetched live. The three
  # verbs are one pipeline named by where it stops: `plan` at the approved plan,
  # `commit` at the local commit, `build` (alias `fix`) at the draft PR — the
  # words `@opilot` also takes. Internally the publishing path is still `ship`.
  class FixRunner
    include Helpers

    # `ship` publishes as the CONTRIBUTOR bot, like every other mode: the fix
    # branch goes to the bot's fork and a cross-repo draft PR is opened against
    # upstream, so a maintainer merges it or nothing lands.
    def initialize(ctx, pull: Pull.new(ctx), harness: Harness.new(ctx), publish: nil)
      @ctx     = ctx
      @pull    = pull
      @harness  = harness
      @publish = publish || Publish.new(ctx)
    end

    # Plan/approve/implement/ship one or more work packages by id. Each WP is
    # fetched live; an already-shipped WP is reported and skipped. With several
    # ids a failure on one (bad id, LLM error) is logged and the rest still
    # run; with a single id the failure is fatal since there is nothing else to do.
    def ship_ids(*wp_ids)
      require_publish_token!
      process_ids(wp_ids, mode: :ship)
    end

    # Like `ship`, but stops after committing the fix locally — nothing is
    # pushed and no PR is opened; `dev build <id>` later publishes that branch.
    def commit_ids(*wp_ids)
      process_ids(wp_ids, mode: :commit)
    end

    # Like `ship`, but stops once each plan is approved instead of building.
    def plan_ids(*wp_ids)
      process_ids(wp_ids, mode: :plan)
    end

    private

    # `dev build` ends in a push and a PR, and it only gets there after a full plan and
    # implement pass — so a missing token has to fail before that LLM work, not
    # after it (`Publish#open_pr` reported it at the very end). `pr` has always
    # checked its token up front; this brings its sibling into line.
    #
    # Deliberately not in the constructor: `commit` and `plan` publish nothing
    # and must keep working with no GitHub token at all.
    def require_publish_token!
      return if @publish.author_token
      raise OPilot::FatalError,
            "No GitHub token — set #{@publish.token_env_var} in .env to ship. " \
            "(`dev commit` and `dev plan` need no token: they stop before publishing.)"
    end

    def process_ids(wp_ids, mode:)
      ensure_harness!
      report_mcp_status
      total = wp_ids.length
      wp_ids.each_with_index do |wp_id, idx|
        counter = total > 1 ? "#{Rainbow("[#{idx + 1}/#{total}]").dimgray} " : ""

        log_script "Fetching work package #{wp_label(wp_id)}…"
        item = @pull.fetch_single_item(wp_id)
        unless item
          msg = "could not fetch work package #{wp_label(wp_id)} — check the id and OPENPROJECT_TOKEN"
          raise OPilot::FatalError, msg if total == 1
          log_script "#{wp_label(wp_id)} — #{msg}"
          next
        end

        puts ""
        puts "  #{counter}#{wp_label(item["id"])} — #{item["subject"]}"
        puts "  #{item["url"]}"

        begin
          process_item(item, mode: mode)
        rescue Harness::Error => e
          raise OPilot::FatalError, "The LLM run failed: #{e.message}" if total == 1
          log_script "#{wp_label(wp_id)} — The LLM run failed: #{e.message}"
        end
      end
    end

    def process_item(item_data, mode:)
      id      = item_data["id"].to_s
      subject = item_data["subject"].to_s
      type    = item_data["type"].to_s
      st      = state_for(id, subject, type)
      # Before any LLM call and before the approval prompt: a work package whose
      # every target repo already has a PR has nothing left to plan or build.
      # One guard for all three verbs — `plan` stops here too, which the old
      # per-verb check inside #commit/#ship could not do.
      return if report_already_shipped(st)
      # One model for every session-bound phase of this WP (plan, chat, replan,
      # implement) — switching mid-session would drop the context. The PR
      # description is a separate, stateless call and picks its own model.
      model   = Harness::MODEL_HEAVY

      replan_feedback = nil
      # Set once the operator picks an option (or types their own direction) at
      # the options prompt below. Present means the approach is settled, so the
      # next plan call asks for a plan rather than for options.
      option_focus = nil
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
        # On Harness::Error the failure was already shown in red; both branches
        # fall through so the loop can recover instead of crashing the run.
        if replan_feedback
          log_script "Re-planning #{wp_label(id)} — #{subject}"
          begin
            # Read-only across all repos; the LLM re-declares the target repo(s) in
            # the revised plan. Branch checkout waits until #ship.
            @harness.capture(
              Prompts.replan(repos_summary: @ctx.repos.summary, repos: repos_for_prompt(@ctx.repos.all),
                             item: container_path(st.item_file),
                             plan: container_path(st.plan_file), feedback: replan_feedback,
                             item_id: id, title: subject, resumed: session_resumable?(st),
                             related: related_ref(st), op_mcp: @ctx.op_mcp?),
              tools: read_tools, model: model, outfile: st.plan_file, session_file: st.session_file
            )
            record_chosen_repos(st)
          rescue Harness::Error
            # capture didn't write the outfile, so the previous plan survives;
            # the user just saw the error and can retry from the prompt below.
          end
          replan_feedback = nil
          just_generated = true
        elsif !Helpers.file_has_content?(st.plan_file)
          log_script "Planning #{wp_label(id)} — #{subject}"
          begin
            # Pass session_file so a prior chat's context carries into the (re-)plan.
            @harness.capture(
              Prompts.plan(repos_summary: @ctx.repos.summary, repos: repos_for_prompt(@ctx.repos.all),
                           item: container_path(st.item_file),
                           item_id: id, title: subject, hint: option_focus.to_s,
                           related: related_ref(st), allow_options: option_focus.nil?, op_mcp: @ctx.op_mcp?),
              tools: read_tools, model: model, outfile: st.plan_file, session_file: st.session_file
            )
            record_chosen_repos(st) if plan_present?(st)
          rescue Harness::Error
            # capture didn't write the outfile; the no-plan check below recovers.
          end
          just_generated = true
        end

        # The writer always names the approach before a plan, the same
        # judgment the agent's `ship` gets. When it named more than one, ask
        # here rather than plan blind — the operator is at the console, so the
        # answer costs one keystroke.
        if Helpers.file_has_content?(st.plan_file) && Helpers.options_sentinel?(st.plan_file.read)
          options, remainder = Helpers.parse_leading_options(st.plan_file.read)

          if options.length == 1 && !remainder.strip.empty?
            # The common case: one named approach, with its plan already in
            # the same response. Strip the header and fall through to the
            # review/approval step below — the operator sees it like any
            # other plan and still has to say yes before anything is built.
            st.plan_file.write(remainder)
          else
            safe_rm(st.plan_file)                  # holds no usable plan
            if options.length < 2
              log_script "#{wp_label(id)} — unusable options came back; planning one approach instead."
              option_focus = ""                    # empty, not nil: asks for a plan
              next
            end
            case (answer = prompt_option_choice(id, options))
            when :skip then log_script "#{wp_label(id)} skipped."; break
            when :drop then log_script "#{wp_label(id)} dropped."; break
            else
              option_focus = answer
              next                                 # plan the chosen option
            end
          end
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

        # Preamble-tolerant NEEDS_INFO check: the LLM sometimes writes a sentence
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
                       "`dev commit #{id}` / `dev build #{id}`."
          when :commit then commit(st, model)
          when :ship   then ship(st, model)
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
      ping_terminal("opilot: plan for #{wp_label(id)} failed — input needed")
      prompt_choice("[r]etry / [c]hat / [s]kip / [d]rop",
                    { retry: %w[r retry], chat: %w[c chat], skip: %w[s skip], drop: %w[d drop] })
    end

    def prompt_needs_info(id)
      ping_terminal("opilot: #{wp_label(id)} needs more info before planning")
      prompt_choice("[c]hat to provide context / [s]kip / [d]rop",
                    { chat: %w[c chat], skip: %w[s skip], drop: %w[d drop] })
    end

    # Offer the implementation options at the console, the same list a work
    # package gets (Prompts::OPTIONS_CONTRACT). Returns the plan focus for the
    # chosen option, free text as its own direction (so the operator is never
    # forced to pick one of the three), :skip, or :drop.
    def prompt_option_choice(id, options)
      ping_terminal("opilot: #{wp_label(id)} has #{options.length} ways to fix it")
      puts ""
      puts "  #{Rainbow("This fix has more than one shape:").bold}"
      options.each do |o|
        tag = [o["repos"].to_a.join(", "), o["size"]].reject { |s| s.to_s.strip.empty? }.join(" · ")
        puts "    #{Rainbow("#{o["n"]})").bold} #{Rainbow(o["title"]).bold} — #{o["summary"]}"
        puts "       estimate: #{tag}" unless tag.empty?
      end
      puts ""
      numbers = options.map { |o| o["n"] }
      loop do
        print "  Build [#{numbers.join("/")}] / your own direction / [s]kip / [d]rop: "
        answer = $stdin.gets&.chomp.to_s.strip
        case answer
        when "s", "skip" then return :skip
        when "d", "drop" then return :drop
        when ""          then puts "  Enter a number, a direction, s, or d."
        else
          # A number selects (with any trailing words folded in); anything else is
          # direction of the operator's own, exactly as in a work-package comment.
          return Helpers.option_choice(options, answer) || answer
        end
      end
    end

    def prompt_approval(id, mode: :ship)
      ping_terminal("opilot: plan for #{wp_label(id)} ready for review")
      yes = { plan: "[y]es accept plan", commit: "[y]es commit", ship: "[y]es build" }.fetch(mode)
      prompt_choice("#{yes} / [s]kip / [d]rop / [c]hat / [r]e-plan",
                    { approve: %w[y yes], skip: %w[s skip], drop: %w[d drop],
                      chat: %w[c chat], replan: %w[r replan] },
                    default: :approve)
    end

    # Feedback for a re-plan. Empty input means "fold in what we discussed in
    # chat" — the LLM session already carries that conversation.
    def prompt_replan_feedback
      print "  Feedback (empty = revise per the chat above): "
      msg = $stdin.gets&.chomp.to_s
      msg.empty? ? "Revise the plan to incorporate the changes requested in the preceding conversation." : msg
    end

    def run_chat(st, model = Harness::MODEL_HEAVY)
      # The session already holds the plan (just generated/revised), so pass its
      # path as a fallback rather than re-embedding the full text on every turn.
      plan_ref = st.plan_file.exist? ? container_path(st.plan_file) : "(no plan yet)"
      puts ""
      # Same reasoning as the plan reference above, one level up: the orientation
      # goes once and every later turn is just the message, because the session
      # still holds it. The session already EXISTS here (planning made it), so
      # `st.session_file.exist?` would wrongly skip the first chat turn's
      # orientation — hence a flag scoped to this loop.
      oriented = false
      loop do
        print "\n  You (empty line to exit): "
        msg = $stdin.gets&.chomp
        break if msg.nil? || msg.empty?
        prompt = if oriented
                   msg
                 else
                   Prompts.plan_chat(
                     item_id: st.item_id, subject: st.subject,
                     item: container_path(st.item_file), plan: plan_ref, message: msg
                   )
                 end
        @harness.run(prompt, tools: read_tools, model: model, session_file: st.session_file)
        oriented = true
        # Ring after the reply, not before the first message: the user just
        # chose [c]hat and is present; it's the LLM's answers they wander off on.
        ping_terminal("opilot: chat reply for #{wp_label(st.item_id)} ready")
        puts ""
      end
    end

    # Helpers#implement_plan plus the console's own report of a no-op plan (the
    # agent answers that on the work package instead).
    def implement(st, model = Harness::MODEL_HEAVY)
      changed = implement_plan(st, model: model)
      if changed.empty?
        log_script "#{wp_label(st.item_id)} — no changes produced."
        puts "  ⚠ No changes produced — plan may be a no-op or already applied."
      end
      changed
    end

    # `commit`: implement and commit, then stop — nothing is pushed and no PR is
    # opened. The committed branch sits in the local clone for review; a later
    # `dev build <id>` finds it via branch_has_commits? and goes straight to publish.
    def commit(st, model = Harness::MODEL_HEAVY)
      implement(st, model).each do |repo|
        record_progress(st.item_id, st.branch, "built:#{repo.name}")
        puts "  ✓ Committed #{st.branch} (#{repo.name}) — review it in the clone, then ship it with `./opilot dev build #{st.item_id}`"
      end
    end

    def ship(st, model = Harness::MODEL_HEAVY)
      implement(st, model).each do |repo|
        generate_pr_description(st, repo)
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
    # there is nothing left to plan, build or ship for this WP. `all?`, not
    # `any?`: a fix that shipped to one of two repos must still finish the
    # other, which is the same rule Agent#shipped? applies.
    def report_already_shipped(st)
      return false unless st.repos.all? { |r| Helpers.file_has_content?(st.pr_url_file(r)) }
      st.repos.each { |r| puts "  Already shipped (#{r.name}): #{st.pr_url_file(r).read.strip}" }
      true
    end
  end
end
