require "json"
require_relative "../pull"
require_relative "../ui"   # #usage! prints from UI#pd_commands, the single help source

module Chomper
  module PD
    # The `pd` (product development) command family: the spec-driven pipeline that
    # turns OpenProject Documents into an OpenSpec change proposal, work packages,
    # and implementation PRs.
    #
    # Kept in its own namespace because the bug-fix verbs (plan/build/ship/pr) all
    # take a work-package id too, while doing something entirely different — and
    # because the identity rules differ (see #publish below).
    #
    # `init`, `intake`, `propose`, `generate-wp` and `implement` are implemented;
    # `archive` is the remaining stage.
    class Runner
      include Helpers

      CHANGE_ID_PATTERN = /\A[a-z0-9][a-z0-9-]*\z/

      def initialize(ctx, op: nil, intake: nil, claude: nil, publish: nil, openspec: nil, pull: nil)
        @ctx      = ctx
        @op       = op || Clients::OpenProject.new(ctx.op_url, ctx.token)
        @intake   = intake
        @claude   = claude || Claude.new(ctx)
        @publish  = publish
        @openspec = openspec
        @pull     = pull
      end

      # Built on demand: Intake pulls in roo/nokogiri/rubyzip, and gh-agent
      # constructs a PD::Runner purely to revise a proposal — a path that never
      # reads a document.
      def intake_client
        @intake ||= begin
          require_relative "intake"
          Intake.new(@ctx, op: @op)
        end
      end

      # How many times Claude gets to fix its own output before the run fails.
      # Two is plenty: past that the problem is the prompt or the intake, not a
      # structural slip the model can see and correct.
      MAX_VALIDATE_ATTEMPTS = 2

      def run(argv)
        case argv[0]
        when "init"    then init(*argv[1..].to_a)
        when "intake"  then intake(*argv[1..].to_a)
        when "propose" then propose(*argv[1..].to_a)
        when "generate-wp" then generate_wp(*argv[1..].to_a)
        when "implement" then implement(*argv[1..].to_a)
        else usage!(argv[0])
        end
      end

      # `pd init [--repo <name>]` — resolve the OpenProject ids and seed the
      # canonical spec store. Safe to re-run.
      def init(*args)
        opts       = parse_options(args)
        project_id = opts[:positional][0]
        usage!("init", "a project id is required") unless project_id

        repo = resolve_repo(opts[:repo])
        require_clone!(repo)
        log_script "Resolving OpenProject ids for project #{project_id}…"
        data = ResolvedIds.new(@ctx, op: @op).resolve!(project_id)
        report_resolved(data)
        report_publish_identity

        log_script "Seeding the canonical spec store for #{repo.name}…"
        store = ChangeStore.new(@ctx, repo)
        store.setup!
        puts "  ✓ store   #{store.root}"
        puts "  ✓ working #{store.working_tree} (git-excluded in the clone)"
        puts ""
        puts "  Next: ./chomper pd intake #{project_id} <change-id> [--doc-id <id>]"
        data
      end

      # `pd intake <project-id> <change-id> [--doc-id <id>]...` — mirror the
      # selected documents into the change's intake/ directory.
      def intake(*args)
        opts       = parse_options(args)
        project_id = opts[:positional][0]
        change_id  = opts[:positional][1]
        usage!("intake", "a project id and a change id are required") unless project_id && change_id
        validate_change_id!(change_id)

        repo  = resolve_repo(opts[:repo])
        store = ChangeStore.new(@ctx, repo)
        unless store.initialized?
          raise Chomper::FatalError, "no spec store for #{repo.name} yet — run `./chomper pd init #{project_id}` first"
        end

        state = change_state_for(change_id, store)

        scope = opts[:doc_ids].any? ? "#{opts[:doc_ids].length} document(s)" : "every document"
        log_script "Intake — project #{project_id}, #{scope} → change #{change_id}"
        result = intake_client.fetch(state, project_id: project_id, doc_ids: opts[:doc_ids])
        record_intake(state, project_id, opts[:doc_ids], result) if result.changed?

        # Canonical → working on the way OUT, not on the way in. Intake is written
        # by the runner, into the canonical store (state.intake_dir, tracker.json);
        # the materialise-then-persist order the Claude-driven stages use would
        # mirror the stale working copy straight back over everything just written
        # and lose the whole intake. Nothing is committed here — the store commits
        # on the next persist!, with the change that consumed this intake.
        #
        # preserve: false because of that same ordering — the working copy holds
        # the OLDER tree by design here, not unsaved work, so the safety net would
        # fire and copy the whole tree aside on every healthy re-intake.
        store.materialise!(preserve: false)

        unless result.changed?
          puts "  No change since the last intake (#{result.hash[0, 19]}…) — nothing written."
          return result
        end

        report_intake(result, state)
        puts ""
        puts "  Next: ./chomper pd propose #{change_id}"
        result
      end

      # `pd propose <change-id>` — turn the intake into an OpenSpec change
      # proposal, validate it, and open the spec PR that is the approval gate.
      #
      # Halts there deliberately (§5 stage 2 step 9): the PR is where a human
      # reviews the decomposition, and revisions come from `@chomper` comments on
      # it rather than from re-running this command.
      def propose(*args)
        opts      = parse_options(args)
        change_id = opts[:positional][0]
        usage!("propose", "a change id is required") unless change_id
        validate_change_id!(change_id)

        repo  = resolve_repo(opts[:repo])
        store = ChangeStore.new(@ctx, repo)
        state = change_state_for(change_id, store)
        require_intake!(state, change_id)
        # Before the branch is checked out and the tree materialised, not after.
        ensure_claude!

        # Branch first, then materialise: checking out replaces the working tree,
        # and the spec tree has to land on top of whatever that leaves behind.
        checkout_branch(state, repo)
        store.materialise!

        return if write_proposal(state, repo) == :too_broad
        enforce_write_scope!(state)

        store.persist!("Propose #{change_id}")
        commit_spec_branch(state, repo)
        publish_proposal(state, repo)
      end

      # Revise a change's proposal in response to a review comment on its spec PR.
      #
      # Called by gh-agent, not from the CLI: `pd propose` is first-shot only, and
      # iteration belongs on the PR where the diff and the line-level comments are.
      # Everything the propose path guards is re-applied here — the same validator
      # loop and the same write scope — because a revision can go out of bounds
      # exactly as easily as a first draft.
      #
      # Returns Claude's raw text so the caller can post the reply; the commit is
      # left in the clone for the caller to push.
      def revise_proposal(change_id, comment_section:, pr_thread:, session_file:, repo_name: nil)
        repo  = resolve_repo(repo_name)
        store = ChangeStore.new(@ctx, repo)
        state = change_state_for(change_id, store)
        store.materialise!

        reply = @claude.run(
          Prompts.propose_feedback(change_id: change_id, change_dir: state.working_change_container,
                                   pr_thread: pr_thread, comment_section: comment_section),
          tools: Claude::TOOLS_IMPL, model: Claude::MODEL_WORK, session_file: session_file
        )

        # A question rather than a change request leaves the tree untouched: reply
        # and stop, rather than validating and committing nothing.
        if store.working_changes.empty?
          log_script "#{change_id} — answered without editing the proposal."
          return reply
        end

        validate_proposal!(state, repo)
        enforce_write_scope!(state)
        store.persist!("Revise #{change_id} from PR feedback")
        commit_spec_branch(state, repo, subject: "Revise #{change_id} from review feedback")
        reply
      end

      # `pd generate-wp <change-id>` — turn the reviewed proposal into work
      # packages: one parent FEATURE for the change, one child IMPLEMENTATION per
      # top-level `tasks.md` section, with each id bound back into the heading.
      #
      # Running this IS the approval signal. It reads the local spec store rather
      # than the spec branch, so merging the PR stays optional — but nothing here
      # is undoable (chomper's HTTP client has no DELETE verb, and OpenProject
      # keeps a work package's comments and history nowhere else), so every write
      # is idempotent: a section that already carries an id is left alone, and the
      # parent is created once and remembered in tracker.json.
      def generate_wp(*args)
        opts      = parse_options(args)
        change_id = opts[:positional][0]
        usage!("generate-wp", "a change id is required") unless change_id
        validate_change_id!(change_id)

        repo  = resolve_repo(opts[:repo])
        store = ChangeStore.new(@ctx, repo)
        state = change_state_for(change_id, store)
        require_intake!(state, change_id)

        # Canonical → working first, then edit the working copy and persist back —
        # the propose ordering, not intake's. Writing the store first would make
        # the working copy differ from canonical at materialise! time, and the
        # unsaved-work safety net would set the whole tree aside on every run.
        store.materialise!
        tasks    = require_tasks!(state, change_id)
        sections = TasksFile.parse(tasks.read)
        raise Chomper::FatalError, no_sections_message(change_id) if sections.empty?
        reject_duplicate_titles!(sections, change_id)
        ids = require_resolved_ids!(state)

        log_script "Generating work packages for #{change_id} (#{sections.length} section(s))…"
        parent = ensure_feature_wp(state, spec_pr_url(state))
        raise Chomper::FatalError, "could not create the parent #{@ctx.pd_parent_type} work package" unless parent

        begin
          created, failed = create_child_wps(state, tasks, sections, ids, parent)
        ensure
          # Persist whatever got bound, even if the loop died partway: the ids are
          # the only link back to work packages that cannot be deleted.
          store.persist!("Bind work packages for #{change_id}")
        end

        report_generated(state, parent, sections, created, failed)
        { parent: parent, created: created, failed: failed }
      end

      # `pd implement <wp-id>...` — build one generated work package: implement its
      # tasks.md section on its own branch, commit, tick the section, and open the
      # draft PR. One work package per run, one PR per work package, because that is
      # the unit `generate-wp` decomposed the change into and the unit a reviewer
      # reads.
      #
      # Deliberately keyed on a WORK-PACKAGE id, not a change id: the work packages
      # are what a human assigns, comments on and closes, and implementing a whole
      # change in one pass would produce exactly the unreviewable PR the
      # decomposition exists to avoid.
      def implement(*args)
        opts = parse_options(args)
        ids  = opts[:positional]
        usage!("implement", "at least one work-package id is required") if ids.empty?

        ids.each do |wp_id|
          implement_one(wp_id, repo_name: opts[:repo])
        rescue Chomper::FatalError, Claude::Error => e
          # With one id there is nothing else to do, so the failure is the result;
          # with several, one bad id must not cost the others their run.
          raise if ids.length == 1
          log_script "#{Helpers.wp_label(wp_id)} — #{e.message}"
        end
      end

      private

      # Resolve the publishing identity now rather than at `propose`'s push. Every
      # `pd` stage publishes as the contributor bot, and propose only discovers a
      # missing or invalid token after Claude has done the expensive work.
      #
      # Advisory, not fatal: `init` and `intake` are useful with no GitHub token at
      # all, so this reports and moves on.
      def report_publish_identity
        if @ctx.contributor_token.to_s.empty?
          puts "  ⚠ github   GITHUB_CONTRIBUTOR_TOKEN is not set — `pd propose` cannot open the spec PR."
          return
        end
        login  = publish.login
        scopes = publish.token_scopes
        puts "  ✓ github   #{login}#{scopes.empty? ? "" : " (scopes: #{scopes.join(", ")})"}"
        missing = %w[public_repo workflow gist] - scopes
        # An empty scope list means a fine-grained token (no X-OAuth-Scopes header),
        # where these classic scope names don't apply — don't invent a warning.
        return if scopes.empty? || missing.empty?
        puts "  ⚠ github   the token is missing #{missing.join(", ")} — see the README on " \
             "why chomper needs public_repo, workflow and gist."
      rescue StandardError => e
        puts "  ⚠ github   could not verify GITHUB_CONTRIBUTOR_TOKEN (#{e.message}) — " \
             "`pd propose` may fail to publish."
      end

      def require_intake!(state, change_id)
        unless state.store.initialized?
          raise Chomper::FatalError,
                "no spec store for #{state.repo.name} yet — run `./chomper pd init <project-id>` first"
        end
        return if state.intake_dir.directory? && state.intake_dir.children.any?
        raise Chomper::FatalError,
              "change #{change_id} has no intake yet — run " \
              "`./chomper pd intake <project-id> #{change_id}` first"
      end

      # tasks.md is the binding between the spec tree and OpenProject, so it is
      # also the precondition for generating anything.
      def require_tasks!(state, change_id)
        tasks = state.working_change_dir / "tasks.md"
        return tasks if Helpers.file_has_content?(tasks)
        raise Chomper::FatalError,
              "change #{change_id} has no tasks.md yet — run `./chomper pd propose #{change_id}` first"
      end

      def no_sections_message(change_id)
        "tasks.md for #{change_id} has no top-level `## ` sections, so there is nothing to " \
          "generate. Fix the proposal (comment `@chomper` on its PR) and re-run."
      end

      # The binding is by heading text — TasksFile.bind_id rewrites the section it
      # matches — so two unbound sections sharing a title would both take the first
      # id created: one work package for two chunks of work, and the second never
      # generated at all. Refuse rather than guess, since nothing here can delete
      # what it created.
      def reject_duplicate_titles!(sections, change_id)
        dupes = sections.reject(&:wp_id).map(&:title).tally.select { |_, n| n > 1 }.keys
        return if dupes.empty?
        raise Chomper::FatalError, <<~MSG.strip
          tasks.md for #{change_id} has more than one top-level section titled:
          #{dupes.map { |t| "  #{t}" }.join("\n")}
          Each section becomes one work package and the id is bound back into the
          heading by title, so the titles have to be unique. Rename them and re-run.
        MSG
      end

      # `pd init`'s cache, or a fatal error naming the fix. generate-wp is the first
      # stage that writes to OpenProject, and it needs all three ids (project,
      # parent type, child type) before it POSTs anything — half a tree is worse
      # than none when the halves can't be deleted.
      def require_resolved_ids!(state)
        ids        = ResolvedIds.new(@ctx, op: @op).read
        project_id = ids["project_id"] || state.tracker["project_id"]
        missing    = []
        missing << "the project id" unless project_id
        missing << "the #{@ctx.pd_parent_type} type id" unless ids.dig("types", "parent", "id")
        missing << "the #{@ctx.pd_child_type} type id" unless ids.dig("types", "child", "id")
        return ids.merge("project_id" => project_id) if missing.empty?

        raise Chomper::FatalError,
              "cannot create work packages without #{missing.join(", ")} — run " \
              "`./chomper pd init <project-id>` first"
      end

      # The spec PR, for the "here is the proposal" links. Absent when `propose`
      # couldn't open it; the stage still runs, it just links nothing.
      def spec_pr_url(state)
        Helpers.file_has_content?(state.pr_url_file) ? state.pr_url_file.read.strip : nil
      end

      # Claude writes the proposal, then the runner validates it and hands any
      # failures back. Validation is runner-side because the openspec CLI is not in
      # the claude container (guard-bash.js allows read-only git and nothing else),
      # so the "agent iterates on its own output" gate becomes a re-prompt loop.
      # Returns :too_broad when Claude refused on scope grounds.
      def write_proposal(state, repo)
        change_dir = state.working_change_dir
        log_script "Proposing #{state.change_id} in #{repo.name}…"
        text = @claude.run(
          Prompts.propose(
            change_id:    state.change_id,
            change_dir:   state.working_change_container,
            intake_dir:   "#{state.working_change_container}/intake",
            specs_dir:    "#{repo.worktree_container}/openspec/specs",
            repo:         repo.name,
            repo_path:    repo.worktree_container,
            instructions: artifact_instructions(state, repo)
          ),
          tools: Claude::TOOLS_IMPL, model: Claude::MODEL_WORK, session_file: state.session_file
        )

        # What Claude DID beats what it said about what it did. It routinely
        # narrates its reasoning ("this is one feature, so I wrote a proposal
        # rather than TOO_BROAD"), and a bare search for the sentinel anywhere in
        # that prose reads the explanation as the verdict — discarding a complete,
        # already-written proposal.
        if proposal_present?(state)
          validate_proposal!(state, repo)
          return nil
        end

        if too_broad?(text)
          report_too_broad(state, text)
          return :too_broad
        end
        raise Chomper::FatalError, "no proposal was written to #{change_dir}"
      end

      # The scope refusal is only a refusal when it is the ANSWER: the prompt asks
      # for it on the first line, so anything further in is Claude talking about
      # the sentinel rather than emitting it. A short preamble is tolerated the way
      # FixRunner tolerates one before NEEDS_INFO.
      def too_broad?(text)
        head = text.to_s.lstrip.lines.first(3).join
        head.match?(/^\s*TOO_BROAD\b/)
      end

      # OpenSpec's own per-artifact instructions, with every path it emits
      # rewritten from the runner's view of the clone to the container's — the CLI
      # resolves absolute paths against where IT ran, and Claude sees the same
      # files at /repos/<name>.
      #
      # Degrades to a note rather than failing the run: a paraphrase-free prompt
      # is the goal, but an openspec version that changed its command surface
      # shouldn't make `pd propose` unusable.
      def artifact_instructions(state, repo)
        host = repo.worktree_host.to_s
        text = openspec_for(repo).instructions_for_all(state.change_id) do |chunk|
          chunk.gsub(host, repo.worktree_container)
        end
        return text unless text.empty?

        log_script "Could not read openspec's artifact instructions — falling back to the templates on disk."
        "(The `openspec instructions` command returned nothing. Follow the templates " \
          "in #{repo.worktree_container}/openspec/ and the OpenSpec conventions for " \
          "proposal.md, specs/<capability>/spec.md, design.md and tasks.md.)"
      end

      def openspec_for(repo)
        @openspec || OpenSpec.new(repo.worktree_host)
      end

      def proposal_present?(state)
        Helpers.file_has_content?(state.working_change_dir / "proposal.md") &&
          Helpers.file_has_content?(state.working_change_dir / "tasks.md")
      end

      def validate_proposal!(state, repo)
        openspec = openspec_for(repo)
        (0..MAX_VALIDATE_ATTEMPTS).each do |attempt|
          result = openspec.validate(state.change_id)
          if result.ok?
            log_script "openspec validate #{state.change_id} --strict ✓"
            return
          end
          failures = OpenSpec.failures(result)
          if attempt == MAX_VALIDATE_ATTEMPTS
            raise Chomper::FatalError,
                  "the proposal still fails `openspec validate --strict` after " \
                  "#{MAX_VALIDATE_ATTEMPTS} revisions:\n#{failures}"
          end
          log_script "openspec validate failed (attempt #{attempt + 1}/#{MAX_VALIDATE_ATTEMPTS}) — re-prompting"
          @claude.run(
            Prompts.propose_revise(change_id: state.change_id, change_dir: state.working_change_container,
                                   failures: failures, attempt: attempt + 1,
                                   max_attempts: MAX_VALIDATE_ATTEMPTS),
            tools: Claude::TOOLS_IMPL, model: Claude::MODEL_WORK, session_file: state.session_file
          )
        end
      end

      # A planning stage must not be able to modify source. guard-writes.js confines
      # Claude to /repos, which is repo-level; this is the path-level half, and it
      # matters more here than it would with a dedicated spec repo because the run
      # happens inside a real product clone.
      #
      # Two surfaces to check: anything git can see (everything outside openspec/,
      # since the tree is git-excluded), and the tree itself, compared against the
      # canonical store.
      def enforce_write_scope!(state)
        # Two path spaces: git reports clone-relative ("openspec/changes/x/…"),
        # the store reports tree-relative ("changes/x/…"). Both need the scope
        # filter. Leaving it off the git side looked harmless while the tree was
        # untracked — but propose force-adds the change dir when it commits, so
        # from the second run on the change's OWN files come back as tracked
        # changes, and every revision was being discarded as out of scope.
        scope       = "changes/#{state.change_id}/"
        clone_scope = "openspec/#{scope}"
        status  = worktree(state.repo).status
        tracked = (status.changed.keys + status.added.keys + status.deleted.keys + status.untracked.keys).uniq
        strays  = tracked.reject { |path| path.start_with?(clone_scope) } +
                  state.store.working_changes(outside: scope)
        return if strays.empty?

        reset_out_of_scope!(state)
        raise Chomper::FatalError, <<~MSG.strip
          The propose run wrote outside openspec/changes/#{state.change_id}/ and was discarded:
          #{strays.first(20).map { |p| "  #{p}" }.join("\n")}
          A planning stage must not modify source. Nothing was committed or pushed.
        MSG
      end

      # Put the clone back the way it was: drop everything git tracks, then restore
      # the spec tree from the canonical store (which the run never touched).
      def reset_out_of_scope!(state)
        wt = worktree(state.repo)
        wt.reset_hard
        wt.clean(force: true, d: true)
        state.store.materialise!
      rescue StandardError => e
        log_script "Could not fully reset the clone after an out-of-scope write: #{e.message}"
      end

      # The spec tree is git-excluded so it can never be swept into an unrelated
      # bug-fix commit; committing it here is the one deliberate exception, hence
      # the force add.
      def commit_spec_branch(state, repo, subject: "Propose #{state.change_id}")
        Helpers.adopt_github_author!(publish.author_token)
        wt = worktree(repo)
        wt.add("openspec/changes/#{state.change_id}", force: true)
        # One status call, not two: ruby-git rebuilds it from four subprocesses
        # each time, over OpenProject's whole index. And `deleted` counts — a
        # revision that only removes an artifact ("drop design.md") was otherwise
        # reported as "no spec changes" and silently dropped.
        st = wt.status
        if st.added.empty? && st.changed.empty? && st.deleted.empty?
          log_script "#{state.change_id} — no spec changes to commit."
          return false
        end
        wt.commit("[#{state.change_id}] #{subject}")
        c = wt.log(1).execute.first
        log_script "Committed to #{repo.name}: #{c.sha[0, 7]} #{c.message.lines.first.to_s.strip}"
        true
      end

      def report_too_broad(state, text)
        body = text.to_s.sub(/.*\bTOO_BROAD\b\s*\n?/m, "").strip
        puts ""
        puts "  ⚠ #{state.change_id} covers more than one atomic feature, so no proposal was written."
        puts body.lines.map { |l| "    #{l}" }.join unless body.empty?
        puts ""
        puts "  Re-run `pd intake` with a narrower --doc-id selection, or split it into"
        puts "  several changes and propose each separately."
      end

      # Like every other mode, `pd` publishes as the contributor bot: spec
      # branches and spec-derived work go to the bot's own fork.
      def publish
        @publish ||= Publish.new(@ctx)
      end

      # Push the spec branch, open the PR that is the approval gate, and hang a
      # FEATURE work package off it. Ordered so a failure leaves the cheapest mess:
      # the commit is already local, the PR is idempotent, and the work package is
      # only created once the PR exists to link from it.
      def publish_proposal(state, repo)
        url = publish.open_spec_pr(state, repo, body: proposal_pr_body(state))
        unless url
          puts "  ⚠ Proposed on #{state.branch} but couldn't open the PR — is GITHUB_CONTRIBUTOR_TOKEN set?"
          return nil
        end
        record_progress(state.change_id, state.branch, "proposed")
        puts "  ✓ Proposal PR: #{url}"
        puts ""
        # Nothing is written to OpenProject yet, deliberately — see #ensure_feature_wp.
        puts "  Review the PR. Comment `@chomper <feedback>` on it to revise,"
        puts "  then: ./chomper pd generate-wp #{state.change_id}"
        url
      end

      # The PR body: what a reviewer needs before opening the diff.
      def proposal_pr_body(state)
        tracker  = state.tracker
        docs     = Array(tracker.dig("intake", "documents"))
        unread   = Array(tracker["unconvertible"])
        sections = TasksFile.parse(read_or_empty(state.working_change_dir / "tasks.md"))

        body = +"🤖 AI-generated change proposal. Chat with #{bot_mention} on this PR to revise it.\n\n"
        body << "**Change:** `#{state.change_id}`\n"
        body << "**Work packages this will generate:** #{sections.length}\n"
        sections.each { |s| body << "- #{s.title} (#{s.items.length} item#{"s" if s.items.length != 1})\n" }
        body << "\n**Intake — OpenProject documents consumed:**\n"
        docs.each do |d|
          body << "- #{Helpers.document_link(@ctx, d["id"], d["title"])} (updated #{d["updated_at"]})\n"
        end
        if unread.any?
          body << "\n**⚠ Attachments that could not be read (#{unread.length})** — if a requirement " \
                  "lives in one of these, it is missing from this proposal:\n"
          unread.each { |u| body << "- `#{u["file"]}` — #{u["reason"]}\n" }
        end
        body << "\nMerging is optional: `pd generate-wp` reads the local spec store, not this branch.\n"
        body
      end

      # --- work-package creation (called by `pd generate-wp`, M2) ------------

      # Create the parent FEATURE once and remember it. Idempotent on `parent_wp`:
      # a work package accumulates comments and history that exist nowhere else, so
      # a re-run must never mint a duplicate.
      #
      # Deliberately NOT called from `propose`: the spec PR is the approval gate,
      # work packages can never be deleted (no DELETE verb anywhere in the client),
      # so every rejected proposal would leave a permanent empty FEATURE — and
      # whether the change really is ONE feature is what the reviewer is deciding.
      # Running `generate-wp` is the approval signal, and creates the parent
      # together with the children that hang off it.
      def ensure_feature_wp(state, pr_url)
        existing = state.parent_wp
        return comment_pr_link(existing, state, pr_url) if existing

        ids = ResolvedIds.new(@ctx, op: @op).read
        project_id = ids["project_id"] || state.tracker["project_id"]
        type_id    = ids.dig("types", "parent", "id")
        unless project_id && type_id
          puts "  ⚠ No resolved ids yet — run `./chomper pd init <project-id>`; skipping work-package creation."
          return nil
        end

        code, body = @op.create_work_package(feature_payload(state, project_id, type_id))
        unless code == 201 && body
          puts "  ⚠ Could not create the FEATURE work package (HTTP #{code})."
          return nil
        end
        state.merge_tracker("parent_wp" => body["id"])
        comment_pr_link(body["id"], state, pr_url)
        body["id"]
      end

      def feature_payload(state, project_id, type_id)
        summary = read_or_empty(state.working_change_dir / "proposal.md").lines.first.to_s.sub(/\A#+\s*/, "").strip
        {
          "subject"     => summary.empty? ? state.change_id : summary[0, 200],
          "description" => { "format" => "markdown",
                             "raw" => "Generated by chomper from the OpenSpec change `#{state.change_id}`." },
          "_links"      => {
            "type"    => { "href" => "/api/v3/types/#{type_id}" },
            "project" => { "href" => "/api/v3/projects/#{project_id}" }
          }
        }
      end

      # One IMPLEMENTATION per unbound section, in file order, writing each id back
      # into tasks.md as soon as it exists — not in one pass at the end. A crash
      # between the POST and the write would otherwise leave a work package nothing
      # references and nothing can delete, and the next run would create a second.
      #
      # A failed POST is reported and the loop continues: the sections are
      # independent, and a re-run picks up exactly the ones still unbound.
      def create_child_wps(state, tasks, sections, ids, parent_wp)
        created = []
        failed  = []
        sections.each do |section|
          next if section.wp_id

          code, body = @op.create_work_package(child_payload(state, section, ids, parent_wp))
          if code == 201 && body
            tasks.write(TasksFile.bind_id(tasks.read, section.title, body["id"]))
            created << { "id" => body["id"], "title" => section.title }
            puts "  ✓ #{Helpers.wp_label(body["id"])}  #{section.title}"
          else
            failed << section.title
            puts "  ✗ #{section.title} — HTTP #{code}"
          end
        end
        [created, failed]
      end

      # The checklist goes into the description as a checklist: `pd implement` reads
      # its scope from tasks.md, but a human opening the work package should see the
      # same items without having to find the spec branch.
      def child_payload(state, section, ids, parent_wp)
        pr    = spec_pr_url(state)
        body  = +"Generated by chomper from the OpenSpec change `#{state.change_id}`"
        body << " ([proposal](#{pr}))" if pr
        body << ".\n"
        items = section.items.map { |i| "- [#{i[:done] ? "x" : " "}] #{i[:text]}" }.join("\n")
        body << "\n**Tasks**\n#{items}\n" unless items.empty?

        {
          "subject"     => section.title[0, 200],
          "description" => { "format" => "markdown", "raw" => body },
          "_links"      => {
            "type"    => { "href" => "/api/v3/types/#{ids.dig("types", "child", "id")}" },
            "project" => { "href" => "/api/v3/projects/#{ids["project_id"]}" },
            "parent"  => { "href" => "/api/v3/work_packages/#{parent_wp}" }
          }
        }
      end

      def report_generated(state, parent_wp, sections, created, failed)
        bound = sections.length - failed.length
        puts ""
        puts "  #{@ctx.pd_parent_type} #{Helpers.wp_label(parent_wp)} — #{bound}/#{sections.length} " \
             "section(s) bound, #{created.length} created this run"
        record_progress(state.change_id, state.branch, "generated-wp:#{created.length}")
        if failed.any?
          puts "  ⚠ #{failed.length} section(s) could not be created:"
          failed.each { |t| puts "      #{t}" }
          puts "    Re-run `./chomper pd generate-wp #{state.change_id}` — the bound ones are skipped."
        end
        puts ""
        puts "  Next: ./chomper pd implement <wp-id>"
      end

      # Skipped when `propose` never managed to open the PR — a comment reading
      # "up for review:" with nothing after it is worse than no comment.
      def comment_pr_link(wp_id, state, pr_url)
        return wp_id if pr_url.to_s.empty?
        @op.post_activity(wp_id, comment: "🤖 Change proposal `#{state.change_id}` is up for review: #{pr_url}")
        wp_id
      rescue StandardError => e
        log_script "Could not comment the PR link on ##{wp_id}: #{e.message}"
        wp_id
      end

      # --- implementation (`pd implement`) ----------------------------------

      def implement_one(wp_id, repo_name: nil)
        found = locate_section!(wp_id, repo_name)
        repo  = found[:repo]
        state = change_state_for(found[:change_id], found[:store])

        item = fetch_item(wp_id)
        st   = state_for(wp_id, item["subject"].to_s.empty? ? found[:section].title : item["subject"],
                         item["type"].to_s.empty? ? @ctx.pd_child_type : item["type"])
        # Recorded even though `pd` resolves the repo from the store: everything
        # downstream (`./chomper wp pr <id>`, gh-agent) reads target_repos.json to find
        # which clone a work package's PR belongs to.
        set_target_repos(st, [repo.name])

        puts ""
        puts "  #{wp_label(wp_id)} — #{st.subject}"
        puts "  #{found[:change_id]} / #{repo.name}"
        if Helpers.file_has_content?(st.pr_url_file(repo))
          puts "  Already shipped: #{st.pr_url_file(repo).read.strip}"
          return nil
        end

        ensure_claude!
        # Branch first, then materialise: checking out replaces the working tree.
        checkout_branch(st, repo)
        found[:store].materialise!
        write_plan_file(st, state, found[:section])

        unless branch_has_commits?(st, repo)
          log_script "Implementing #{wp_label(wp_id)} (#{found[:change_id]}) in #{repo.name}…"
          # Inside this branch, not above it: a re-run that only publishes an
          # already-built branch must not rewind the status it set last time.
          transition!(wp_id, item, @ctx.pd_implementing_status)
          @claude.run(
            Prompts.implement_task(
              repo: repo.name, repo_path: repo.worktree_container,
              change_id: found[:change_id], change_dir: state.working_change_container,
              wp_label: wp_label(wp_id), section: found[:section].title,
              tasks: render_tasks(found[:section]), item: container_path(st.item_file)
            ),
            tools: Claude::TOOLS_IMPL, model: Claude::MODEL_WORK, session_file: st.session_file
          )
          restore_spec_tree!(found[:store], found[:change_id])
          publish # memoize the identity commit() authors as
          commit(st, repo)
        end

        unless branch_has_commits?(st, repo)
          puts "  ⚠ No changes produced — the section may already be implemented, or the spec may be a no-op."
          return nil
        end

        tick_section!(found[:store], state, found[:section].title, wp_id)
        ship_task(st, state, repo, wp_id, item)
      end

      # Move a work package to the status named in the config, best-effort.
      #
      # Bookkeeping, never the deliverable: an instance that renamed or dropped the
      # status, a workflow that forbids the transition, or a plain API failure all
      # report and return. Failing an implementation that is already committed
      # because a status field wouldn't move would be absurd — and unlike the work
      # itself, a status is trivial for a human to set.
      #
      # `item` is the mirror fetched at the start of the run, so the current status
      # is already known: re-asserting the status a work package is already in would
      # add a journal entry saying nothing.
      def transition!(wp_id, item, status_name)
        return if status_name.to_s.empty?
        return if item["status"].to_s.casecmp?(status_name)

        status = resolved_status(status_name)
        unless status
          puts "  ⚠ No status named #{status_name.inspect} in `pd init`'s cache — leaving the status alone."
          puts "    Set CHOMPER_PD_IMPLEMENTING_STATUS / CHOMPER_PD_IMPLEMENTED_STATUS to match this instance."
          return
        end

        code, = @op.update_work_package(
          wp_id, { "_links" => { "status" => { "href" => "/api/v3/statuses/#{status["id"]}" } } }
        )
        if (200..299).cover?(code)
          item["status"] = status["name"]   # so a later transition in the same run compares correctly
          puts "  → status: #{status["name"]}"
        else
          puts "  ⚠ Could not set #{wp_label(wp_id)} to #{status["name"].inspect} (HTTP #{code}) — " \
               "the workflow may not allow that transition from #{item["status"].inspect}."
        end
      rescue StandardError => e
        puts "  ⚠ Could not set the status on #{wp_label(wp_id)}: #{e.message}"
      end

      # Statuses come from `pd init`'s cache, matched case-insensitively like the
      # type names — instances style them inconsistently ("In progress", "In
      # Progress") and an exact-match miss here would be pure friction.
      def resolved_status(name)
        statuses = Array(ResolvedIds.new(@ctx, op: @op).read["statuses"])
        statuses.find { |s| s["name"].to_s.casecmp?(name.to_s) }
      end

      # The work package as OpenProject has it, mirrored to item.json. Best-effort:
      # the spec is the requirement and it is already on disk, so an OpenProject
      # hiccup must not stop the implementation — the prompt just loses whatever a
      # human added in the comments.
      def fetch_item(wp_id)
        item = pull_client.fetch_single_item(wp_id)
        return item if item
        log_script "Could not fetch #{Helpers.wp_label(wp_id)} from OpenProject — working from the spec alone."
        Helpers.safe_json_read(Helpers.item_dir(@ctx, wp_id) / "item.json") || {}
      rescue StandardError => e
        log_script "Could not fetch #{Helpers.wp_label(wp_id)} (#{e.message}) — working from the spec alone."
        {}
      end

      # Built on demand, like #intake_client: most `pd` stages never talk to
      # OpenProject's work-package API at all.
      def pull_client
        @pull ||= Pull.new(@ctx)
      end

      # Which change (and which repo's store) a work-package id belongs to. The
      # answer lives in tasks.md — `ChangeStore#reverse_index` rebuilds it from the
      # bindings on every call rather than caching, so a store edited by hand still
      # resolves correctly.
      #
      # Searches every registry repo's store unless --repo narrows it: a work
      # package knows nothing about which clone it came from, and asking the
      # operator to remember would be asking them to repeat what the store knows.
      def locate_section!(wp_id, repo_name)
        repos = repo_name ? [resolve_repo(repo_name)] : @ctx.repos.all
        repos.each do |repo|
          store = ChangeStore.new(@ctx, repo)
          entry = store.reverse_index[wp_id.to_s]
          next unless entry

          state    = change_state_for(entry[:change_id], store)
          sections = TasksFile.parse((state.store_change_dir / "tasks.md").read)
          section  = sections.find { |s| s.wp_id.to_s == wp_id.to_s }
          return { repo: repo, store: store, change_id: entry[:change_id], section: section } if section
        end
        raise Chomper::FatalError, unknown_wp_message(wp_id, repos)
      end

      # Naming what IS bound beats "not found": the id is almost always a work
      # package from a different project, or a change id typed where a work-package
      # id belongs.
      def unknown_wp_message(wp_id, repos)
        bound = repos.flat_map do |repo|
          store = ChangeStore.new(@ctx, repo)
          store.reverse_index.map { |id, e| "  #{Helpers.wp_label(id)}  #{e[:change_id]} — #{e[:section]}" }
        end
        <<~MSG.strip
          #{Helpers.wp_label(wp_id)} is not bound to any tasks.md section, so there is
          no spec to implement it from. Run `./chomper pd generate-wp <change-id>` first.
          #{bound.empty? ? "No work packages are bound yet." : "Bound work packages:\n#{bound.join("\n")}"}
        MSG
      end

      def render_tasks(section)
        section.items.map { |i| "- [#{i[:done] ? "x" : " "}] #{i[:text]}" }.join("\n")
      end

      # plan.md, written by the runner rather than Claude: for a `pd` work package
      # the spec IS the plan. It exists because everything downstream of a shipped
      # PR expects one — the PR body's gist link, and the prompts gh-agent and
      # `wp pr` build (`plan:`) — so without it a pd PR would be the one kind
      # of chomper PR that can't explain itself.
      def write_plan_file(st, state, section)
        body = +"# #{section.title}\n\n"
        body << "Work package #{wp_label(st.item_id)} of the OpenSpec change " \
                "`#{state.change_id}`.\n\n"
        body << "## Tasks\n#{render_tasks(section)}\n\n"
        proposal = read_or_empty(state.working_change_dir / "proposal.md")
        body << "## Change proposal\n\n#{proposal}\n" unless proposal.empty?
        body << "\nFull spec: `openspec/changes/#{state.change_id}/` " \
                "(proposal.md, design.md, specs/, tasks.md) on this branch's repo.\n"
        st.plan_file.write(body)
      end

      # The spec is this stage's INPUT, so a spec edit is discarded rather than
      # fatal — the opposite call to #enforce_write_scope!, and for the opposite
      # reason: there the planning run had written source it had no business
      # touching, here failing would throw away a working implementation over a
      # stray edit. The tree is git-excluded, so nothing would have been committed
      # anyway; restoring it keeps the store as the single source of truth.
      def restore_spec_tree!(store, change_id)
        strays = store.working_changes
        return if strays.empty?
        puts "  ⚠ The run edited #{strays.length} spec file(s); restoring them from the store " \
             "(chomper owns openspec/, not the implementer):"
        strays.first(10).each { |p| puts "      #{p}" }
        store.materialise!(preserve: false)
        log_script "#{change_id} — discarded #{strays.length} out-of-scope spec edit(s)."
      end

      # Tick the section's checkboxes once the work is committed. The harness owns
      # these edits, never the agent: two runs implementing sibling sections would
      # otherwise both be rewriting the same file.
      def tick_section!(store, state, title, wp_id)
        tasks = state.working_change_dir / "tasks.md"
        return unless Helpers.file_has_content?(tasks)
        tasks.write(TasksFile.set_section_done(tasks.read, title, done: true))
        store.persist!("Implement #{title} (#{Helpers.wp_label(wp_id)})")
      end

      # Publish the branch as a draft PR the same way the bug-fix flow does, so the
      # result is an ordinary chomper PR: gh-agent picks it up from pr_url.txt, and
      # `./chomper wp pr <id>` can refresh it.
      def ship_task(st, state, repo, wp_id, item)
        generate_pr_description(st, repo, model: Claude::MODEL_WORK)
        url = publish.open_pr(st.item_id, st.subject, st.branch, repo)
        unless url
          # The status stays where it is: the work is committed but nothing is up
          # for review, which is exactly what "In progress" says.
          puts "  ⚠ Implemented on #{st.branch} (#{repo.name}) but couldn't open the PR — is GITHUB_CONTRIBUTOR_TOKEN set?"
          return nil
        end
        record_progress(state.change_id, st.branch, "implemented:#{wp_id}")
        puts "  ✓ Draft PR (#{repo.name}): #{url}"
        comment_implementation_pr(wp_id, state, url)
        transition!(wp_id, item, @ctx.pd_implemented_status)
        url
      end

      def comment_implementation_pr(wp_id, state, url)
        @op.post_activity(wp_id, comment: "🤖 Implementation PR for `#{state.change_id}`: #{url}")
      rescue StandardError => e
        log_script "Could not comment the PR link on #{Helpers.wp_label(wp_id)}: #{e.message}"
      end

      def read_or_empty(path)
        path.exist? ? path.read : ""
      end

      # The bot's @-handle, for the "reply here to revise" line. Resolving it costs
      # a GitHub call, so a failure degrades to the generic word rather than
      # blocking a PR body that is otherwise ready.
      def bot_mention
        login = publish.login
        login.to_s.empty? ? "chomper" : "@#{login}"
      rescue StandardError
        "chomper"
      end

      def resolve_repo(name)
        return @ctx.default_repo unless name
        @ctx.repos[name] ||
          raise(Chomper::FatalError,
                "unknown repo #{name.inspect} — repos.json has: #{@ctx.repos.all.map(&:name).join(", ")}")
      end

      def change_state_for(change_id, store)
        dir = Helpers.change_dir(@ctx, change_id)
        dir.mkpath
        ChangeState.new(change_id: change_id, store: store, state_dir: dir)
      end

      # change-id is author-supplied and becomes a directory name that everything
      # downstream binds to, so it is validated rather than sanitised — silently
      # rewriting it would break the binding the operator thinks they created.
      def validate_change_id!(change_id)
        return if change_id.match?(CHANGE_ID_PATTERN)
        raise Chomper::FatalError,
              "invalid change id #{change_id.inspect} — use kebab-case: lowercase letters, " \
              "digits and hyphens, starting with a letter or digit (e.g. add-recurring-meetings)"
      end

      def record_intake(state, project_id, doc_ids, result)
        state.merge_tracker(
          "change_id"     => state.change_id,
          "repo"          => state.repo.name,
          "project_id"    => project_id.to_s,
          "intake"        => {
            "hash"      => result.hash,
            "selection" => doc_ids.map(&:to_s),
            "documents" => result.documents.map do |d|
              { "id" => d["id"], "title" => d["title"].to_s,
                "updated_at" => d["updatedAt"] || d["updated_at"] }
            end
          },
          "unconvertible" => result.unconvertible
        )
      end

      def report_resolved(data)
        puts "  ✓ project  #{data["project_id"]}  #{data["project_name"]}"
        %w[parent child].each do |role|
          t = data.dig("types", role)
          puts "  ✓ type #{role.ljust(6)} #{t["name"]} (#{t["id"]})"
        end
        closed = ResolvedIds.closed_status_ids(data)
        puts "  ✓ statuses #{data["statuses"].length} (#{closed.length} closed)"
      end

      def report_intake(result, state)
        result.documents.each_with_index do |doc, i|
          puts "  ✓ ##{doc["id"]}  #{doc["title"]}  (#{doc["updatedAt"] || doc["updated_at"]})"
          puts "     #{format("%03d", i + 1)}-… .md"
        end
        if result.unconvertible.any?
          puts ""
          puts "  ⚠ #{result.unconvertible.length} attachment(s) could not be read — a requirement"
          puts "    hiding in one of these is MISSING from this intake:"
          result.unconvertible.each { |u| puts "      ##{u["document"]} #{u["file"]} — #{u["reason"]}" }
        end
        puts ""
        puts "  intake → #{state.intake_dir}"
      end

      # Minimal flag parsing: --repo <name> and repeatable --doc-id <id>.
      # Deliberately not OptionParser — chomper's other commands hand-roll their
      # argv handling too, and this keeps the "unknown flag" error in one voice.
      def parse_options(args)
        opts = { positional: [], doc_ids: [], repo: nil }
        # Split `--flag=value` into two tokens up front, so each flag needs one
        # arm below instead of one per spelling.
        queue = args.flat_map { |a| (m = /\A(--[a-z-]+)=(.*)\z/m.match(a)) ? [m[1], m[2]] : [a] }
        until queue.empty?
          arg = queue.shift
          case arg
          when "--doc-id" then opts[:doc_ids] << require_value!(queue, arg)
          when "--repo"   then opts[:repo] = require_value!(queue, arg)
          when /\A-/      then raise Chomper::FatalError, "unknown option #{arg.inspect}"
          else opts[:positional] << arg
          end
        end
        opts
      end

      def require_value!(queue, flag)
        value = queue.shift
        raise Chomper::FatalError, "#{flag} needs a value" if value.nil? || value.start_with?("-")
        value
      end

      # The command list itself lives in UI#pd_commands, the one place every help
      # path reads from. A bare `./chomper pd` is a request for help, not a typo —
      # reporting "unknown pd subcommand nil" at it named the wrong problem.
      def usage!(subcommand, reason = nil)
        message = if reason then "#{reason}\n\n"
                  elsif subcommand.to_s.empty? then ""
                  else "unknown pd subcommand #{subcommand.inspect}\n\n"
                  end
        raise Chomper::FatalError, message + UI.new(@ctx).pd_usage_text
      end
    end
  end
end
