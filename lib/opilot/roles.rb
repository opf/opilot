module OPilot
  class Harness
    # One role the model plays: its tool grant, its model, and whether it may
    # resume a session. Every LLM call names one (Helpers#llm). The MCP tools
    # resolve per call, because they follow the Context flags.
    Role = Data.define(:name, :base, :mcp, :model, :stateless) do
      def tools(ctx)
        mcp ? Harness.tools_for(base, op_mcp: ctx.op_mcp?, gh_mcp: ctx.gh_mcp?) : base
      end
    end

    # One entry per distinct (grant, model, memory) tuple in use. Two roles that
    # look alike but differ in grant stay separate until someone decides.
    ROLES = [
      Role.new(:planner,         TOOLS_READ, true,  MODEL_HEAVY, false), # plan, re-plan
      Role.new(:advisor,         TOOLS_READ, true,  MODEL_HEAVY, false), # WP chat, `chat`
      Role.new(:wp_writer,       TOOLS_READ, false, MODEL_HEAVY, false), # `create wp`
      Role.new(:triager,         TOOLS_READ, true,  MODEL_HEAVY, true),  # `appsignal fix`
      Role.new(:auditor,         TOOLS_READ, true,  MODEL_HEAVY, true),  # health
      Role.new(:implementer,     TOOLS_IMPL, false, MODEL_HEAVY, false), # fix, `pd implement`
      Role.new(:spec_writer,     TOOLS_IMPL, false, MODEL_HEAVY, false), # `pd propose`
      Role.new(:pr_author,       TOOLS_IMPL, true,  MODEL_HEAVY, false), # own-PR reply, CI fix
      Role.new(:pr_refresher,    TOOLS_IMPL, false, MODEL_HEAVY, false), # `dev refresh`
      Role.new(:pr_advisor,      TOOLS_READ, false, MODEL_HEAVY, false), # upstream PR, reply-only
      Role.new(:scribe,          TOOLS_READ, false, MODEL_LIGHT, true),  # commit subject, PR body
    ].to_h { |r| [r.name, r] }.freeze

    def self.role(name) = ROLES.fetch(name)
  end
end
