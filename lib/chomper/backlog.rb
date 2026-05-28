require "json"
require "tempfile"
require "pathname"

module Chomper
  class Backlog
    STATE_UNTRIAGED = "untriaged"
    STATE_PENDING   = "pending"
    STATE_PLANNED   = "planned"
    STATE_COMMITTED = "committed"
    STATE_BLOCKED   = "blocked"

    def initialize(path)
      @path = Pathname(path)
      @data = nil
    end

    def exist?
      @path.exist?
    end

    def data
      @data ||= exist? ? JSON.parse(@path.read) : { "items" => [] }
    end

    def reload!
      @data = nil
    end

    def items
      data["items"]
    end

    def untriaged
      items.select { |i| i["state"] == STATE_UNTRIAGED }
    end

    def pending
      items.select { |i| i["state"] == STATE_PENDING }
    end

    def planned
      items.select { |i| i["state"] == STATE_PLANNED }
    end

    def committed
      items.select { |i| i["state"] == STATE_COMMITTED }
    end

    def blocked
      items.select { |i| i["state"] == STATE_BLOCKED }
    end

    def find(id)
      items.find { |i| i["id"] == id.to_s }
    end

    # Stage 1 pull: merge new items, preserving triage+fix fields for existing ones.
    def merge_new_items(new_items)
      existing = items.each_with_object({}) { |i, h| h[i["id"]] = i }
      merged = new_items.map do |item|
        prev = existing[item["id"]]
        if prev
          item.merge(
            "state"          => prev["state"],
            "locality_group" => prev["locality_group"],
            "complexity"     => prev["complexity"],
            "files_touched"  => prev["files_touched"],
            "ai_category"    => prev["ai_category"]
          )
        else
          item.merge("state" => STATE_UNTRIAGED)
        end
      end
      atomic_write("items" => merged)
    end

    # Stage 1 fetch-ids: full replace (items arrive as STATE_PENDING, ready to fix).
    def replace_with_new_items(new_items)
      atomic_write("items" => new_items)
    end

    # Stage 1 fetch-ids (append mode): upsert fetched items as PENDING, preserve everything else.
    def merge_fetched_items(new_items)
      existing  = items.each_with_object({}) { |i, h| h[i["id"]] = i }
      new_by_id = new_items.each_with_object({}) { |i, h| h[i["id"]] = i }

      kept  = existing.values.map { |item| new_by_id[item["id"]] || item }
      added = new_items.reject { |item| existing[item["id"]] }
      atomic_write("items" => kept + added)
    end

    def remove_items(ids)
      id_set = ids.map(&:to_s).to_set
      atomic_write("items" => items.reject { |i| id_set.include?(i["id"]) })
    end

    # Stage 2: patch locality_group, complexity, files_touched, ai_category, state.
    def merge_triage_results(triaged)
      index = triaged.each_with_object({}) { |t, h| h[t["id"]] = t }
      updated = items.map do |item|
        t = index[item["id"]]
        t ? item.merge(t) : item
      end
      atomic_write("items" => updated)
    end

    def sort_by_complexity!
      order = { "trivial" => 0, "simple" => 1, "moderate" => 2, "complex" => 3 }
      sorted = items.sort_by { |i| [order.fetch(i["complexity"].to_s, 4), i["locality_group"].to_s] }
      atomic_write("items" => sorted)
    end

    def set_state(id, value)
      updated = items.map do |i|
        i["id"] == id.to_s ? i.merge("state" => value) : i
      end
      atomic_write("items" => updated)
    end

    private

    def atomic_write(new_data)
      tmp = Tempfile.new("backlog", @path.dirname)
      tmp.write(JSON.generate(new_data))
      tmp.close
      File.rename(tmp.path, @path.to_s)
      reload!
    rescue
      tmp&.unlink
      raise
    end
  end
end
