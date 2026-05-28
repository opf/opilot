require "json"

module Chomper
  FixState = Struct.new(
    :item_id, :title, :group, :complexity, :url,
    :files_hint, :item_dir,
    :plan_file, :item_file, :review_file, :pr_desc_file,
    :branch,
    keyword_init: true
  )

  class Fix
    include Helpers

    def initialize(ctx, backlog, claude)
      @ctx     = ctx
      @backlog = backlog
      @claude  = claude
    end

    def fix_item(item_id, cmd)
      item = @backlog.find(item_id)
      return unless item

      fs = build_fix_state(item_id, item)

      @backlog.set_state(fs.item_id, Backlog::STATE_IN_PROGRESS)
      log_script "##{item_id} — #{fs.title}\n  Group: #{fs.group} | Complexity: #{fs.complexity}\n  #{fs.url}"

      fs.item_dir.mkpath

      if local_branch_exists?(worktree, fs.branch)
        worktree.checkout(fs.branch)
        puts "  ✓ Resuming existing branch #{fs.branch}"
      else
        worktree.checkout(fs.branch, new_branch: true, start_point: 'origin/dev')
        puts "  ✓ Worktree on #{fs.branch}"
      end

      branch_has_commits = worktree.log.between('origin/dev', fs.branch).execute.any?

      if branch_has_commits
        puts "  ↩ Resuming: branch has commits, skipping plan + impl."
      else
        return if fix_plan(fs) == :rejected
        if @ctx.require_plan_approval
          case request_approval(fs)
          when :rejected, :skipped then return
          end
        end
        if cmd == "plan"
          @backlog.set_state(fs.item_id, Backlog::STATE_PLANNED)
          puts "  ✓ Plan saved — plan mode, skipping implementation."
          return
        end
        fix_impl(fs, tests_pre_written: false)
      end

      fix_commit(fs)
      puts ""
    end

    private

    def request_approval(fs)
      puts ""
      puts "  ── Plan: ##{fs.item_id} — #{fs.title}"
      puts ""
      puts fs.plan_file.read.lines.map { |l| "  #{l}" }.join
      puts ""
      loop do
        print "  Approve plan? [Y/n/skip] "
        response = $stdin.gets&.chomp&.downcase || ""
        case response
        when "", "y", "yes"
          log_script "Plan approved by user for ##{fs.item_id}."
          return :approved
        when "n", "no"
          log_script "Plan rejected by user for ##{fs.item_id} — resetting to pending."
          safe_rm(fs.plan_file)
          @backlog.set_state(fs.item_id, Backlog::STATE_PENDING)
          return :rejected
        when "s", "skip"
          log_script "Plan skipped for ##{fs.item_id} — saved as planned."
          @backlog.set_state(fs.item_id, Backlog::STATE_PLANNED)
          return :skipped
        else
          puts "  Please enter Y to approve, n to reject, or skip."
        end
      end
    end

    def fix_plan(fs)
      if fs.plan_file.exist? && fs.plan_file.size > 0
        puts "  ↩ Resuming: plan exists, skipping planning stage."
        return :ok
      end

      plan_c    = container_path(fs.plan_file)
      item_c    = container_path(fs.item_file)
      review_c  = container_path(fs.review_file)

      log_script "Writer: generating plan for ##{fs.item_id} — #{fs.title}"
      prompt = <<~PROMPT
        PRODUCT REPO: #{@ctx.worktree_container}
        ISSUE:        #{item_c}  (JSON — fields: subject, description, comments[], version, files_touched)
        HINT FILES:   #{fs.files_hint}
        You are the WRITER. Produce a plan only — do not modify any file.

        ## Plan: ##{fs.item_id} — #{fs.title}
        ### Files to change
        ### Approach
        ### Tests to run
        ### Risks / assumptions
      PROMPT
      @claude.capture(prompt, tools: Claude::TOOLS_READ, outfile: fs.plan_file, fresh: true)

      log_script "Reviewer: checking plan for ##{fs.item_id}"
      review_prompt = <<~PROMPT
        You are the REVIEWER. Read the plan at #{plan_c} and critique it.
        Flag: wrong file paths, missing edge cases, unnecessary complexity, blast radius.

        ## Review: ##{fs.item_id}
        ### Issues found  (or 'None')
        ### Suggested adjustments  (or 'None')
        ### Verdict  PROCEED | REVISE | REJECT
      PROMPT
      @claude.capture(review_prompt, tools: Claude::TOOLS_READ, outfile: fs.review_file, fresh: true)

      verdict = fs.review_file.read.scan(/\b(PROCEED|REVISE|REJECT)\b/i).last&.first&.upcase || "PROCEED"

      case verdict
      when "REJECT"
        log_script "Plan REJECTED for ##{fs.item_id} — moving to next item."
        worktree.checkout('origin/dev', detach: true)
        Git.open(@ctx.repo_path.to_s).branch(fs.branch).delete rescue nil
        @backlog.set_state(fs.item_id, Backlog::STATE_BLOCKED)
        @ctx.progress_file.open("a") { |f| f.puts "#{Time.now.strftime("%Y-%m-%dT%H:%M")}|#{fs.item_id}|-|REJECTED" }
        safe_rm(fs.review_file)
        return :rejected
      when "REVISE"
        log_script "Revising plan for ##{fs.item_id} based on reviewer feedback"
        revise_prompt = <<~PROMPT
          Read the original plan at #{plan_c} and the review at #{review_c}.
          Revise the plan incorporating the reviewer's suggestions.
          Print the complete revised plan to stdout only — do not write or edit any files.
        PROMPT
        @claude.capture(revise_prompt, tools: Claude::TOOLS_READ, outfile: fs.plan_file, fresh: true)
      end

      safe_rm(fs.review_file)
      :ok
    end

    def fix_impl(fs, tests_pre_written:)
      log_script "Implementing fix for ##{fs.item_id}"
      plan_c = container_path(fs.plan_file)
      test_instruction = tests_pre_written ?
        "- Do not modify the tests" :
        "- Write tests as specified in the plan, then implement the fix"
      prompt = <<~PROMPT
        PRODUCT REPO: #{@ctx.worktree_container}
        APPROVED PLAN: #{plan_c}

        Check the current state of the worktree (uncommitted changes, existing work in progress).
        Continue from wherever things are — there may already be partial or complete work in place.
        Implement what's missing to fix the issue according to the plan.
        #{test_instruction}
        - Do not commit
      PROMPT
      @claude.run(prompt, tools: Claude::TOOLS_IMPL, fresh: true)
    end

    def fix_commit(fs)
      worktree.add(all: true)
      diff = worktree.diff('HEAD')
      if diff.entries.empty?
        log_script "##{fs.item_id} — nothing to commit, leaving as pending for retry."
        @ctx.progress_file.open("a") { |f| f.puts "#{Time.now.strftime("%Y-%m-%dT%H:%M")}|#{fs.item_id}|#{fs.branch}|no-changes" }
        return
      end

      stats = diff.stats
      stats[:files].each { |f, s| puts "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
      puts "  #{stats[:total][:files]} file(s) changed"
      puts ""
      worktree.commit("fix(#{fs.group}): #{fs.title} (WP ##{fs.item_id})")
      c = worktree.log(1).first
      log_script "Committed: #{c.sha[0, 7]} #{c.message}"

      @backlog.set_state(fs.item_id, Backlog::STATE_COMMITTED)
      @ctx.progress_file.open("a") { |f| f.puts "#{Time.now.strftime("%Y-%m-%dT%H:%M")}|#{fs.item_id}|#{fs.branch}|committed" }

      item_c = container_path(fs.item_file)
      plan_c = container_path(fs.plan_file)
      log_script "Generating PR description for ##{fs.item_id}"

      template_section = ""
      template_file = @ctx.repo_path / ".github" / "pull_request_template.md"
      template_section = "Fill in this PR template exactly: #{template_file}" if template_file.exist?

      diff_stat = worktree.diff('HEAD~1', 'HEAD').stats[:files]
        .map { |f, s| "  #{f} | +#{s[:insertions]} -#{s[:deletions]}" }
        .join("\n")
      prompt = <<~PROMPT
        Write a GitHub PR description for this fix.

        ISSUE: #{item_c}
        PLAN:  #{plan_c}
        DIFF:
        #{diff_stat}
        #{template_section}
        Always include a ## Screenshots section immediately after the "## What approach did you choose and why?" section,
        even if empty (write "N/A" or "No visual changes").
        Output only the PR description — no preamble.
      PROMPT

      pr_text = @claude.run(prompt, tools: Claude::TOOLS_READ, fresh: true)
      # Strip everything before the first markdown heading
      pr_body = pr_text[/^#.*/m] || pr_text
      fs.pr_desc_file.write(strip_ansi(pr_body))
      puts ""
      puts "  ✓ PR description → #{fs.pr_desc_file}"
      puts "  Push & open PR:"
      puts "    git -C #{@ctx.worktree_host} push -u origin #{fs.branch}"
      puts "    gh pr create --draft --base dev --head #{fs.branch} --body-file #{fs.pr_desc_file}"
    end

    def worktree
      @worktree ||= Git.open(@ctx.worktree_host.to_s)
    end

    def container_path(host_path)
      host_path.to_s.sub(@ctx.state_dir.to_s, @ctx.state_container)
    end

    def build_fix_state(item_id, item)
      title      = item["subject"].to_s
      group      = item["locality_group"].to_s
      complexity = item["complexity"].to_s
      url        = item["url"].to_s
      files_hint = Array(item["files_touched"]).join(", ")
      branch     = branch_slug(item_id, title)
      item_dir   = @ctx.state_dir / "items" / item_id.to_s

      FixState.new(
        item_id:      item_id.to_s,
        title:        title,
        group:        group,
        complexity:   complexity,
        url:          url,
        files_hint:   files_hint,
        item_dir:     item_dir,
        plan_file:    item_dir / "plan.md",
        item_file:    item_dir / "item.json",
        review_file:  item_dir / "review.txt",
        pr_desc_file: item_dir / "pr.md",
        branch:       branch
      )
    end
  end
end
