require "digest"
require "fileutils"
require "json"
require "tmpdir"

require_relative "intake/converter"

module Chomper
  # Stage 1 of the `pd` pipeline: pull raw human intent onto disk.
  #
  # No LLM involvement — this is a fetch, a conversion, and a hash. Documents
  # are read-only intake: humans write them in OpenProject, chomper reads them,
  # and nothing is ever written back.
  #
  # Output lands in the change's intake/ directory in the canonical store:
  #
  #   intake/001-recurring-meetings-concept.md    document body + frontmatter
  #   intake/attachments/README.md                what came in, and what didn't
  #   intake/attachments/001-meeting-patterns/*.csv
  class Intake
    include Helpers

    Result = Struct.new(:changed, :documents, :unconvertible, :hash, keyword_init: true) do
      def changed?
        changed
      end
    end

    def initialize(ctx, op: nil)
      @ctx = ctx
      @op  = op || Clients::OpenProject.new(ctx.op_url, ctx.token)
    end

    # Fetch the selected documents into `state`'s intake directory.
    #
    # `doc_ids` narrows a project-wide sweep to specific documents. Each is
    # verified to belong to `project_id` — the mandatory project argument is
    # what makes that check possible, and without it a typo would silently pull
    # a document from an unrelated project into this change's intake.
    #
    # Returns a Result; `changed?` is false when nothing moved since last time,
    # so the caller can stop rather than churn the store.
    def fetch(state, project_id:, doc_ids: [])
      docs = select_documents(project_id, doc_ids)
      raise Chomper::FatalError, "no documents found for project #{project_id}" if docs.empty?

      identity = intake_identity(docs, doc_ids)
      previous = state.tracker.dig("intake", "hash")
      return Result.new(changed: false, documents: docs, unconvertible: [], hash: identity) if previous == identity

      # The identity is computed once and carried through: recomputing it after
      # the write would have to be given the same doc_ids to produce the same
      # value, and getting that wrong stores a hash the next run can never match.
      write_intake(state, docs, identity)
    end

    private

    # Either every document in the project, or exactly the ones named. Both go
    # through #document so the payloads are shaped identically (the collection
    # representer is thinner than the single-document one).
    def select_documents(project_id, doc_ids)
      return fetch_named(project_id, doc_ids) if doc_ids.any?

      code, body = @op.documents(project_id)
      raise Chomper::FatalError, document_error(code, project_id) unless code == 200
      ids = (body&.dig("_embedded", "elements") || []).map { |d| d["id"] }
      ids.filter_map { |id| fetch_one(id) }
    end

    def fetch_named(project_id, doc_ids)
      doc_ids.map do |id|
        doc = fetch_one(id)
        raise Chomper::FatalError, "document #{id} not found (or not visible to this token)" unless doc

        actual = href_id(doc.dig("_links", "project", "href"))
        unless actual.to_s == project_id.to_s
          raise Chomper::FatalError,
                "document #{id} belongs to project #{actual || "(unknown)"}, not #{project_id} — " \
                "check the --doc-id, or run without it to sweep the whole project"
        end
        doc
      end
    end

    def fetch_one(id)
      code, body = @op.document(id)
      code == 200 ? body : nil
    end

    def document_error(code, project_id)
      case code
      when 404 then "the Documents module is not enabled on project #{project_id} " \
                    "(or the project does not exist) — enable it in the project settings"
      when 403 then "this OpenProject token lacks :view_documents on project #{project_id}"
      else "listing documents for project #{project_id} failed with HTTP #{code}"
      end
    end

    # sha256 over the sorted (id, updated_at) pairs AND the explicit --doc-id
    # selection. The selection has to be part of the identity: narrowing or
    # widening it changes the intake material even when no document was touched,
    # and without it a re-run with different --doc-ids would wrongly report
    # "no change" and leave the previous selection in place.
    def intake_identity(docs, doc_ids)
      pairs = docs.map { |d| [d["id"], d["updatedAt"] || d["updated_at"]] }.sort_by { |id, _| id.to_i }
      payload = { selection: doc_ids.map(&:to_s).sort, documents: pairs }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    def write_intake(state, docs, identity)
      dir = state.intake_dir
      FileUtils.rm_rf(dir.to_s) # mirror, don't merge: a dropped document must disappear
      (dir / "attachments").mkpath

      converted = docs.each_with_index.map do |doc, idx|
        ordinal = format("%03d", idx + 1)
        [doc, ordinal, write_attachments(doc, dir, ordinal)]
      end

      unconvertible = converted.flat_map do |doc, _ordinal, results|
        results.select(&:unconvertible?).map do |r|
          { "document" => doc["id"], "file" => r.file_name, "reason" => r.reason }
        end
      end

      entries = converted.map do |doc, ordinal, results|
        file = dir / "#{ordinal}-#{slug(doc["title"])}.md"
        file.write(document_markdown(doc, results))
        {
          "id" => doc["id"], "title" => doc["title"].to_s,
          "updated_at" => doc["updatedAt"] || doc["updated_at"],
          "file" => "intake/#{file.basename}"
        }
      end

      write_attachment_index(dir, entries, unconvertible)
      Result.new(changed: true, documents: docs, unconvertible: unconvertible, hash: identity)
    end

    # One markdown file per document: frontmatter carrying the provenance a
    # reviewer needs (which document, whose, when), then the body, then a
    # pointer to whatever its attachments became.
    def document_markdown(doc, results)
      converted = results.reject(&:unconvertible?)
      skipped   = results.select(&:unconvertible?)

      lines = ["---",
               "id: #{doc["id"]}",
               "title: #{doc["title"].to_s.inspect}",
               "updated_at: #{doc["updatedAt"] || doc["updated_at"]}",
               "---",
               "",
               "# #{doc["title"]}",
               "",
               description_text(doc).strip]

      if converted.any?
        lines.push("", "## Attachments", "")
        # Link paths come off the Result rather than being re-derived here: the
        # directory was named by the converter, and two independent slug calls
        # agreeing by hand is exactly how a link silently goes stale.
        converted.each { |r| r.links.each { |l| lines << "- `#{l}` — from #{r.file_name}" } }
      end
      if skipped.any?
        lines.push("", "## Attachments that could not be read", "")
        skipped.each { |r| lines << "- #{r.file_name} — #{r.reason}" }
      end
      "#{lines.join("\n").rstrip}\n"
    end

    # OpenProject formattable properties are { format:, raw:, html: }; raw is
    # the markdown a human typed, which is what we want.
    def description_text(doc)
      desc = doc["description"]
      return desc.to_s unless desc.is_a?(Hash)
      desc["raw"].to_s
    end

    def write_attachments(doc, dir, ordinal)
      code, body = @op.document_attachments(doc["id"])
      return [] unless code == 200
      elements = body&.dig("_embedded", "elements") || []
      return [] if elements.empty?

      Dir.mktmpdir do |tmp|
        elements.filter_map { |a| convert_attachment(a, dir, ordinal, tmp) }
      end
    end

    def convert_attachment(attachment, dir, ordinal, tmp)
      name = attachment["fileName"].to_s
      dest = dir / "attachments" / "#{ordinal}-#{slug(File.basename(name, ".*"))}"
      url  = attachment.dig("_links", "downloadLocation", "href")
      return Converter.unconvertible(name, "no download location", dir: dest) if url.to_s.empty?

      # The API reports fileSize, so an oversized attachment is rejected before
      # it is downloaded — otherwise a 200MB file costs a full transfer, 200MB
      # resident and a 200MB write just to produce an `unconvertible` entry.
      size = attachment["fileSize"].to_i
      return Converter.unconvertible(name, Converter.oversize_reason(size), dir: dest) if size > Converter::MAX_BYTES

      code, bytes = @op.download_attachment(url)
      return Converter.unconvertible(name, "download failed with HTTP #{code}", dir: dest) unless code == 200

      source = File.join(tmp, "attachment-#{attachment["id"]}")
      File.binwrite(source, bytes.to_s)
      Converter.convert(source, name, dest, content_type: attachment["contentType"])
    rescue StandardError => e
      # An attachment that cannot even be fetched is still just one attachment.
      Converter.unconvertible(attachment["fileName"].to_s, "#{e.class}: #{e.message}")
    end

    # A single index the propose prompt can point Claude at, and that a human
    # reviewing the proposal PR can scan to see whether anything was skipped.
    # Silence about a dropped attachment is the failure mode this prevents.
    def write_attachment_index(dir, entries, unconvertible)
      lines = ["# Intake attachments", "",
               "Generated by chomper. Converted from the OpenProject documents listed below.", ""]
      entries.each { |e| lines << "- Document ##{e["id"]} — #{e["title"]} (`#{e["file"]}`)" }

      if unconvertible.any?
        lines.push("", "## Could not be read (#{unconvertible.length})", "",
                   "These attachments were NOT converted. If a requirement lives in one of them,",
                   "it is missing from this intake — move it into the document body.", "")
        unconvertible.each { |u| lines << "- ##{u["document"]} `#{u["file"]}` — #{u["reason"]}" }
      else
        lines.push("", "All attachments were converted or passed through.")
      end
      (dir / "attachments" / "README.md").write("#{lines.join("\n")}\n")
    end

    def href_id(href)
      href.to_s[%r{/(\d+)\z}, 1]
    end

    def slug(str)
      Helpers.slugify(str, fallback: "document", limit: 50)
    end
  end
end
