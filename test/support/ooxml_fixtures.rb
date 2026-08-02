# Builders for the OOXML fixtures the intake converter is tested against.
#
# Generated rather than committed as binaries: the packages are small, and a
# builder makes it obvious what each test actually exercises (a date cell, a
# second sheet, a row count over the cap) instead of hiding it inside a blob.
require "zip"

module OOXMLFixtures
  module_function

  # A minimal but structurally complete .xlsx. roo validates the package, so
  # every part here is load-bearing — unlike .docx/.pptx below, where the
  # converter reads a single entry and needs no rels.
  #
  # `sheets` is { "Sheet name" => [[cell, cell], …] }. Values are written as
  # inline strings except Numeric (written as numbers) and Date (written as an
  # Excel serial with a date format, so the roo date decoding is exercised).
  def xlsx(path, sheets:)
    names = sheets.keys
    Zip::File.open(path.to_s, create: true) do |zip|
      zip.get_output_stream("[Content_Types].xml") { |f| f.write(content_types(names.length)) }
      zip.get_output_stream("_rels/.rels") { |f| f.write(root_rels) }
      zip.get_output_stream("xl/workbook.xml") { |f| f.write(workbook(names)) }
      zip.get_output_stream("xl/_rels/workbook.xml.rels") { |f| f.write(workbook_rels(names.length)) }
      zip.get_output_stream("xl/styles.xml") { |f| f.write(styles) }
      names.each_with_index do |name, i|
        zip.get_output_stream("xl/worksheets/sheet#{i + 1}.xml") { |f| f.write(sheet(sheets[name])) }
      end
    end
    path
  end

  def docx(path, paragraphs:, table: nil)
    body = paragraphs.map { |p| "<w:p><w:r><w:t>#{esc(p)}</w:t></w:r></w:p>" }.join
    body += table_xml(table) if table
    zip_with(path, "word/document.xml" => <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>#{body}</w:body>
      </w:document>
    XML
  end

  # `slides` is an array of arrays of strings; `notes` maps a 1-based slide
  # number to its speaker-note text.
  def pptx(path, slides:, notes: {})
    entries = {}
    slides.each_with_index do |texts, i|
      shapes = texts.map { |t| "<a:p><a:r><a:t>#{esc(t)}</a:t></a:r></a:p>" }.join
      entries["ppt/slides/slide#{i + 1}.xml"] = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
               xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <p:cSld><p:spTree>#{shapes}</p:spTree></p:cSld>
        </p:sld>
      XML
    end
    notes.each do |number, text|
      entries["ppt/notesSlides/notesSlide#{number}.xml"] = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <p:notes xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"
                 xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
          <a:p><a:r><a:t>#{esc(text)}</a:t></a:r></a:p>
        </p:notes>
      XML
    end
    zip_with(path, entries)
  end

  # A zip whose central directory is intact but whose payload is not — the
  # "corrupt attachment" case, which must degrade to unconvertible.
  def corrupt_zip(path)
    File.binwrite(path.to_s, "PK\x03\x04corrupted-not-really-a-zip")
    path
  end

  def zip_with(path, entries)
    Zip::File.open(path.to_s, create: true) do |zip|
      entries.each { |name, body| zip.get_output_stream(name) { |f| f.write(body) } }
    end
    path
  end

  # --- xlsx parts -------------------------------------------------------

  EPOCH = Date.new(1899, 12, 30) # Excel's serial-date origin

  def sheet(rows)
    body = rows.each_with_index.map do |row, r|
      cells = row.each_with_index.map do |value, c|
        ref = "#{("A".ord + c).chr}#{r + 1}"
        case value
        when Date    then %(<c r="#{ref}" s="1"><v>#{(value - EPOCH).to_i}</v></c>)
        when Numeric then %(<c r="#{ref}"><v>#{value}</v></c>)
        when nil     then ""
        else %(<c r="#{ref}" t="inlineStr"><is><t>#{esc(value)}</t></is></c>)
        end
      end.join
      %(<row r="#{r + 1}">#{cells}</row>)
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>#{body}</sheetData>
      </worksheet>
    XML
  end

  def workbook(names)
    sheets = names.each_with_index.map do |n, i|
      %(<sheet name="#{esc(n)}" sheetId="#{i + 1}" r:id="rId#{i + 1}"/>)
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>#{sheets}</sheets>
      </workbook>
    XML
  end

  def workbook_rels(count)
    rels = (1..count).map do |i|
      %(<Relationship Id="rId#{i}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet#{i}.xml"/>)
    end.join
    styles_id = count + 1
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        #{rels}
        <Relationship Id="rId#{styles_id}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      </Relationships>
    XML
  end

  def root_rels
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
      </Relationships>
    XML
  end

  def content_types(count)
    sheets = (1..count).map do |i|
      %(<Override PartName="/xl/worksheets/sheet#{i}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>)
    end.join
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        #{sheets}
      </Types>
    XML
  end

  # Style index 1 is a date format, which is how roo decides a numeric cell is
  # actually a date.
  def styles
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/></numFmts>
        <fonts count="1"><font/></fonts>
        <fills count="1"><fill/></fills>
        <borders count="1"><border/></borders>
        <cellStyleXfs count="1"><xf/></cellStyleXfs>
        <cellXfs count="2">
          <xf numFmtId="0" xfId="0"/>
          <xf numFmtId="164" xfId="0" applyNumberFormat="1"/>
        </cellXfs>
      </styleSheet>
    XML
  end

  def table_xml(rows)
    body = rows.map do |row|
      cells = row.map { |c| "<w:tc><w:p><w:r><w:t>#{esc(c)}</w:t></w:r></w:p></w:tc>" }.join
      "<w:tr>#{cells}</w:tr>"
    end.join
    "<w:tbl>#{body}</w:tbl>"
  end

  def esc(str)
    str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end
