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

    # The artifacts a spec-driven change is made of, in dependency order
    # (proposal `<unlocks>` specs and design; tasks comes last).
    ARTIFACTS = %w[proposal specs design tasks].freeze

    # The CLI's own authoritative instructions for writing one artifact: its
    # task, the exact output path, the rules, and the section template.
    #
    # This is what keeps chomper aligned with OpenSpec instead of imitating it.
    # `openspec init --tools none` deliberately suppresses the AGENTS.md the CLI
    # would normally drop in a repo (the product clone already has a real one),
    # so without this the artifact format would live only in chomper's prompt —
    # a paraphrase that silently drifts, since `validate --strict` checks delta
    # structure but not, say, whether the proposal declares its capabilities.
    def instructions(artifact, change_id:)
      run("instructions", artifact, "--change", change_id)
    end

    # Every artifact's instructions, concatenated, ready to drop into a prompt.
    # `rewrite_paths` maps the runner's absolute paths to wherever the caller's
    # reader sees them; unmet-dependency warnings are dropped because in a
    # single pass nothing exists yet and "Missing: proposal" is noise, not news.
    def instructions_for_all(change_id, &rewrite_paths)
      ARTIFACTS.filter_map do |artifact|
        result = instructions(artifact, change_id: change_id)
        next unless result.ok?
        text = strip_warnings(result.out)
        rewrite_paths ? rewrite_paths.call(text) : text
      end.join("\n").strip
    end

    WARNING_BLOCK = %r{^<warning>.*?^</warning>\n?}m

    def strip_warnings(text)
      text.to_s.gsub(WARNING_BLOCK, "")
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
