require "yaml"
require "pathname"

module OPilot
  class Harness
    # One role the model plays, loaded from prompts/<name>.yml: its grant, model
    # and memory, and the charter that opens its prompts (Prompts.charter).
    # Every LLM call names one (Helpers#llm). The MCP tools resolve per call,
    # from the Context flags.
    Role = Data.define(:name, :base, :mcp, :model, :memory, :charter) do
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

    # Strict on purpose: a typo in a role file must fail at boot, not grant
    # something unexpected at the first call.
    def self.load_role(path)
      name = path.basename(".yml").to_s
      meta = YAML.safe_load(path.read)
      raise ArgumentError, "#{path}: not a YAML mapping" unless meta.is_a?(Hash)
      keys = ROLE_VALUES.keys + ["charter"]
      raise ArgumentError, "#{path}: keys must be #{keys.join(", ")}" unless meta.keys.sort == keys.sort
      charter = meta["charter"]
      raise ArgumentError, "#{path}: charter must be text" unless charter.is_a?(String) && !charter.strip.empty?
      values = ROLE_VALUES.to_h do |key, allowed|
        raise ArgumentError, "#{path}: #{key}: #{meta[key].inspect} is not one of #{allowed.keys.join(", ")}" unless allowed.key?(meta[key])
        [key.to_sym, allowed[meta[key]]]
      end
      Role.new(name: name.to_sym, base: values[:tools], mcp: values[:mcp], model: values[:model],
               memory: values[:memory], charter: charter.strip)
    end

    ROLES = ROLES_DIR.glob("*.yml").sort.map { |f| load_role(f) }.to_h { |r| [r.name, r] }.freeze

    def self.role(name) = ROLES.fetch(name)
  end
end
