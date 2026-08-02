module Chomper
  class CLI
    def initialize(ctx)
      @ctx = ctx
    end

    def run(argv)
      cmd = argv[0] || ""
      ui  = UI.new(@ctx)

      case cmd
      when "", "--help", "-h"
        ui.usage
      when "status"
        ui.status
      when "reset"
        ui.reset
      when "agent"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Combined Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        CombinedAgent.new(@ctx).run
      when "op-agent"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        Agent.new(@ctx).run
      when "gh-agent"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== GH Session #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        GhAgent.new(@ctx).run
      when "chat"
        @ctx.load_config!
        @ctx.log_file.open("a") { |f| f.puts "\n=== Chat #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
        ChatRunner.new(@ctx).run(argv[1..].to_a.join(" "))
      when "ship", "fix"   # `fix` stays as an alias of `ship`
        with_ids(argv, "Ship", "ship") { |ids| FixRunner.new(@ctx).ship_ids(*ids) }
      when "build"
        with_ids(argv, "Build", "build") { |ids| FixRunner.new(@ctx).build_ids(*ids) }
      when "plan"
        with_ids(argv, "Plan", "plan") { |ids| FixRunner.new(@ctx).plan_ids(*ids) }
      when "pd"
        pd(argv)
      when "pr"
        pr(argv)
      when "pull"
        pull(argv)
      else
        $stderr.puts "Unknown argument: #{cmd}"
        ui.usage
        raise Chomper::FatalError
      end
    end

    private

    # `pd` is the product-development (spec-driven) pipeline. Every subcommand
    # goes through here, which is also the single place the direct-publish guard
    # is enforced.
    #
    # The whole pipeline assumes the CONTRIBUTOR identity: a fork the bot owns
    # and may push to, and product PRs opened from it. With a maintainer token
    # set, chomper is in direct-publish mode — Publish skips the fork and pushes
    # straight to the canonical repo — so a `pd` run would try to push spec
    # branches and spec-derived work to opf/*. Refuse before load_config! does
    # any network work rather than discovering it at push time.
    def pd(argv)
      unless @ctx.maintainer_token.empty?
        raise Chomper::FatalError, <<~MSG.strip
          pd commands are unavailable while GITHUB_MAINTAINER_TOKEN is set (direct-publish
          mode). The product-development pipeline publishes as the contributor bot.
          Unset it in .env and re-run.
        MSG
      end
      # Required here rather than at boot: the intake converter drags in roo,
      # nokogiri and rubyzip, and no other command touches them.
      require "chomper/intake"
      require "chomper/product_runner"

      @ctx.load_config!
      sub = argv[1].to_s
      @ctx.log_file.open("a") { |f| f.puts "\n=== pd #{sub} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
      ProductRunner.new(@ctx).run(argv[1..].to_a)
    end

    # `pr` refreshes shipped PRs; it accepts work-package ids and/or pasted
    # GitHub PR URLs (a URL is resolved to its WP via chomper's own state, else
    # via the OpenProject ticket link at the top of the PR description).
    def pr(argv)
      args = argv[1..].to_a.map(&:strip).map { |a| a.match?(%r{\Ahttps?://}) ? a : wp_id_arg(a) }
      valid = args.all? do |a|
        a.match?(Helpers::WP_ID_PATTERN) ||
          (Clients::GitHub.repo_from_url(a) && Clients::GitHub.pr_number_from_url(a))
      end
      if args.empty? || !valid
        $stderr.puts "Usage: ./chomper pr <work-package-id | pr-url>...   " \
                     "(e.g. 59942, PROJ-123, or https://github.com/opf/openproject/pull/123)"
        raise Chomper::FatalError
      end
      @ctx.load_config!
      labels = args.map { |a| a.match?(Helpers::WP_ID_PATTERN) ? Helpers.wp_label(a) : a }.join(", ")
      @ctx.log_file.open("a") { |f| f.puts "\n=== PR refresh #{labels} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
      PrRunner.new(@ctx).run(*args)
    end

    # `pull` mirrors work packages into the local cache for later `chat`, without
    # planning or shipping. With ids it fetches exactly those (validated like
    # fix/plan); with no ids it runs the filter wizard and mirrors every match.
    def pull(argv)
      ids = argv[1..].to_a.map { |a| wp_id_arg(a) }
      if ids.any? { |id| !id.match?(Helpers::WP_ID_PATTERN) }
        $stderr.puts "Usage: ./chomper pull [<work-package-id>...]   (ids, or none to use saved/prompted filters)"
        raise Chomper::FatalError
      end
      @ctx.load_config!
      header = ids.empty? ? "by filter" : ids.map { |id| Helpers.wp_label(id) }.join(", ")
      @ctx.log_file.open("a") { |f| f.puts "\n=== Pull #{header} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
      PullRunner.new(@ctx).run(*ids)
    end

    # Shared setup for the id-based commands (`fix`, `plan`): validate the ids,
    # load config, write a log header, then yield the ids to the runner call.
    def with_ids(argv, label, usage)
      ids = argv[1..].to_a.map { |a| wp_id_arg(a) }
      if ids.empty? || ids.any? { |id| !id.match?(Helpers::WP_ID_PATTERN) }
        $stderr.puts "Usage: ./chomper #{usage} <work-package-id>...   (e.g. 59942 or PROJ-123 STC-7)"
        raise Chomper::FatalError
      end
      @ctx.load_config!
      labels = ids.map { |id| Helpers.wp_label(id) }.join(", ")
      @ctx.log_file.open("a") { |f| f.puts "\n=== #{label} #{labels} #{Time.now.strftime("%Y-%m-%dT%H:%M:%S")} ===" }
      yield ids
    end

    # Ids pasted from OpenProject often carry the "#" prefix ("#59942",
    # "#PROJ-123") — accept it, and upcase semantic ids typed in lowercase
    # ("proj-123"); the WP_ID_PATTERN validation downstream rejects garbage.
    def wp_id_arg(arg)
      id = arg.to_s.strip.delete_prefix("#")
      id.match?(/\A[A-Za-z][A-Za-z0-9_]*-\d+\z/) ? id.upcase : id
    end
  end
end
