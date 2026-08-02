require_relative "../../test_helper"
require_relative "../../support/ooxml_fixtures"
require "date"
require "tmpdir"

module Chomper
  class ConverterTest < Minitest::Test
    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @dest   = @tmpdir / "out"
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def convert(path, name = path.basename.to_s, content_type: nil)
      Intake::Converter.convert(path, name, @dest, content_type: content_type)
    end

    def test_xlsx_becomes_one_csv_per_sheet
      OOXMLFixtures.xlsx(@tmpdir / "b.xlsx", sheets: {
                           "Patterns" => [%w[pattern owner], %w[daily ana]],
                           "Glossary" => [%w[term meaning]]
                         })
      result = convert(@tmpdir / "b.xlsx", "meeting-patterns.xlsx")

      refute result.unconvertible?, result.reason
      assert_equal %w[patterns.csv glossary.csv], result.outputs
      assert_equal "pattern,owner\ndaily,ana\n", (@dest / "patterns.csv").read
    end

    def test_xlsx_date_cells_decode_to_iso_dates
      # Excel stores dates as serial numbers with a date format; getting this
      # wrong silently yields "46231" instead of a date, which is exactly the
      # class of bug that makes hand-rolling a spreadsheet parser a mistake.
      OOXMLFixtures.xlsx(@tmpdir / "d.xlsx",
                         sheets: { "S" => [["since"], [Date.new(2026, 7, 28)]] })
      convert(@tmpdir / "d.xlsx")
      assert_includes (@dest / "s.csv").read, "2026-07-28"
    end

    def test_xlsx_rows_are_capped_and_the_truncation_is_stated_in_the_file
      rows = [%w[a]] + Array.new(600) { |i| [i.to_s] }
      OOXMLFixtures.xlsx(@tmpdir / "big.xlsx", sheets: { "Big" => rows })
      result = convert(@tmpdir / "big.xlsx")

      lines = (@dest / "big.csv").read.lines
      assert_match(/\A# truncated: showing \d+ of 601 rows/, lines.first,
                   "a truncated sheet must say so in the file itself, not only in the log")
      assert_equal Intake::Converter::MAX_ROWS_PER_SHEET + 1, lines.length
      assert_match(/truncated/, result.note)
    end

    def test_docx_paragraphs_and_tables_become_markdown
      OOXMLFixtures.docx(@tmpdir / "n.docx",
                         paragraphs: ["Intro line", "Second line"],
                         table: [%w[col_a col_b], %w[1 2]])
      result = convert(@tmpdir / "n.docx", "rrule-notes.docx")

      refute result.unconvertible?, result.reason
      text = (@dest / "rrule-notes.md").read
      assert_includes text, "Intro line"
      assert_includes text, "| col_a | col_b |"
      assert_includes text, "| 1 | 2 |"
    end

    def test_pptx_slides_and_speaker_notes
      # Speaker notes frequently carry the actual reasoning, so they must not
      # be dropped just because they live in a separate part of the package.
      OOXMLFixtures.pptx(@tmpdir / "s.pptx",
                         slides: [["Title A", "a bullet"], ["Title B"]],
                         notes: { 1 => "the real reason" })
      result = convert(@tmpdir / "s.pptx", "deck.pptx")

      refute result.unconvertible?, result.reason
      text = (@dest / "deck.md").read
      assert_includes text, "## Slide 1"
      assert_includes text, "- a bullet"
      assert_includes text, "## Slide 2"
      assert_includes text, "**Speaker notes:** the real reason"
    end

    def test_legacy_binary_formats_are_reported_not_silently_dropped
      %w[old.xls old.doc old.ppt].each do |name|
        path = @tmpdir / name
        path.write("x")
        result = convert(path, name)
        assert result.unconvertible?, "#{name} should be unconvertible"
        assert_match(/legacy binary/, result.reason)
        assert_empty result.outputs
      end
    end

    def test_a_corrupt_archive_degrades_instead_of_raising
      OOXMLFixtures.corrupt_zip(@tmpdir / "bad.xlsx")
      result = convert(@tmpdir / "bad.xlsx", "bad.xlsx")
      assert result.unconvertible?
      refute_nil result.reason
    end

    def test_unknown_types_are_reported
      path = @tmpdir / "thing.dwg"
      path.write("binary")
      assert_match(/unsupported type \.dwg/, convert(path, "thing.dwg").reason)
    end

    def test_oversized_attachments_are_refused_before_parsing
      path = @tmpdir / "huge.xlsx"
      path.write("x" * (Intake::Converter::MAX_BYTES + 1))
      assert_match(/larger than/, convert(path, "huge.xlsx").reason)
    end

    def test_zip_with_too_many_entries_is_refused
      # Zip-bomb guard: an attachment is attacker-influenceable input parsed
      # inside the runner, which holds both API tokens.
      entries = (0..(Intake::Converter::MAX_ZIP_ENTRIES + 10)).to_h { |i| ["e#{i}.xml", "<a/>"] }
      OOXMLFixtures.zip_with(@tmpdir / "bomb.docx", entries)
      assert_match(/entries/, convert(@tmpdir / "bomb.docx", "bomb.docx").reason)
    end

    def test_text_and_pdf_pass_through_untouched
      %w[notes.md data.json spec.pdf shot.png].each do |name|
        path = @tmpdir / name
        path.write("payload-#{name}")
        result = convert(path, name)
        refute result.unconvertible?, result.reason
        assert_equal "payload-#{name}", (@dest / result.outputs.first).read
      end
    end

    def test_content_type_is_the_fallback_when_the_name_has_no_extension
      OOXMLFixtures.docx(@tmpdir / "noext", paragraphs: ["Body text"])
      result = convert(@tmpdir / "noext", "attachment",
                       content_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
      refute result.unconvertible?, result.reason
      assert_includes (@dest / result.outputs.first).read, "Body text"
    end

    def test_attachment_names_cannot_escape_the_destination
      path = @tmpdir / "evil.txt"
      path.write("payload")
      result = convert(path, "../../../etc/passwd.txt")
      refute result.unconvertible?, result.reason
      assert_equal [@dest / result.outputs.first], @dest.children
      refute_includes result.outputs.first, "/"
    end
  end
end
