module OPilot
  module Helpers
    # Parsers for the delimited answers the prompts ask for: OPTIONS, the
    # BEGIN/END WORK PACKAGE, HEALTH and ARTIFACT blocks, and the trailing
    # markers. Each lives beside the text that corrects a miss of it.

    # ── implementation options ──────────────────────────────────────────────
    #
    # A plan call may answer with implementation options instead of a plan (see
    # Prompts::Planner::OPTIONS_CONTRACT). Both readers of that answer live here — the
    # agent, which offers the options in a work-package comment, and the terminal
    # runner, which offers them at the console — so the parsing and the wording of
    # a chosen option are written once.

    # One pipe-delimited option line's fields, or nil when the line doesn't
    # match — shared by parse_options and parse_leading_options below.
    def self.parse_option_line(line)
      fields = line.to_s.split("|").map(&:strip)
      return nil unless fields.length >= 3
      number = fields[0][/\d+/]
      return nil unless number
      { "n" => number.to_i, "title" => fields[1], "summary" => fields[2],
        "repos" => fields[3].to_s.split(",").map(&:strip).reject(&:empty?),
        "size" => fields[4].to_s }
    end

    # Read the OPTIONS block: one pipe-delimited line per option. Lines that do
    # not parse are dropped, so a stray sentence around the block costs nothing,
    # and a duplicate number keeps its first line — the numbers are what a reader
    # answers with. Used for the stops-after-options answer, where nothing but
    # option lines is expected anywhere in the body.
    def self.parse_options(body)
      body.to_s.lines.filter_map { |line| parse_option_line(line) }
        .uniq { |o| o["n"] }.sort_by { |o| o["n"] }
    end

    # Whether `text` answers with OPTIONS (Prompts::Planner::OPTIONS_CONTRACT) — tolerant
    # of a preamble sentence before the sentinel line, the same accommodation
    # #record_chosen_repos' REPOS: match already makes and the NEEDS_INFO check
    # below makes too: a local model in particular often reasons in prose before
    # it reaches the actual marker ("I have enough from the issue... OPTIONS").
    # Requires the sentinel ALONE on its own line, so an ordinary sentence that
    # happens to use the word "options" is never mistaken for the block.
    def self.options_sentinel?(text)
      text.to_s.lines.any? { |l| l.strip == Prompts::Planner::OPTIONS_SENTINEL }
    end

    # The questions after a leading NEEDS_INFO sentinel, or nil when the answer
    # does not open with one.
    def self.needs_info(text)
      return nil unless text.to_s.lstrip.start_with?("NEEDS_INFO")
      text.sub(/\A\s*NEEDS_INFO\s*\n?/, "").strip
    end

    # Split a writer's answer into its OPTIONS line(s) and whatever follows
    # (Prompts::Planner::OPTIONS_CONTRACT: name the approach, then — when there's only
    # one — continue straight into the plan in the same response). The
    # sentinel is found anywhere, per #options_sentinel? above, and everything
    # before and including it is dropped along with it — a preamble sentence
    # is not part of the contract's answer, the same as a NEEDS_INFO preamble
    # is dropped where it is read. From there, only CONTIGUOUS option lines are
    # consumed: a plan can itself contain pipe-delimited markdown table rows,
    # which a tolerant scan like parse_options' would misread as more options.
    def self.parse_leading_options(body)
      lines = body.to_s.lines
      start = lines.index { |l| l.strip == Prompts::Planner::OPTIONS_SENTINEL }
      return [[], body.to_s.lstrip] unless start
      lines = lines[(start + 1)..] || []
      options = []
      while (parsed = parse_option_line(lines.first))
        options << parsed
        lines.shift
      end
      [options.uniq { |o| o["n"] }.sort_by { |o| o["n"] }, lines.join.lstrip]
    end

    WP_BEGIN     = /\A[ \t]*BEGIN WORK PACKAGE[ \t]*\z/
    WP_END       = /\A[ \t]*END WORK PACKAGE[ \t]*\z/
    SUBJECT_LINE = /\ASUBJECT:[ \t]*(.+)\z/i
    TYPE_LINE    = /\ATYPE:[ \t]*(.+)\z/i
    LINK_LINE    = /\ALINK:[ \t]*(.+)\z/i
    FENCE_LINE   = /\A[ \t]*(`{3,}|~{3,})/

    # How a new work package hangs off the one that asked for it. "child" is the
    # only value that makes it one; everything else, including a missing LINK
    # line, is a peer. The default is deliberately the conservative direction:
    # OpenProject derives a parent's dates and progress from its children, so a
    # child link CHANGES the source work package, while a relation does not.
    WP_LINKS        = %w[child related].freeze
    DEFAULT_WP_LINK = "related".freeze

    # Read the work packages a `create wp` answer asks for (Prompts::WpWriter.create_wp).
    # Each one is a block — BEGIN WORK PACKAGE, a SUBJECT: line, an optional
    # TYPE: and LINK: line, the description, END WORK PACKAGE — and a request
    # that names several pieces of work answers with several blocks, in order.
    #
    # Returns [] when the answer holds no usable block, which the caller treats
    # as unusable: one bounded retry, then it gives up. That is safe precisely
    # because nothing is created yet, and it must stay strict, because a work
    # package cannot be deleted and so a block opilot half-understands must
    # never reach the POST.
    #
    # Three rules do the work:
    #
    # - BOTH marker lines are required, each alone on its line. An unclosed
    #   block means the answer was CUT OFF — all N blocks share one output
    #   budget, so a truncated last block is the real failure mode here, and
    #   without the end marker it would be created as a work package with half a
    #   description. One unclosed block rejects the whole answer.
    # - Marker lines inside a fenced code block are text. A description quotes
    #   the thread, so it can contain anything — including a comment somebody
    #   pasted opilot's own answer into. PD::TasksFile learned the same lesson
    #   with an example `##` heading.
    # - Text between blocks is ignored. Narration between blocks is harmless;
    #   only what sits INSIDE one becomes a work package.
    def self.parse_work_packages(body)
      blocks = []
      open   = nil
      fence  = nil
      body.to_s.lines.each do |raw|
        line  = raw.chomp
        fence = fence_state(fence, line)
        # Inside a fence: description text, whatever it says.
        next open&.<<(line) unless fence.nil?

        if line.match?(WP_BEGIN)
          # A second BEGIN with no END between: the first block is unterminated,
          # which is the same broken answer as a truncated one.
          return [] if open
          open = []
        elsif line.match?(WP_END)
          return [] unless open
          blocks << open
          open = nil
        else
          open&.<<(line)
        end
      end
      return [] if open   # cut off mid-block
      blocks.filter_map { |block| work_package_fields(block) }
    end

    # Whether this line leaves us inside a fenced code block, and in which
    # fence. Nil means outside.
    def self.fence_state(fence, line)
      marker = line[FENCE_LINE, 1] or return fence
      return marker[0] if fence.nil?
      marker.start_with?(fence) ? nil : fence
    end
    private_class_method :fence_state

    # One block's fields. Only the LEADING lines are read as fields, so a
    # description that discusses a "SUBJECT:" line of its own cannot move the
    # subject. A block with no subject is dropped rather than guessed at.
    #
    # SUBJECT, TYPE and LINK are one header and are read in ANY order: a writer
    # that swaps two of them has still said everything, and rejecting it costs a
    # whole retry call (a local model swapped SUBJECT and TYPE on a real
    # `appsignal fix` run). TYPE and LINK stay optional.
    def self.work_package_fields(lines)
      lines  = lines.drop_while { |l| l.strip.empty? }
      fields = {}
      loop do
        line = lines.first.to_s
        if (subject = line[SUBJECT_LINE, 1])
          fields["subject"] ||= subject.strip
        elsif (type = line[TYPE_LINE, 1])
          fields["type"] ||= type.strip
        elsif (link = line[LINK_LINE, 1])
          fields["link"] ||= link.strip
        else
          break
        end
        lines = lines.drop(1)
      end
      return nil if fields["subject"].to_s.empty?

      link = fields["link"].to_s.downcase
      { "subject"     => fields["subject"],
        "type"        => fields["type"].to_s,
        "link"        => WP_LINKS.include?(link) ? link : DEFAULT_WP_LINK,
        "description" => lines.join("\n").strip }
    end
    private_class_method :work_package_fields

    HEALTH_BEGIN = /\A[ \t]*BEGIN HEALTH[ \t]*\z/
    HEALTH_END   = /\A[ \t]*END HEALTH[ \t]*\z/
    HEALTH_FINDING_LINE = /\A[ \t]*FINDING:[ \t]*(.+)\z/i
    HEALTH_GAP_LINE     = /\A[ \t]*GAP:[ \t]*(.+)\z/i
    HEALTH_CLEAN_LINE   = /\A[ \t]*NO FINDINGS[ \t.]*\z/i

    # Read a health answer (Prompts::Auditor::HEALTH_CONTRACT) into
    # { "findings" => [...], "gaps" => [...] }, or nil when there is no complete
    # block — the answer was cut off, or ignored the format. The LAST complete
    # block wins, so a format the writer rehearsed first does not count. A
    # malformed line drops only itself; so does a finding with no evidence.
    def self.parse_health(body)
      block = nil
      open  = nil
      fence = nil
      body.to_s.lines.each do |raw|
        line  = raw.chomp
        fence = fence_state(fence, line)
        next unless fence.nil?

        if line.match?(HEALTH_BEGIN) then open = []
        elsif line.match?(HEALTH_END)
          block = open if open
          open = nil
        else open&.<<(line)
        end
      end
      return nil unless block

      findings = block.filter_map { |l| health_finding(l[HEALTH_FINDING_LINE, 1]) }
      gaps = block.filter_map do |l|
        what, why = l[HEALTH_GAP_LINE, 1]&.split("|", 2)&.map(&:strip)
        { "what" => what, "why" => why.to_s } unless what.to_s.empty?
      end
      readable = findings.any? || gaps.any? ||
                 block.any? { |l| l.match?(HEALTH_CLEAN_LINE) || l.match?(HEALTH_FINDING_LINE) }
      return nil unless readable
      { "findings" => findings.first(Prompts::Auditor::HEALTH_MAX_FINDINGS), "gaps" => gaps }
    end

    def self.health_finding(text)
      return nil unless text
      severity, area, sentence, evidence = text.split("|", 4).map { |f| f.to_s.strip }
      severity = severity.downcase
      area     = area.to_s.downcase
      return nil unless Prompts::Auditor::HEALTH_SEVERITIES.include?(severity) && Prompts::Auditor::HEALTH_AREAS.include?(area)
      return nil if sentence.to_s.empty? || evidence.to_s.empty?
      { "severity" => severity, "area" => area, "text" => sentence, "evidence" => evidence }
    end
    private_class_method :health_finding

    ARTIFACT_BEGIN         = /\A[ \t]*BEGIN ARTIFACT[ \t]*\z/
    ARTIFACT_END           = /\A[ \t]*END ARTIFACT[ \t]*\z/
    ARTIFACT_FILENAME_LINE = /\AFILENAME:[ \t]*(.+)\z/i
    ARTIFACT_TITLE_LINE    = /\ATITLE:[ \t]*(.+)\z/i

    # Read the artifacts a chat answer carries (Prompts::Advisor.artifact_block), and
    # return [artifacts, remainder] — the remainder being the answer with every
    # block removed, which is what gets posted as the comment.
    #
    # The block shape mirrors .parse_work_packages, but the failure rule is the
    # OPPOSITE and deliberately so: there, one bad block rejects the whole answer,
    # because a work package can never be deleted. Here a malformed or truncated
    # block drops only ITSELF and the reply is still posted — an unreadable
    # diagram is no reason to swallow the answer that came with it.
    #
    # As there: marker lines inside a fence are text (a report quotes things, and
    # somebody will paste opilot's own answer into a comment), and a ```mermaid
    # fence inside a block therefore cannot end it.
    def self.parse_artifacts(body)
      artifacts = []
      kept      = []   # lines outside every block, joined verbatim
      open      = nil
      fence     = nil
      body.to_s.lines.each do |raw|
        line  = raw.chomp
        fence = fence_state(fence, line)
        # Inside a fence: content, whatever it says.
        unless fence.nil?
          open ? open << line : kept << raw
          next
        end

        if line.match?(ARTIFACT_BEGIN)
          open = []   # a second BEGIN abandons an unterminated block
        elsif line.match?(ARTIFACT_END)
          artifacts << open if open
          open = nil
        else
          open ? open << line : kept << raw
        end
      end
      # `open` here was cut off mid-block: drop it, but keep everything before it.
      [artifacts.filter_map { |block| artifact_fields(block) }, kept.join]
    end

    # One block's fields. Only the LEADING lines are read as a header, so a report
    # that discusses a `TITLE:` line of its own cannot move the title. A block with
    # no filename, or no content, is dropped rather than guessed at.
    def self.artifact_fields(lines)
      lines  = lines.drop_while { |l| l.strip.empty? }
      fields = {}
      loop do
        line = lines.first.to_s
        if (name = line[ARTIFACT_FILENAME_LINE, 1])
          fields["filename"] ||= name.strip
        elsif (title = line[ARTIFACT_TITLE_LINE, 1])
          fields["title"] ||= title.strip
        else
          break
        end
        lines = lines.drop(1)
      end
      return nil if fields["filename"].to_s.empty?

      content = lines.join("\n").strip
      return nil if content.empty?
      { "filename" => fields["filename"], "title" => fields["title"].to_s, "content" => content }
    end
    private_class_method :artifact_fields

    # A filesystem- and gist-safe name for an artifact, always `.md` (a gist
    # serves raw content as text/plain, so markdown with a ```mermaid fence is the
    # one format that renders). De-duplicated against `taken`, which is
    # load-bearing: a gist's files are keyed by name, so two blocks slugging to
    # the same name would silently collapse into one.
    def self.artifact_filename(raw, taken: [])
      stem = slugify(File.basename(raw.to_s.strip).sub(/\.[^.]+\z/, ""), fallback: "artifact")
      name = "#{stem}.md"
      n    = 1
      while taken.include?(name)
        n += 1
        name = "#{stem}-#{n}.md"
      end
      name
    end

    # Which part of the BEGIN/END WORK PACKAGE contract the last answer missed,
    # said back to the writer on the one retry. Read off the answer itself rather
    # than from the parser, whose answer is only "nothing usable" — the three
    # misses below need three different corrections.
    #
    # It lives beside WP_BEGIN/WP_END and .parse_work_packages on purpose: the
    # markers, the parser and this correction text are ONE contract, and a copy
    # per caller is how one of them starts teaching the old format. `many` is the
    # only thing that varies between callers.
    def self.wp_format_miss(answer, many: false)
      # WP_BEGIN/WP_END anchor a whole LINE, so they are matched line by line.
      lines = answer.to_s.lines.map(&:chomp)
      if lines.none? { |l| l.match?(WP_BEGIN) }
        "Your last answer had no `BEGIN WORK PACKAGE` line. #{many ? "Every work package needs" : "It needs"} " \
          "one, alone on its own line, and a closing `END WORK PACKAGE` line."
      elsif lines.none? { |l| l.match?(WP_END) }
        "Your last answer opened a block and never closed it. Write the closing " \
          "`END WORK PACKAGE` line#{many ? " for every block" : ""}, alone on its own line."
      else
        "Your last answer's #{many ? "blocks were" : "block was"} unreadable — #{many ? "each one" : "it"} " \
          "needs a `SUBJECT: <one line>` line in the header, above the description."
      end
    end

    # Resolve a reader's answer to the plan-call focus for the option they chose,
    # or nil when the answer names no option (it is then plain direction). A
    # **leading** number selects: "2", "option 2" and "2 but keep the toast" all
    # choose option 2, and whatever follows the number rides along instead of
    # being lost. One implementation, because a work-package comment and the
    # terminal prompt must read an answer the same way.
    def self.option_choice(options, text)
      number, extra = text.to_s.strip.match(/\A(?:option\s+)?(\d{1,2})\b[\s,.:;–—-]*(.*)\z/im)&.captures
      return nil unless number
      option = options.to_a.find { |o| o["n"] == number.to_i }
      return nil unless option
      option_focus_text(option, extra.to_s)
    end

    # The plan-call focus for a chosen option. `extra` is anything the reader
    # wrote after the number ("2 but keep the toast"), which is direction on top
    # of the option and must not be dropped. The option's own repo list is passed
    # on as the expected targets, so the repos named in the offer and the repos in
    # the plan's REPOS line do not drift apart.
    def self.option_focus_text(option, extra = "")
      repos = option["repos"].to_a.join(", ")
      text  = +"The reporter chose option #{option["n"]} of the options you offered: " \
               "#{option["title"]} — #{option["summary"]} " \
               "Plan that option only, and do not plan the other options."
      text << " The offer named these repos for it: #{repos}. Keep to them in the REPOS line " \
              "unless the code makes that impossible; if you must change them, say why in the plan." unless repos.empty?
      text << " The reporter added: #{extra.strip}" unless extra.to_s.strip.empty?
      text
    end

    # Everything after the LAST `<MARKER>:` line, or the whole text when the
    # marker is absent.
    #
    # This is the shape every "the answer is the marked part" contract uses, and
    # the reason is always the same: a model under pressure narrates before it
    # answers, however firmly a prompt says not to. A LEADING sentinel fights that
    # instinct — and loses expensively, since a model can spend its whole output
    # budget getting ready to comply and stop with `length`, having produced
    # nothing. A trailing marker turns the same narration into discarded scratch.
    def self.after_marker(text, marker)
      text.to_s.split(/^#{Regexp.escape(marker)}:[ \t]*$/, -1).last.to_s.strip
    end

    # The PR-reply prompts (Prompts::REPLY_CONTRACT) mark the comment to post
    # with a final "REPLY:" line; anything the model produced before it —
    # narration about tooling trouble, "here's my reply:" framing — is discarded
    # rather than posted. Output without the marker is posted whole, and the
    # last marker wins if the text contains several.
    #
    # The marker may carry the reply on its own line here, so this one does not
    # anchor the line end the way .after_marker does.
    def self.extract_reply(text)
      text.to_s.split(/^REPLY:[ \t]*/, -1).last.to_s.strip
    end

    # Prompts::PR_EDIT_CONTRACT. The END line detects a cut-off answer.
    DESCRIPTION_BLOCK = /^BEGIN DESCRIPTION[ \t]*\n(.*?)^END DESCRIPTION[ \t]*$\n?/m
    DESCRIPTION_OPEN  = /^BEGIN DESCRIPTION[ \t]*$/

    # [description or nil, the text without the block, whether it was cut off].
    # The last block wins.
    def self.split_description(text)
      text   = text.to_s
      blocks = text.scan(DESCRIPTION_BLOCK)
      return [blocks.last.first.strip, text.gsub(DESCRIPTION_BLOCK, ""), false] if blocks.any?
      return [nil, text, false] unless text.match?(DESCRIPTION_OPEN)
      [nil, text.split(DESCRIPTION_OPEN, 2).first, true]
    end

    # GitHub's own limit on a PR title.
    MAX_TITLE = 256
    TITLE_LINE = /^TITLE:[ \t]*(.*)$\n?/

    # [title or nil, the text without TITLE lines]. Read only before the last
    # REPLY: line, so a reply that quotes "TITLE:" changes nothing. The last
    # line wins.
    def self.split_title(text)
      text = text.to_s
      head, marker, reply = text.rpartition(/^REPLY:/)
      head, reply = text, "" if marker.empty?
      title = head.scan(TITLE_LINE).flatten.last.to_s.gsub(/\s+/, " ").strip
      [title.empty? ? nil : title[0, MAX_TITLE], "#{head.gsub(TITLE_LINE, "")}#{marker}#{reply}"]
    end
  end
end
