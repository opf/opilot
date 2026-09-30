require "yaml"

module OPilot
  class Harness
    # One role the model plays, loaded from roles/<name>.md: frontmatter for the
    # grant, model and memory; the body is the role's charter, which opens the
    # role's prompts (Prompts.charter). HTML comments in the body are notes for
    # people and never reach the model. Every LLM call names one (Helpers#llm).
    # The MCP tools resolve per call, from the Context flags.
    Role = Data.define(:name, :base, :mcp, :model, :memory, :charter) do
      def stateless = memory == :none

      def write? = base == TOOLS_IMPL

      def tools(ctx)
        mcp ? Harness.tools_for(base, op_mcp: ctx.op_mcp?, gh_mcp: ctx.gh_mcp?) : base
      end
    end

    ROLES_DIR = Pathname(__dir__).join("../../roles").expand_path

    ROLE_VALUES = {
      "tools"  => { "read" => TOOLS_READ, "write" => TOOLS_IMPL },
      "mcp"    => { true => true, false => false },
      "model"  => { "heavy" => MODEL_HEAVY, "light" => MODEL_LIGHT },
      "memory" => { "session" => :session, "none" => :none },
    }.freeze

    # Strict on purpose: a typo in a role file must fail at boot, not grant
    # something unexpected at the first call.
    def self.load_role(path)
      name = path.basename(".md").to_s
      _, front, body = path.read.split(/^---\s*$/, 3)
      raise ArgumentError, "#{path}: no frontmatter" unless body
      meta = YAML.safe_load(front) || {}
      unless meta.keys.sort == ROLE_VALUES.keys.sort
        raise ArgumentError, "#{path}: keys must be #{ROLE_VALUES.keys.join(", ")}"
      end
      values = ROLE_VALUES.to_h do |key, allowed|
        raise ArgumentError, "#{path}: #{key}: #{meta[key].inspect} is not one of #{allowed.keys.join(", ")}" unless allowed.key?(meta[key])
        [key.to_sym, allowed[meta[key]]]
      end
      Role.new(name: name.to_sym, base: values[:tools], mcp: values[:mcp], model: values[:model],
               memory: values[:memory], charter: body.gsub(/<!--.*?-->/m, "").strip)
    end

    ROLES = ROLES_DIR.glob("*.md").sort.map { |f| load_role(f) }.to_h { |r| [r.name, r] }.freeze

    def self.role(name) = ROLES.fetch(name)
  end
end
