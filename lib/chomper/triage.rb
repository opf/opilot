require "json"

module Chomper
  class Triage
    include Helpers
    BATCH_SIZE = 25

    SCHEMA = <<~JSON.freeze
      {
        "id":             "<same id as input>",
        "locality_group": "<subsystem: auth|api|db|ui|payments|...>",
        "complexity":     "<trivial|simple|moderate|complex>",
        "files_touched":  ["<likely source file paths>"],
        "ai_category":    "<null-safety|type-error|logic-bug|perf|refactor|test|feature|chore>",
        "state":          "pending"
      }
    JSON

    def initialize(ctx, backlog, claude)
      @ctx     = ctx
      @backlog = backlog
      @claude  = claude
    end

    def run_triage_stage
      untriaged = @backlog.untriaged
      return if untriaged.empty?

      total_batches = (untriaged.length.to_f / BATCH_SIZE).ceil
      puts "  #{untriaged.length} issues · #{total_batches} batches of #{BATCH_SIZE}"

      untriaged.each_slice(BATCH_SIZE).with_index(1) do |batch, batch_num|
        puts "  Batch #{batch_num} / #{total_batches}"

        triage_input = @ctx.state_dir / "triage_input.json"
        triage_input.write(JSON.generate(batch))

        input_c = "#{@ctx.state_container}/triage_input.json"
        text = @claude.run(build_prompt(input_c))

        json_block = extract_json_block(text)
        if json_block.nil? || json_block.strip.empty?
          puts "  Warning: no JSON extracted for batch #{batch_num} — skipping."
          safe_rm(triage_input)
          next
        end

        triaged = JSON.parse(json_block) rescue nil
        unless triaged.is_a?(Array)
          puts "  Warning: invalid JSON in batch #{batch_num} — skipping."
          safe_rm(triage_input)
          next
        end

        @backlog.merge_triage_results(triaged)
        safe_rm(triage_input)
      end

      @backlog.sort_by_complexity!
    end

    private

    def build_prompt(input_container_path)
      <<~PROMPT
        Read #{input_container_path} — a JSON array of Bug work packages.
        Each item has: id, subject, description, comments[], version, category, priority.

        For each item print one line:
          #<id> <subject> → <locality_group> / <complexity>

        Then output the complete results between these exact delimiters — nothing after the closing delimiter:
        ---BEGIN JSON---
        [one object per item]
        ---END JSON---

        Schema per object:
        #{SCHEMA}

        Complexity guide:
          trivial  — single obvious fix, ≤2 files
          simple   — clear fix, ≤5 files
          moderate — spans multiple subsystems
          complex  — architectural impact or high risk

        Set state to "pending" — this marks the item as triaged and ready to fix.
      PROMPT
    end

    def extract_json_block(text)
      text[/---BEGIN JSON---\n(.*?)---END JSON---/m, 1]
    end
  end
end
