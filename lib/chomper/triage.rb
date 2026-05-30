require "json"

module Chomper
  class Triage
    include Helpers
    BATCH_SIZE = 25

    def initialize(ctx, backlog, claude)
      @ctx     = ctx
      @backlog = backlog
      @claude  = claude
    end

    def run_triage_stage
      triage_items(@backlog.untriaged)
    end

    def run_triage_for_requested
      triage_items(@backlog.requested)
    end

    private

    def triage_items(items)
      return if items.empty?

      total_batches = (items.length.to_f / BATCH_SIZE).ceil
      puts "  #{items.length} issues · #{total_batches} batches of #{BATCH_SIZE}"

      items.each_slice(BATCH_SIZE).with_index(1) do |batch, batch_num|
        puts "  Batch #{batch_num} / #{total_batches}"

        text = @claude.run(build_prompt(batch))

        json_block = extract_json_block(text)
        if json_block.nil? || json_block.strip.empty?
          puts "  Warning: no JSON extracted for batch #{batch_num} — skipping."
          next
        end

        triaged = JSON.parse(json_block) rescue nil
        unless triaged.is_a?(Array)
          puts "  Warning: invalid JSON in batch #{batch_num} — skipping."
          next
        end

        @backlog.merge_triage_results(triaged)
      end

      @backlog.sort_by_complexity!
    end

    def build_prompt(batch)
      paths = batch.map { |item| "#{@ctx.state_container}/items/#{item["id"]}/item.json" }.join("\n")
      Prompts.triage(paths: paths)
    end

    def extract_json_block(text)
      text[/---BEGIN JSON---\n(.*?)---END JSON---/m, 1]
    end
  end
end
