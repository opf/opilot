module OPilot
  # All LLM prompts, under lib/opilot/prompts/:
  #   blocks.rb    — prompt text more than one role uses (roles/_blocks/*.md)
  #   prompt.rb    — Prompt (a role-tagged String) and Prompts.charter
  #   sections.rb  — helper methods more than one role uses
  #   <role>.rb    — one module per role (roles/<name>.md): its builders, and
  #                  whatever text and helpers only that role uses
  # Builders are pure: they take already-resolved strings (container paths,
  # text) and return a Prompt tagged with its role — no I/O, no context lookups.
  #
  # A guardrail is stated once and interpolated, never re-worded per prompt
  # (that's how contradictions creep in).
  module Prompts
  end
end

%w[blocks prompt sections
   planner advisor wp_writer triager auditor implementer spec_writer
   pr_author pr_refresher pr_advisor scribe].each { |f| require_relative "prompts/#{f}" }
