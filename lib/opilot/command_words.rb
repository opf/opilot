module OPilot
  # The @opilot command words, shared by every interface that reads them
  # (OpenProject::Pull#parse_command, Matrix::Pull#parse), so an alias added
  # here reaches both. Each interface keeps its own argument rules.
  module CommandWords
    # [pattern, verb, the word as people type it]. The words `build` replaced
    # (ship, plan, approve, …) are deliberately absent: they fall through to chat,
    # whose prompt names the real command.
    TABLE = [
      # `build`, alias `fix` — the same pair `./opilot dev` takes. The verb stays
      # :ship because publishing is what the handler does.
      [/\A(?:build|fix)\b\s*/i, :ship, "build"],
      # Two words: `create` alone could mean a branch, a PR or a comment.
      [/\Acreate\s+(?:wp|work\s+package)\b\s*/i, :create_wp, "create wp"],
      # Not a lens: it needs a fact pass, its own prompt and a composed reply.
      [/\Ahealth\b\s*/i, :health, "health"],
      # Chat lenses: a preset instruction over chat (Prompts::Advisor::LENSES).
      [/\A(grill|summarize)\b\s*/i, :lens, nil]
    ].freeze

    # { verb:, word:, rest: } for text that starts with a command word, else nil.
    # A lens reports its own name as the word.
    def self.match(text)
      TABLE.each do |pattern, verb, word|
        m = text.to_s.match(pattern) or next
        return { verb: verb, word: word || m[1].downcase, rest: m.post_match.strip }
      end
      nil
    end
  end
end
