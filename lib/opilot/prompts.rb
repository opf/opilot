module OPilot
  # All LLM prompts, in lib/opilot/prompts/. Each role is two files side by side:
  #   <role>.yml  — its grant, model, memory and charter
  #   <role>.rb   — its module: its builders, and what only its prompts use
  # _shared.rb holds what several roles use: the text blocks (from _blocks/),
  # Prompt and Prompts.charter, and the helper methods in Sections.
  # Builders are pure: they take already-resolved strings (container paths,
  # text) and return a Prompt tagged with its role — no I/O, no context lookups.
  #
  # A guardrail is stated once and interpolated, never re-worded per prompt
  # (that's how contradictions creep in).
  module Prompts
  end
end

# Not autoloaded: it defines Prompt, Sections and every shared text block.
require_relative "prompts/_shared"
