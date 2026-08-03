require_relative "../test_helper"
require "tmpdir"

module Chomper
  class IntakeTest < Minitest::Test
    # Stands in for Clients::OpenProject. Documents are keyed by id; each may
    # carry attachments as [{name:, content_type:, body:}].
    class FakeOP
      attr_reader :downloads, :filtered_by
      # Report a size over the cap without materialising a 25MB fixture.
      attr_accessor :oversize

      # `identifiers` maps a project identifier to its numeric id, standing in
      # for the /projects/<identifier> lookup the real client memoizes.
      def initialize(docs: {}, list: nil, list_code: 200, identifiers: {})
        @docs = docs
        @list = list
        @list_code = list_code
        @identifiers = identifiers
        @downloads = []
      end

      def project_numeric_id(project_id)
        return [200, project_id.to_i] if project_id.to_s.match?(/\A\d+\z/)
        id = @identifiers[project_id.to_s]
        id ? [200, id] : [404, nil]
      end

      def documents(project_id, page: 1, page_size: 100)
        @filtered_by = project_id
        return [@list_code, nil] unless @list_code == 200
        ids = (@list || @docs.keys).map { |id| { "id" => id } }
        [200, { "_embedded" => { "elements" => ids } }]
      end

      def document(id)
        doc = @docs[id.to_i] || @docs[id.to_s]
        doc ? [200, doc] : [404, nil]
      end

      def document_attachments(id)
        doc = @docs[id.to_i] || @docs[id.to_s]
        elements = (doc&.dig("__attachments") || []).each_with_index.map do |a, i|
          { "id" => "#{id}-#{i}", "fileName" => a[:name], "contentType" => a[:content_type],
            "fileSize" => @oversize ? Chomper::Intake::Converter::MAX_BYTES + 1 : a[:body].bytesize,
            "_links" => { "downloadLocation" => { "href" => "https://op.test/dl/#{id}-#{i}" } } }
        end
        [200, { "_embedded" => { "elements" => elements } }]
      end

      def download_attachment(url)
        @downloads << url
        id = url.split("/").last
        doc_id, idx = id.split("-")
        doc = @docs[doc_id.to_i]
        [200, doc["__attachments"][idx.to_i][:body]]
      end
    end

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @ctx    = Context.build(@tmpdir)
      @repo   = @ctx.default_repo
      (@repo.worktree_host / ".git" / "info").mkpath
      @store  = ChangeStore.new(@ctx, @repo)
      (@store.tree / "changes").mkpath
      (@store.tree / "config.yaml").write("schema: spec-driven\n")
      @state  = ChangeState.new(change_id: "add-recurring-meetings",
                                store: @store, state_dir: @tmpdir / "s")
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def doc(id, title:, project: "42", updated: "2026-07-28T09:12:00Z", body: "Body text", attachments: [])
      { "id" => id, "title" => title, "updatedAt" => updated,
        "description" => { "format" => "markdown", "raw" => body },
        "_links" => { "project" => { "href" => "/api/v3/projects/#{project}" } },
        "__attachments" => attachments }
    end

    def test_project_sweep_writes_one_ordinal_file_per_document
      op = FakeOP.new(docs: { 118 => doc(118, title: "Recurring meetings — concept"),
                              119 => doc(119, title: "Data model") })
      result = Intake.new(@ctx, op: op).fetch(@state, project_id: "42")

      assert result.changed?
      files = @state.intake_dir.children.select(&:file?).map { |f| f.basename.to_s }.sort
      assert_equal ["001-recurring-meetings-concept.md", "002-data-model.md"], files
      text = (@state.intake_dir / "001-recurring-meetings-concept.md").read
      assert_includes text, "id: 118"
      assert_includes text, "updated_at: 2026-07-28T09:12:00Z"
      assert_includes text, "Body text"
    end

    def test_doc_id_narrows_the_selection
      op = FakeOP.new(docs: { 118 => doc(118, title: "Wanted"), 119 => doc(119, title: "Unwanted") })
      Intake.new(@ctx, op: op).fetch(@state, project_id: "42", doc_ids: ["118"])

      files = @state.intake_dir.children.select(&:file?).map { |f| f.basename.to_s }
      assert_equal ["001-wanted.md"], files
    end

    def test_doc_id_from_another_project_is_rejected
      # The mandatory project argument is what makes this check possible; a typo
      # would otherwise pull an unrelated project's document into this change.
      op = FakeOP.new(docs: { 118 => doc(118, title: "Elsewhere", project: "99") })
      error = assert_raises(Chomper::FatalError) do
        Intake.new(@ctx, op: op).fetch(@state, project_id: "42", doc_ids: ["118"])
      end
      assert_match(/belongs to project 99, not 42/, error.message)
    end

    def test_unchanged_documents_short_circuit
      op = FakeOP.new(docs: { 118 => doc(118, title: "Concept") })
      intake = Intake.new(@ctx, op: op)

      first = intake.fetch(@state, project_id: "42")
      assert first.changed?
      @state.merge_tracker("intake" => { "hash" => first.hash })

      assert_equal false, intake.fetch(@state, project_id: "42").changed?
    end

    def test_an_unchanged_doc_id_selection_short_circuits
      # Regression: the stored hash and the compared hash must be computed from
      # the SAME selection. Computing the stored one with an empty selection made
      # every --doc-id run re-fetch forever, while still passing a test that only
      # checked that a *different* selection re-fetches.
      op = FakeOP.new(docs: { 118 => doc(118, title: "A"), 119 => doc(119, title: "B") })
      intake = Intake.new(@ctx, op: op)

      first = intake.fetch(@state, project_id: "42", doc_ids: %w[118])
      assert first.changed?
      @state.merge_tracker("intake" => { "hash" => first.hash })

      again = intake.fetch(@state, project_id: "42", doc_ids: %w[118])
      assert_equal false, again.changed?, "the same selection, unchanged, must not re-fetch"
      assert_equal first.hash, again.hash
    end

    def test_a_changed_doc_id_selection_defeats_the_hash
      # Narrowing or widening the selection changes the intake material even
      # when no document was touched, so it must not report "no change".
      op = FakeOP.new(docs: { 118 => doc(118, title: "A"), 119 => doc(119, title: "B") })
      intake = Intake.new(@ctx, op: op)

      wide = intake.fetch(@state, project_id: "42", doc_ids: %w[118 119])
      @state.merge_tracker("intake" => { "hash" => wide.hash })

      narrow = intake.fetch(@state, project_id: "42", doc_ids: %w[118])
      assert narrow.changed?, "a different selection is a different intake"
      refute_equal wide.hash, narrow.hash
    end

    def test_an_updated_document_defeats_the_hash
      op = FakeOP.new(docs: { 118 => doc(118, title: "A", updated: "2026-07-01T00:00:00Z") })
      first = Intake.new(@ctx, op: op).fetch(@state, project_id: "42")
      @state.merge_tracker("intake" => { "hash" => first.hash })

      moved = FakeOP.new(docs: { 118 => doc(118, title: "A", updated: "2026-08-02T00:00:00Z") })
      assert Intake.new(@ctx, op: moved).fetch(@state, project_id: "42").changed?
    end

    def test_attachments_are_converted_and_indexed
      xlsx = @tmpdir / "book.xlsx"
      require_relative "../support/ooxml_fixtures"
      OOXMLFixtures.xlsx(xlsx, sheets: { "Patterns" => [%w[pattern owner], %w[daily ana]] })

      op = FakeOP.new(docs: { 118 => doc(118, title: "Concept", attachments: [
                                { name: "meeting-patterns.xlsx", content_type: "application/vnd…", body: xlsx.binread }
                              ]) })
      result = Intake.new(@ctx, op: op).fetch(@state, project_id: "42")

      assert_empty result.unconvertible
      csv = @state.intake_dir / "attachments" / "001-meeting-patterns" / "patterns.csv"
      assert csv.exist?, "an xlsx attachment must arrive as readable CSV"
      assert_includes csv.read, "daily,ana"
      assert_includes (@state.intake_dir / "attachments" / "README.md").read, "All attachments were converted"

      # The markdown link must point at the directory the converter actually
      # wrote to — the two used to be derived by separate slug calls that agreed
      # only by hand.
      link = (@state.intake_dir / "001-concept.md").read[%r{`(attachments/\S+?)`}, 1]
      assert link, "the document markdown should link its converted attachments"
      assert (@state.intake_dir / link).exist?, "link #{link.inspect} points at nothing"
    end

    def test_oversized_attachments_are_rejected_without_downloading
      op = FakeOP.new(docs: { 118 => doc(118, title: "Concept", attachments: [
                                { name: "huge.xlsx", content_type: "application/vnd…", body: "x" }
                              ]) })
      op.oversize = true
      result = Intake.new(@ctx, op: op).fetch(@state, project_id: "42")

      assert_equal 1, result.unconvertible.length
      assert_match(/larger than/, result.unconvertible.first["reason"])
      assert_empty op.downloads, "the reported fileSize should short-circuit before the transfer"
    end

    def test_unreadable_attachments_are_surfaced_not_dropped
      # A requirement hiding in an unreadable file is MISSING from the intake;
      # silence about it is the failure mode this guards.
      op = FakeOP.new(docs: { 118 => doc(118, title: "Concept", attachments: [
                                { name: "legacy.xls", content_type: "application/vnd.ms-excel", body: "junk" }
                              ]) })
      result = Intake.new(@ctx, op: op).fetch(@state, project_id: "42")

      assert_equal 1, result.unconvertible.length
      assert_equal "legacy.xls", result.unconvertible.first["file"]
      readme = (@state.intake_dir / "attachments" / "README.md").read
      assert_includes readme, "Could not be read (1)"
      assert_includes readme, "legacy.xls"
      # This file is committed to the spec branch, so GitHub renders it — a bare
      # "#118" would autolink to an unrelated pull request.
      assert_includes readme, "(#{@ctx.op_url}/documents/118)"
      refute_match(/^- #118 /, readme)
      assert_includes (@state.intake_dir / "001-concept.md").read, "could not be read"
    end

    def test_missing_documents_module_reports_a_useful_error
      op = FakeOP.new(docs: {}, list_code: 404)
      error = assert_raises(Chomper::FatalError) { Intake.new(@ctx, op: op).fetch(@state, project_id: "42") }
      assert_match(/Documents module is not enabled/, error.message)
    end

    def test_forbidden_documents_reports_the_missing_permission
      op = FakeOP.new(docs: {}, list_code: 403)
      error = assert_raises(Chomper::FatalError) { Intake.new(@ctx, op: op).fetch(@state, project_id: "42") }
      assert_match(/view_documents/, error.message)
    end

    def test_project_identifier_is_resolved_to_the_numeric_id
      # The documents filter coerces its values to integers, so an identifier
      # would match nothing and the sweep would come back silently empty.
      op = FakeOP.new(docs: { 118 => doc(118, title: "Concept") }, identifiers: { "my-project" => 42 })
      result = Intake.new(@ctx, op: op).fetch(@state, project_id: "my-project")

      assert_equal 42, op.filtered_by
      assert_equal 1, result.documents.length
    end

    def test_doc_id_ownership_is_checked_against_the_resolved_numeric_id
      op = FakeOP.new(docs: { 118 => doc(118, title: "Wanted", project: "42") },
                      identifiers: { "my-project" => 42 })
      Intake.new(@ctx, op: op).fetch(@state, project_id: "my-project", doc_ids: %w[118])

      assert (@state.intake_dir / "001-wanted.md").exist?,
             "a document's project href carries the numeric id, not the identifier"
    end

    def test_unresolvable_project_reports_a_useful_error
      op = FakeOP.new(docs: {})
      error = assert_raises(Chomper::FatalError) do
        Intake.new(@ctx, op: op).fetch(@state, project_id: "no-such-project")
      end
      assert_match(/project no-such-project is not readable \(HTTP 404\)/, error.message)
    end

    def test_reintake_drops_documents_no_longer_selected
      op = FakeOP.new(docs: { 118 => doc(118, title: "A"), 119 => doc(119, title: "B") })
      Intake.new(@ctx, op: op).fetch(@state, project_id: "42")
      assert (@state.intake_dir / "002-b.md").exist?

      Intake.new(@ctx, op: op).fetch(@state, project_id: "42", doc_ids: %w[118])
      refute (@state.intake_dir / "002-b.md").exist?,
             "intake mirrors the selection; a dropped document must not linger"
    end
  end
end
