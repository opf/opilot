module OPilot
  module Prompts
    # A String that knows its role. Concatenation returns a plain String,
    # which carries no role and is not checked.
    class Prompt < String
      attr_reader :role

      def initialize(text, role)
        super(text)
        @role = role
      end
    end

    # What a role's first prompt opens with: the role's own charter from
    # roles/<name>.md, then the rules its grant carries. Derived from the grant,
    # so a prompt cannot state a grant its role does not hold. Only prompts that
    # orient the model include it; a follow-up turn in the same session does not.
    def self.charter(name)
      role = Harness.role(name)
      grant = role.write? ? WRITE_GRANT : READ_ONLY
      "#{role.charter}\n#{grant}"
    end
  end
end
