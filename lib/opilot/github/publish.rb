module OPilot
  module GitHub
    class Publish
      include Helpers

      # Publishes as the contributor bot, to its fork only. See CLAUDE.md, step 4 "Publish".
      def initialize(ctx, github: nil)
        @ctx    = ctx
        @github = github || Clients::GitHub.new(author_token)
      end

      # Also the commit author, so a PR's commits match its opener.
      def author_token
        @ctx.contributor_token
      end

      def token_env_var
        "GITHUB_CONTRIBUTOR_TOKEN"
      end

      # Returns the PR URL, or nil on failure. Idempotent: an open PR is returned.
      def open_pr(item_id, subject, branch, repo)
        unless author_token
          puts "  Error: #{token_env_var} is not set — cannot open PRs."
          return nil
        end

        st           = state_for(item_id, subject)
        pr_desc_file = st.pr_desc_file(repo)
        pr_url_file  = st.pr_url_file(repo)
        upstream     = repo.upstream
        base         = st.base_for(repo)

        unless local_branch_exists?(worktree(repo), branch)
          puts "  Error: branch #{branch} not found in #{repo.name} — has this item been committed?"
          return nil
        end
        unless Helpers.file_has_content?(pr_desc_file)
          puts "  Error: no PR description at #{pr_desc_file} (missing or empty)"
          return nil
        end

        target_repo = @github.ensure_fork(upstream)
        head        = "#{target_repo.split('/').first}:#{branch}"

        existing = @github.find_open_pr(upstream, head: head)
        if existing
          pr_url_file.write(existing)
          return existing
        end

        log_script "Publishing #{wp_label(item_id)} → #{repo.name} (base #{base}, via #{target_repo}) — #{subject}"

        # `opilot-adopt` deletes the fenced banner; the plan link stays outside it
        # so it survives adoption. See CLAUDE.md, step 4 "Publish".
        banner    = "🤖 This is an AI-generated prototype.\n\n" \
                    "* To ask for a change, write a comment to @#{@github.login} on this PR."
        gist_url  = plan_gist_url(st)
        plan_line = gist_url ? "📋 **Implementation plan:** #{gist_url}\n\n" : ""
        pr_body   = "#{BANNER_OPEN}\n#{banner}\n#{BANNER_CLOSE}\n\n#{plan_line}#{pr_desc_file.read}"

        # Defanged (http→hxxp) to keep the PR off the WP's activity tab.
        pr_body = neutralize_wp_links(pr_body)

        # Backstop for an ensure_fork that resolved to the upstream itself.
        if refuse_canonical_push?(target_repo, branch)
          puts "  #{branch} was not pushed and no PR was opened."
          return nil
        end
        @github.push_branch(target_repo, branch: branch, worktree_path: repo.worktree_host)

        title = pr_title(item_id, subject)
        url = @github.create_draft_pr(upstream, base: base, head: head, title: title, body: pr_body,
                                      maintainer_can_modify: true)
        add_adopt_note(upstream, url, pr_body, banner)
        pr_url_file.write(url)
        record_progress(item_id, branch, "published:#{repo.name}")
        url
      end

      # One secret gist per chat answer, uncached. `files` is {name => content}.
      def artifact_gist(item_id, subject, files)
        return nil if files.empty?
        unless author_token
          puts "  Error: #{token_env_var} is not set — cannot publish artifacts."
          return nil
        end

        @github.create_gist(
          description: "opilot artifact: #{wp_label(item_id)} — #{subject}",
          files:       files
        )
      end

      def login
        @github.login
      end

      # The token's classic-PAT scopes, for `pd init`'s preflight. Empty means
      # "unknown" (fine-grained token, or the call failed), not "none".
      def token_scopes
        @github.token_scopes
      end

      # Opens the `pd` proposal PR inside the bot's fork, not upstream: the diff is
      # planning artifacts. Idempotent: an open PR for this head is returned.
      def open_spec_pr(state, repo, body:)
        unless author_token
          puts "  Error: GITHUB_CONTRIBUTOR_TOKEN is not set — cannot open the proposal PR."
          return nil
        end

        fork   = @github.ensure_fork(repo.upstream)
        branch = state.branch
        head   = "#{fork.split("/").first}:#{branch}"

        existing = @github.find_open_pr(fork, head: head)
        if existing
          state.pr_url_file.write(existing)
          return existing
        end

        base = state.base_for(repo)
        log_script "Publishing proposal #{state.change_id} → #{fork} (base #{base})"

        # Sync the fork's base first, or the diff shows every upstream commit
        # since the fork was made.
        @github.sync_fork_branch(fork, branch: base)

        if refuse_canonical_push?(fork, branch)
          # Without this the caller blames a missing token.
          puts "  #{branch} was not pushed and no PR was opened."
          return nil
        end
        @github.push_branch(fork, branch: branch, worktree_path: repo.worktree_host)

        url = @github.create_draft_pr(
          fork, base: base, head: branch,
          title: "[#{state.change_id}] Change proposal",
          # A same-repo PR 422s unless maintainer edits are off.
          body: body, maintainer_can_modify: false
        )
        state.pr_url_file.write(url)
        record_progress(state.change_id, branch, "proposal-pr")
        url
      end

      # Apply a reply's DESCRIPTION block (Prompts::DESCRIPTION_CONTRACT) to
      # opilot's own PR, and return the reply without it. A failure is logged
      # and stated in the reply, so the reply never claims an edit that failed.
      def apply_description(repo, number, reply)
        text, rest, cut_off = Helpers.split_description(reply)
        return "#{rest}\n\nI did not change the PR description: my answer was cut off." if cut_off
        return rest unless text

        current = @github.pull_request(repo, number).body.to_s
        body = self.class.description_body(current, text) or
          raise "the description has no opilot banner, so I did not replace it"
        @github.update_pr_body(repo, number, neutralize_wp_links(body))
        log_script "Updated the description of #{repo}##{number}"
        rest
      rescue => e
        log_script "Description update failed on #{repo}##{number}: #{e.message}"
        "#{rest}\n\nI could not update the PR description: #{e.message}"
      end

      # The current banner and plan link, then the new text. nil when the body
      # has no banner fence. `chomper` is the fence of PRs opened before the rename.
      BANNER_HEAD = %r{\A.*?<!-- /(?:opilot|chomper):banner -->[ \t]*\n(?:\s*📋 \*\*Implementation plan:\*\*[^\n]*\n)?}m
      COPIED_HEAD = %r{<!-- (opilot|chomper):banner -->.*?<!-- /\1:banner -->\s*|^📋 \*\*Implementation plan:\*\*[^\n]*\n?}m

      def self.description_body(current, text)
        head = current[BANNER_HEAD] or return nil
        "#{head.rstrip}\n\n#{text.gsub(COPIED_HEAD, "").strip}\n"
      end

      private

      # The anchor must match the README heading's slug.
      ADOPT_DOC_URL = "https://github.com/opf/opilot#adopting-an-opilot-pr"

      # A published interface: `opilot-adopt` deletes this range verbatim, so a
      # changed marker orphans every earlier PR. See CLAUDE.md, step 4 "Publish".
      BANNER_OPEN  = "<!-- opilot:banner -->"
      BANNER_CLOSE = "<!-- /opilot:banner -->"

      # A follow-up edit, because the number exists only after creation. It goes
      # inside the fence, so an adopted PR drops it. Best-effort.
      def add_adopt_note(upstream, url, pr_body, banner)
        number = Clients::GitHub.pr_number_from_url(url)
        return unless number
        note = "* To ship the PR, first make it yours: run `opilot-adopt #{number}` " \
               "([setup guide](#{ADOPT_DOC_URL}))."
        @github.update_pr_body(upstream, number, pr_body.sub(banner, "#{banner}\n#{note}"))
      rescue => e
        log_script "Could not add the adopt note to #{url}: #{e.message}"
      end

      # Cached in gist_url.txt so every repo's PR links the same gist.
      def plan_gist_url(st)
        cache = st.gist_url_file
        return cache.read.strip if Helpers.file_has_content?(cache)
        return nil unless Helpers.file_has_content?(st.plan_file)

        url = @github.create_gist(
          description: "opilot plan: #{wp_label(st.item_id)} — #{st.subject}",
          files:       { "wp-#{st.item_id}-plan.md" => st.plan_file.read }
        )
        cache.write(url) if url
        url
      end
    end
  end
end
