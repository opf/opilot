require "json"

module Chomper
  # The `pd` (product development) command family: the spec-driven pipeline that
  # turns OpenProject Documents into an OpenSpec change proposal, work packages,
  # and implementation PRs.
  #
  # Kept in its own namespace because the bug-fix verbs (plan/build/ship/pr) all
  # take a work-package id too, while doing something entirely different — and
  # because the identity rules differ (see #publish below).
  #
  # M0 implements `init` and `intake`; the later stages land in M1–M4.
  class ProductRunner
    include Helpers

    CHANGE_ID_PATTERN = /\A[a-z0-9][a-z0-9-]*\z/

    def initialize(ctx, op: nil, intake: nil, claude: nil, publish: nil, openspec: nil)
      @ctx      = ctx
      @op       = op || Clients::OpenProject.new(ctx.op_url, ctx.token)
      @intake   = intake
      @claude   = claude || Claude.new(ctx)
      @publish  = publish
      @openspec = openspec
    end

    # Built on demand: Intake pulls in roo/nokogiri/rubyzip, and gh-agent
    # constructs a ProductRunner purely to revise a proposal — a path that never
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
      log_script "Resolving OpenProject ids for project #{project_id}…"
      data = ResolvedIds.new(@ctx, op: @op).resolve!(project_id)
      report_resolved(data)

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
      @claude.ensure_available! if @claude.respond_to?(:ensure_available!)

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

    private

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

    # The `pd` pipeline ALWAYS publishes as the contributor bot. FixRunner picks
    # its identity from the configured tokens; this must not, because every `pd`
    # push targets the bot's own fork. The CLI already refuses to dispatch `pd`
    # at all when a maintainer token is set — this is the second belt, so the
    # guard is never the only thing standing between `pd` and a canonical push.
    def publish
      @publish ||= Publish.new(@ctx, as: :contributor)
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
    # the work package accumulates comments and history that exist nowhere else,
    # so a re-run must never mint a duplicate.
    #
    # Deliberately NOT called from `propose`. The spec PR is the approval gate,
    # so creating a FEATURE there announces a planned feature before anyone has
    # agreed to it — and work packages are never deleted (chomper's HTTP client
    # has no DELETE verb at all), so every abandoned or rejected proposal would
    # leave a permanent empty FEATURE behind. It is also premature: whether the
    # change really is ONE atomic feature is exactly what the reviewer is
    # checking, and a review that says "split this" invalidates it.
    #
    # `generate-wp` is the right moment: the operator running it is the approval
    # signal (it reads the local store, so merging the PR is optional), and the
    # parent is then created together with the children that hang off it.
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

    def comment_pr_link(wp_id, state, pr_url)
      @op.post_activity(wp_id, comment: "🤖 Change proposal `#{state.change_id}` is up for review: #{pr_url}")
      wp_id
    rescue StandardError => e
      log_script "Could not comment the PR link on ##{wp_id}: #{e.message}"
      wp_id
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

    def usage!(subcommand, reason = nil)
      message = reason ? "#{reason}\n\n" : "unknown pd subcommand #{subcommand.inspect}\n\n"
      raise Chomper::FatalError, message + <<~USAGE.strip
        Usage: ./chomper pd <command>

          init <project-id> [--repo <name>]
              Resolve the OpenProject ids and seed the canonical spec store.

          intake <project-id> <change-id> [--doc-id <id>]... [--repo <name>]
              Mirror OpenProject Documents into the change's intake/ directory.
              Without --doc-id every document in the project is pulled in.

          propose <change-id> [--repo <name>]
              Write the OpenSpec change proposal from that intake, validate it,
              and open the spec PR that is the approval gate. Revise it by
              commenting `@chomper <feedback>` on the PR.

        change-id is author-chosen kebab-case (e.g. add-recurring-meetings).
      USAGE
    end
  end
end
