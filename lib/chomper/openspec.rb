require "json"
require "open3"
require "pathname"

module Chomper
  # Thin wrapper around the `openspec` CLI (npm @fission-ai/openspec, pinned in
  # Dockerfile.runner).
  #
  # It runs in the RUNNER, never in the claude container: guard-bash.js there
  # allows read-only git and nothing else, and widening it for a non-git binary
  # would undo the container's whole posture. So the agent writes spec files and
  # the runner validates them — the same split as every other tool chomper uses.
  #
  # `root` is the directory that CONTAINS the `openspec/` tree (a product clone,
  # or the canonical store), mirroring how the CLI resolves its root.
  class OpenSpec
    # `openspec init --tools none` writes only openspec/ — no AGENTS.md, no
    # .claude/ — which matters because the product clone already has a real
    # AGENTS.md (CLAUDE.md symlinks to it) that must never be clobbered.
    INIT_TOOLS = "none".freeze

    Result = Struct.new(:ok, :out, :err, keyword_init: true) do
      def ok?
        ok
      end

      # Parsed --json output, or nil when the command produced none (or died
      # before emitting it).
      def json
        @json ||= JSON.parse(out.to_s)
      rescue JSON::ParserError
        nil
      end

      # The most useful text to feed back to Claude or show the operator:
      # stderr when there is any, else stdout.
      def message
        e = err.to_s.strip
        e.empty? ? out.to_s.strip : e
      end
    end

    def initialize(root)
      @root = Pathname(root)
    end

    attr_reader :root

    # Seed a fresh openspec/ tree. Safe on an already-initialised root (the CLI
    # is idempotent), but callers generally only run it once, at `pd init`.
    def init!
      run("init", "--tools", INIT_TOOLS, "--no-animation", ".")
    end

    # Validate one change (or everything, when change_id is nil). --json gives a
    # structured verdict instead of scraped prose, so #failures below can report
    # exactly what to fix in the re-prompt loop.
    def validate(change_id = nil, strict: true)
      args = ["validate"]
      args << change_id if change_id
      args << "--type" << "change" if change_id
      args << "--strict" if strict
      args.push("--json", "--no-interactive")
      args << "--changes" unless change_id
      run(*args)
    end

    # Human-readable failure lines from a validate Result, for the re-prompt.
    # Falls back to the raw message when the JSON isn't in the shape we expect,
    # so a CLI change degrades to "show Claude the output" rather than silence.
    def self.failures(result)
      doc = result.json
      return result.message unless doc.is_a?(Hash) && doc["items"].is_a?(Array)

      lines = doc["items"].reject { |i| i["passed"] }.flat_map do |item|
        name = item["name"] || item["id"] || "(unnamed)"
        Array(item["issues"] || item["errors"]).map do |issue|
          detail = issue.is_a?(Hash) ? (issue["message"] || issue.to_json) : issue.to_s
          "#{name}: #{detail}"
        end
      end
      lines.empty? ? result.message : lines.join("\n")
    end

    def show(item, json: true)
      args = ["show", item]
      args << "--json" if json
      run(*args)
    end

    # Fold a completed change's deltas into openspec/specs/. --yes skips the
    # confirmation prompt (there is no operator at the terminal for the
    # auto-archive path); --skip-specs is for tooling-only changes with no
    # capability deltas.
    def archive(change_id, skip_specs: false)
      args = ["archive", change_id, "--yes"]
      args << "--skip-specs" if skip_specs
      run(*args)
    end

    private

    # Never shells out through a shell: Open3.capture3 with an argv array, so a
    # change id from a work package can't inject anything.
    def run(*args)
      out, err, status = Open3.capture3("openspec", *args, chdir: @root.to_s)
      Result.new(ok: status.success?, out: out, err: err)
    rescue Errno::ENOENT
      Result.new(ok: false, out: "",
                 err: "openspec CLI not found — rebuild the runner image (docker compose build runner)")
    end
  end
end
