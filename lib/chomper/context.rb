require "pathname"
require "rainbow"

module Chomper
  FatalError = Class.new(StandardError)

  class Context
    attr_reader :script_dir, :state_dir, :progress_file,
                :log_file, :claude_url, :github_token,
                :worktree_host, :worktree_container, :state_container,
                :anthropic_api_key, :op_url, :token, :repo_path
    attr_reader   :allowed_emails

    def self.build(script_dir = nil)
      script_dir = Pathname(script_dir || File.expand_path("../../..", __FILE__))
      new(script_dir)
    end

    def initialize(script_dir)
      @script_dir         = Pathname(script_dir)
      @state_dir          = @script_dir / ".chomper"
      @progress_file      = @state_dir / "progress.txt"
      @log_file           = @state_dir / "chomp.log"
      @github_token       = ENV["GITHUB_TOKEN"]
      @claude_url         = ENV.fetch("CLAUDE_URL", "http://claude:3000")
      @worktree_host      = @state_dir / "openproject"
      @worktree_container = "/repo"
      @state_container    = "/state"
      @anthropic_api_key  = ENV["ANTHROPIC_API_KEY"]
      @op_url             = ENV["OPENPROJECT_URL"]
      @token              = ENV["OPENPROJECT_TOKEN"]
      @repo_path          = ENV["OP_REPO_PATH"] ? Pathname(ENV["OP_REPO_PATH"]) : nil
      # @chomper triggers are gated only when this list is non-empty; otherwise
      # every OpenProject user may trigger the agent.
      @allowed_emails        = ENV.fetch("CHOMPER_ALLOWED_EMAILS", "")
                                  .split(",").map { |e| e.strip.downcase }.reject(&:empty?)

      @state_dir.mkpath
      @progress_file.open("a") {} # touch
    end

    def load_config!
      raise FatalError, "Config not found — add OPENPROJECT_URL, OPENPROJECT_TOKEN, OP_REPO_PATH to .env and re-run." \
        unless @op_url && @token && @repo_path
    end
  end
end
