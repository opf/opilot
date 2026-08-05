require "csv"
require "fileutils"
require "nokogiri"
require "pathname"
require "roo"
require "zip"

module Chomper
  module PD
    # Reopened by intake.rb, which defines the class proper — Converter is nested
    # inside it because it is only ever reached through an intake run.
    class Intake
      # Turns a document attachment into something Claude can actually read.
      # Claude's Read tool is the only way into the container (bash is read-only
      # git, egress is blocked), and it makes nothing of ZIP-of-XML
      # .xlsx/.docx/.pptx — so conversion happens here, in the runner.
      #
      # SECURITY: the one place chomper parses attacker-influenceable binary input
      # inside the trusted container (which holds both API tokens), since anyone
      # who can edit a document can attach a file. Hence the caps below and the
      # per-attachment rescue: a hostile or corrupt attachment must degrade to an
      # `unconvertible` entry, never take the run down or exhaust the host.
      module Converter
        module_function

        # Refuse anything implausible before it reaches a parser.
        MAX_BYTES            = 25 * 1024 * 1024   # a single attachment
        MAX_ZIP_ENTRIES      = 2_000              # zip-bomb: entry count
        MAX_UNCOMPRESSED     = 100 * 1024 * 1024  # zip-bomb: total inflated size
        MAX_ROWS_PER_SHEET   = 500                # context budget, not security
        MAX_COLS             = 60

        SPREADSHEET = %w[.xlsx .xlsm .ods].freeze
        PASSTHROUGH = %w[.pdf .md .txt .json .yml .yaml .xml .csv
                         .png .jpg .jpeg .gif .webp .svg].freeze
        # OLE compound documents. .xls would need roo-xls + spreadsheet, and
        # .doc/.ppt have no viable pure-Ruby reader — not worth the dependencies
        # until an `unconvertible` entry says otherwise.
        LEGACY_BINARY = %w[.xls .doc .ppt].freeze

        # One converted attachment. `outputs` are file names relative to `dir`,
        # which is the attachment directory's basename — carried here rather than
        # re-derived by the caller, so the directory the files were written to and
        # the markdown link pointing at them cannot drift apart. `reason` is set
        # only when the attachment could not be read.
        Result = Struct.new(:file_name, :dir, :outputs, :note, :reason, keyword_init: true) do
          def unconvertible?
            !reason.nil?
          end

          # Paths a document's markdown should link, relative to intake/.
          def links
            Array(outputs).map { |o| "attachments/#{dir}/#{o}" }
          end
        end

        # Convert `source` (raw bytes already on disk) into `dest_dir`.
        # Never raises: any failure comes back as a Result with a `reason`, so one
        # corrupt spreadsheet cannot abort an intake run.
        def convert(source, file_name, dest_dir, content_type: nil)
          source   = Pathname(source)
          dest_dir = Pathname(dest_dir)
          ext      = extension_for(file_name, content_type)

          return unconvertible(file_name, oversize_reason(source.size), dir: dest_dir) if source.size > MAX_BYTES
          if LEGACY_BINARY.include?(ext)
            return unconvertible(file_name, "legacy binary #{ext} — no pure-Ruby reader", dir: dest_dir)
          end

          dest_dir.mkpath
          case ext
          when *SPREADSHEET then convert_spreadsheet(source, file_name, dest_dir, ext)
          when ".docx"      then convert_docx(source, file_name, dest_dir)
          when ".pptx"      then convert_pptx(source, file_name, dest_dir)
          when *PASSTHROUGH then passthrough(source, file_name, dest_dir)
          else unconvertible(file_name, "unsupported type #{ext.empty? ? content_type.to_s : ext}", dir: dest_dir)
          end
        rescue StandardError => e
          # Deliberately broad: a malformed OOXML file can raise almost anything
          # out of Zip/Nokogiri/Roo, and none of it should reach the caller.
          unconvertible(file_name, "#{e.class}: #{e.message}", dir: dest_dir)
        end

        # Shared with Intake, which checks the size the API reports before spending
        # a download on a file it is going to reject anyway.
        def oversize_reason(bytes)
          "larger than #{MAX_BYTES / 1024 / 1024}MB (#{bytes} bytes)"
        end

        # --- spreadsheets ----------------------------------------------------

        # One CSV per sheet rather than one markdown blob: greppable, compact, and
        # Claude can read a single sheet instead of pulling thousands of rows into
        # context. roo handles the parts that are genuinely easy to get wrong —
        # sharedStrings indirection, inline vs shared strings, cell-type coercion,
        # and Excel's serial-date encoding.
        def convert_spreadsheet(source, file_name, dest_dir, ext)
          with_zip(source) { |_zip| } # xlsx/xlsm/ods are all zip: guard before Roo parses
          book    = Roo::Spreadsheet.open(source.to_s, extension: ext.delete_prefix(".").to_sym)
          outputs = []
          notes   = []

          book.sheets.each do |sheet_name|
            book.default_sheet = sheet_name
            rows, total = sheet_rows(book)
            next if rows.empty?

            note = truncation_note(rows.length, total)
            out  = dest_dir / "#{Helpers.slugify(sheet_name, fallback: "sheet")}.csv"
            CSV.open(out.to_s, "w") do |csv|
              csv << ["# #{note}"] if note
              rows.each { |row| csv << row }
            end
            notes << "#{sheet_name}: #{note}" if note
            outputs << out.basename.to_s
          end

          return unconvertible(file_name, "no non-empty sheets", dir: dest_dir) if outputs.empty?
          summary = "#{outputs.length} sheet#{"s" if outputs.length != 1}"
          result(file_name, dest_dir, outputs, ([summary] + notes).join("; "))
        end

        # Stated in the CSV itself, not only in the log: whoever reads the file has
        # to be able to see that it was cut off.
        def truncation_note(shown, total)
          if total && total > shown then "truncated: showing #{shown} of #{total} rows"
          elsif shown >= MAX_ROWS_PER_SHEET then "truncated: showing the first #{shown} rows"
          end
        end

        # Rows as arrays of scalars, capped. Returns [rows, total_or_nil] — the
        # total is only known when roo can report it cheaply, so a truncation note
        # says "of N" when it can and stays vague when it can't rather than lying.
        def sheet_rows(book)
          total = begin
            book.last_row
          rescue StandardError
            nil
          end

          rows = []
          if book.respond_to?(:each_row_streaming)
            book.each_row_streaming(max_rows: MAX_ROWS_PER_SHEET - 1, pad_cells: true) do |row|
              rows << row.first(MAX_COLS).map { |c| cell_value(c) }
            end
          else
            first = book.first_row.to_i
            last  = [total.to_i, first + MAX_ROWS_PER_SHEET - 1].min
            (first..last).each { |i| rows << book.row(i).first(MAX_COLS).map { |c| cell_value(c) } }
          end
          rows.pop while rows.any? && rows.last.all? { |v| v.to_s.strip.empty? }
          [rows, total]
        end

        def cell_value(cell)
          value = cell.respond_to?(:value) ? cell.value : cell
          case value
          when nil            then ""
          when Date, DateTime then value.iso8601
          when Time           then value.utc.iso8601
          when Float          then value == value.to_i ? value.to_i.to_s : value.to_s
          else value.to_s
          end
        end

        # --- OOXML text (docx / pptx) ----------------------------------------
        #
        # Hand-rolled rather than gem-backed: text extraction is ~40 lines against
        # rubyzip + nokogiri, which roo has already pulled in, and no maintained
        # Ruby gem reads .pptx at all — so a docx gem would add a dependency,
        # still leave a hole, and duplicate this code path anyway.

        def convert_docx(source, file_name, dest_dir)
          xml = with_zip(source) { |zip| entry_text(zip, "word/document.xml") }
          return unconvertible(file_name, "no word/document.xml — not a .docx?", dir: dest_dir) unless xml

          body = parse_xml(xml).at_xpath("//body")
          return unconvertible(file_name, "no document body", dir: dest_dir) unless body

          lines = body.elements.filter_map do |node|
            case node.name
            when "p"   then paragraph_text(node)
            when "tbl" then table_markdown(node)
            end
          end.reject { |l| l.to_s.strip.empty? }

          write_markdown(file_name, dest_dir, lines, "no readable text")
        end

        def convert_pptx(source, file_name, dest_dir)
          lines = with_zip(source) do |zip|
            slides = zip.map(&:name)
                        .grep(%r{\Appt/slides/slide\d+\.xml\z})
                        .sort_by { |name| name[/\d+/].to_i }
            slides.empty? ? nil : slides.each_with_index.flat_map { |entry, idx| slide_lines(zip, entry, idx) }
          end
          return unconvertible(file_name, "no slides — not a .pptx?", dir: dest_dir) if lines.nil?

          write_markdown(file_name, dest_dir, lines, "no readable text in any slide")
        end

        # Speaker notes live in a separate part of the package and frequently carry
        # the actual reasoning, so they are pulled in alongside the slide body.
        def slide_lines(zip, entry, index)
          lines = ["## Slide #{index + 1}"]
          lines.concat(text_nodes(entry_text(zip, entry)).map { |t| "- #{t}" })
          notes = text_nodes(entry_text(zip, "ppt/notesSlides/notesSlide#{entry[/\d+/]}.xml"))
          lines.push("", "**Speaker notes:** #{notes.join(" ")}") if notes.any?
          lines << ""
        end

        def write_markdown(file_name, dest_dir, lines, empty_reason)
          return unconvertible(file_name, empty_reason, dir: dest_dir) if lines.all? { |l| l.to_s.strip.empty? }
          out = dest_dir / "#{Helpers.slugify(File.basename(file_name, ".*"), fallback: "document")}.md"
          out.write("#{lines.join("\n").strip}\n")
          result(file_name, dest_dir, [out.basename.to_s], "#{lines.length} lines")
        end

        # Every <t> in document order. remove_namespaces! means <w:t> and <a:t>
        # both reduce to <t>, which is exactly the text we want out of both formats.
        def text_nodes(xml)
          return [] unless xml
          parse_xml(xml).xpath("//t").map { |n| n.text.strip }.reject(&:empty?)
        end

        def parse_xml(xml)
          doc = Nokogiri::XML(xml)
          doc.remove_namespaces!
          doc
        end

        def paragraph_text(node)
          node.xpath(".//t").map(&:text).join.strip
        end

        def table_markdown(node)
          rows = node.xpath("./tr").map do |tr|
            tr.xpath("./tc").map { |tc| tc.xpath(".//t").map(&:text).join.strip.gsub("|", "\\|") }
          end
          return nil if rows.empty?
          header, *body = rows
          width = rows.map(&:length).max
          out = ["| #{header.fill("", header.length...width).join(" | ")} |",
                 "|#{" --- |" * width}"]
          body.each { |r| out << "| #{r.fill("", r.length...width).join(" | ")} |" }
          "#{out.join("\n")}\n"
        end

        # --- passthrough / helpers -------------------------------------------

        def passthrough(source, file_name, dest_dir)
          out = dest_dir / safe_file_name(file_name)
          FileUtils.cp(source.to_s, out.to_s)
          result(file_name, dest_dir, [out.basename.to_s], "passed through")
        end

        def result(file_name, dest_dir, outputs, note)
          Result.new(file_name: file_name, dir: Pathname(dest_dir).basename.to_s,
                     outputs: outputs, note: note)
        end

        def unconvertible(file_name, reason, dir: nil)
          Result.new(file_name: file_name, dir: dir && Pathname(dir).basename.to_s,
                     outputs: [], reason: reason)
        end

        # Open the archive ONCE, validate it, and hand the open handle to the block.
        # Every read goes through here: opening per entry meant a 40-slide deck paid
        # ~160 opens and ~80 full central-directory scans to extract 80 XML parts.
        #
        # The guard rejects a zip bomb before anything inflates it. rubyzip's own
        # validate_entry_sizes catches a lying local header; the caps here catch the
        # honest-but-hostile case of a small archive that inflates enormously.
        def with_zip(source)
          Zip.validate_entry_sizes = true
          Zip::File.open(source.to_s) do |zip|
            raise "archive has #{zip.size} entries (max #{MAX_ZIP_ENTRIES})" if zip.size > MAX_ZIP_ENTRIES
            total = 0
            zip.each do |entry|
              total += entry.size.to_i
              raise "archive inflates to over #{MAX_UNCOMPRESSED / 1024 / 1024}MB" if total > MAX_UNCOMPRESSED
            end
            yield zip
          end
        end

        def entry_text(zip, name)
          zip.find_entry(name)&.get_input_stream&.read
        end

        def extension_for(file_name, content_type)
          ext = File.extname(file_name.to_s).downcase
          return ext unless ext.empty?
          case content_type.to_s
          when %r{spreadsheetml}      then ".xlsx"
          when %r{wordprocessingml}   then ".docx"
          when %r{presentationml}     then ".pptx"
          when %r{^application/pdf}   then ".pdf"
          when %r{^text/csv}          then ".csv"
          when %r{^text/}             then ".txt"
          when %r{^image/}            then ".png"
          else ""
          end
        end

        # Keep the extension, sanitise the stem — the name comes from an upload
        # and must never escape dest_dir.
        def safe_file_name(file_name)
          ext = File.extname(file_name.to_s).downcase
          "#{Helpers.slugify(File.basename(file_name.to_s, ".*"), fallback: "attachment")}#{ext}"
        end
      end
    end
  end
end
