require "json"

module OPilot
  module Runners
    # `./opilot gh <resource> <action>` — GitHub, read as the contributor bot.
    # Same contract as Runners::Op: JSON on stdout, diagnostics on stderr, reads
    # only.
    class Gh
      RESOURCES  = %w[pr].freeze
      PR_ACTIONS = %w[list].freeze

      def initialize(ctx, github: nil)
        @ctx    = ctx
        @github = github
      end

      def run(args)
        resource, action, *rest = args
        unknown!("resource", resource, RESOURCES) unless resource == "pr"
        unknown!("pr action", action, PR_ACTIONS) unless action == "list"
        reject!("gh pr list", "takes no arguments, got #{rest.map(&:inspect).join(", ")}") if rest.any?
        load_config!
        pr_list
      end

      private

      def github
        @github ||= Clients::GitHub.new(@ctx.contributor_token)
      end

      # The bot's open PRs — the set gh-agent polls — each with the state dir
      # that tracks it. `tracked: null` is an open PR gh-agent never reads.
      def pr_list
        prs = github.open_prs or fail!("the open-PR query failed")
        dirs = tracked_dirs
        out = prs.map do |p|
          dir = dirs[p["url"].to_s.downcase]
          { "url" => p["url"], "repo" => Clients::GitHub.repo_from_url(p["url"]),
            "number" => Clients::GitHub.pr_number_from_url(p["url"]),
            "updated_at" => p["updated_at"], "head_sha" => p["head_sha"], "ci" => p["ci"]&.to_s,
            "tracked" => dir&.relative_path_from(@ctx.state_dir)&.to_s }
        end
        $stdout.puts JSON.pretty_generate(out)
      end

      # PR URL → state dir, by pr_url.txt and by pr.json's URL (a renamed bot
      # account leaves the old name in pr_url.txt).
      def tracked_dirs
        pull = GitHub::Pull.new(@ctx, github: github)
        (pull.shipped_pr_dirs + pull.spec_pr_dirs).each_with_object({}) do |dir, map|
          cached = Helpers.safe_json_read(dir / "pr.json") || {}
          [(dir / "pr_url.txt").read.strip, cached["url"]].compact.each { |u| map[u.downcase] = dir }
        end
      end

      # The state is namespaced by the OpenProject host, so that is needed too.
      def load_config!
        fail!("GITHUB_CONTRIBUTOR_TOKEN is not set in .env") unless @ctx.contributor_token
        fail!("OPENPROJECT_URL is not set in .env") unless @ctx.op_url
      end

      def fail!(message)
        $stderr.puts message
        raise OPilot::FatalError
      end

      def reject!(command, message)
        fail!("#{command}: #{message}")
      end

      def unknown!(kind, given, allowed)
        $stderr.puts given.to_s.empty? ? "missing #{kind}" : "unknown #{kind} #{given.inspect}"
        $stderr.puts "Expected one of: #{allowed.join(", ")}"
        fail!("Run `./opilot gh --help` for the full list.")
      end
    end
  end
end
