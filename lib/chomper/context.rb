require "pathname"
require "rainbow"

module Chomper
  FatalError = Class.new(StandardError)

  class Context
    attr_reader :script_dir, :state_dir, :backlog_json, :progress_file,
                :log_file, :claude_url, :github_token,
                :worktree_host, :worktree_container, :state_container,
                :anthropic_api_key, :op_url, :token, :repo_path

    def self.build(script_dir = nil)
      script_dir = Pathname(script_dir || File.expand_path("../../..", __FILE__))
      new(script_dir)
    end

    def initialize(script_dir)
      @script_dir         = Pathname(script_dir)
      @state_dir          = @script_dir / ".chomper"
      @backlog_json       = @state_dir / "backlog.json"
      @progress_file      = @state_dir / "progress.txt"
      @log_file           = @state_dir / "chomp.log"
      @github_token       = ENV["GITHUB_TOKEN"]
      @claude_url         = ENV.fetch("CLAUDE_URL", "http://claude:3000")
      @worktree_host      = @state_dir / "openproject"
      @worktree_container = "/repo"
      @state_container    = "/state"
      @anthropic_api_key  = ENV["ANTHROPIC_API_KEY"]
      @op_url             = ENV["OP_URL"]
      @token              = ENV["TOKEN"]
      @repo_path          = ENV["OP_REPO_PATH"] ? Pathname(ENV["OP_REPO_PATH"]) : nil

      @state_dir.mkpath
      @progress_file.open("a") {} # touch
    end

    def load_config!
      raise FatalError, "Config not found — add OP_URL, TOKEN, OP_REPO_PATH to .env and re-run." \
        unless @op_url && @token && @repo_path
    end
  end
end
