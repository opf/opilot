require "yaml"
require "pathname"

module OPilot
  class Harness
    # One role the model plays, loaded from prompts/<name>.yml: its grant, model
    # and memory, and the charter that becomes its system prompt (Prompts.charter).
    # Every LLM call names one (Helpers#llm). The MCP tools resolve per call,
    # from the Context flags.
    Role = Data.define(:name, :base, :mcp, :model, :memory, :thinking, :charter) do
      def stateless = memory == :none

      def write? = base == TOOLS_IMPL

      def tools(ctx)
        mcp ? Harness.tools_for(base, op_mcp: ctx.op_mcp?, gh_mcp: ctx.gh_mcp?) : base
      end
    end

    ROLES_DIR = Pathname(__dir__).join("prompts").expand_path

    ROLE_VALUES = {
      "tools"  => { "read" => TOOLS_READ, "write" => TOOLS_IMPL },
      "mcp"    => { true => true, false => false },
      "model"  => { "heavy" => MODEL_HEAVY, "light" => MODEL_LIGHT },
      "memory" => { "session" => :session, "none" => :none },
    }.freeze

    # pi's levels; server.js passes a role's level as --thinking. Optional, and
    # only for a stateless role: a level change inside a session can drop the
    # prompt cache. pi clamps a level the model lacks to the nearest it has.
    THINKING_LEVELS = %w[off minimal low medium high xhigh max].freeze

    # Strict on purpose: a typo in a role file must fail at boot, not grant
    # something unexpected at the first call.
    def self.load_role(path)
      name = path.basename(".yml").to_s
      meta = YAML.safe_load(path.read)
      raise ArgumentError, "#{path}: not a YAML mapping" unless meta.is_a?(Hash)
      keys = ROLE_VALUES.keys + ["charter"]
      unless (meta.keys - ["thinking"]).sort == keys.sort
        raise ArgumentError, "#{path}: keys must be #{keys.join(", ")}, and optionally thinking"
      end
      charter = meta["charter"]
      raise ArgumentError, "#{path}: charter must be text" unless charter.is_a?(String) && !charter.strip.empty?
      values = ROLE_VALUES.to_h do |key, allowed|
        raise ArgumentError, "#{path}: #{key}: #{meta[key].inspect} is not one of #{allowed.keys.join(", ")}" unless allowed.key?(meta[key])
        [key.to_sym, allowed[meta[key]]]
      end
      # YAML reads a bare `off` as false; server.js reads the same file as text.
      thinking = meta["thinking"] == false ? "off" : meta["thinking"]
      if meta.key?("thinking")
        raise ArgumentError, "#{path}: thinking: #{thinking.inspect} is not one of #{THINKING_LEVELS.join(", ")}" unless THINKING_LEVELS.include?(thinking)
        raise ArgumentError, "#{path}: thinking needs memory: none" unless values[:memory] == :none
      end
      Role.new(name: name.to_sym, base: values[:tools], mcp: values[:mcp], model: values[:model],
               memory: values[:memory], thinking: thinking, charter: charter.strip)
    end

    ROLES = ROLES_DIR.glob("*.yml").sort.map { |f| load_role(f) }.to_h { |r| [r.name, r] }.freeze

    def self.role(name) = ROLES.fetch(name)
  end
end
