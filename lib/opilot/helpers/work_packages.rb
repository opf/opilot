require "uri"
# Ruby 4.0 dropped the full CGI library; cgi/escape is the part that survived,
# and CGI.escapeHTML is all .mention needs.
require "cgi/escape"

module OPilot
  module Helpers
    # OpenProject text: mentions, links, labels, the prompt's type list, and what
    # a posted comment is rewritten to.

    # An OpenProject mention of a user, so a comment notifies and addresses them
    # by name. Falls back to the bare name, then to "", when the details are
    # missing. Display names are free text an attacker can influence, so the name
    # is HTML-escaped and the id must be numeric.
    def self.mention(name, user_href)
      escaped = CGI.escapeHTML(name.to_s)
      id      = Clients::OpenProject::Resource.href_id(user_href).to_s
      return escaped unless id.match?(/\A\d+\z/)
      %Q(<mention class="mention" data-id="#{id}" data-type="user" data-text="#{escaped}">@#{escaped}</mention>)
    end

    # The TYPE line's menu. An empty registry is stated rather than left blank, so
    # the writer omits the line instead of inventing a type name. One definition,
    # because every prompt carrying a `TYPE:` line reads the same list.
    def self.types_for_prompt(types)
      names = types.to_a.map { |t| t["name"].to_s }.reject(&:empty?)
      names.empty? ? "(unknown — leave the TYPE line out)" : names.join(", ")
    end

    # A markdown link to an OpenProject document, for text that will be rendered
    # by GitHub. Always a link, never a bare "#118": GitHub autolinks that to
    # issue/PR 118 in whatever repo the text lands in, so a document reference
    # silently turns into a pointer at an unrelated pull request. Inside link
    # text the autolinker leaves it alone, and the reader gets the real document.
    def self.document_link(ctx, id, title = nil)
      label = title.to_s.empty? ? "Document ##{id}" : "##{id} #{title}"
      "[#{label}](#{ctx.op_url}/documents/#{id})"
    end

    # The browser URL of a work package on this instance.
    def self.wp_url(ctx, id)
      "#{ctx.op_url}/work_packages/#{id}"
    end

    # A work package id as the user types it: numeric ("59942") or semantic
    # ("PROJ-123", instances in semantic-identifier mode). Mirrors OpenProject's
    # WorkPackage::SemanticIdentifier::ID_ROUTE_CONSTRAINT.
    WP_ID_PATTERN = /\A(?:\d+|[A-Z][A-Z0-9_]*-\d+)\z/

    # Ids pasted from OpenProject often carry the "#" prefix ("#59942",
    # "#PROJ-123") — accept it, and upcase semantic ids typed in lowercase
    # ("proj-123"); WP_ID_PATTERN validation downstream rejects garbage.
    def self.wp_id_arg(arg)
      id = arg.to_s.strip.delete_prefix("#")
      id.match?(/\A[A-Za-z][A-Za-z0-9_]*-\d+\z/) ? id.upcase : id
    end

    # Inline label for a work package id, mirroring OpenProject's
    # WorkPackage::SemanticIdentifier.format_display_id: semantic ids are
    # self-describing ("PROJ-42"); classic numeric ids keep the "#42" prefix.
    def self.wp_label(id)
      id.to_s.match?(/[A-Za-z]/) ? id.to_s : "##{id}"
    end

    def wp_label(id)
      Helpers.wp_label(id)
    end

    # Shared by the commit subject and the PR title so the two stay identical.
    def self.pr_title(id, subject)
      "[#{wp_label(id)}] #{subject}"
    end

    def pr_title(id, subject)
      Helpers.pr_title(id, subject)
    end

    # The OpenProject instance host (no port), for matching WP links, or nil.
    def op_link_host
      URI(@ctx.op_url.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    # Demote every ATX markdown heading to bold, for anything posted to a work
    # package: the activity tab is a narrow column, so a plan with five `##`
    # sections spends most of its width on its own titles. Bold reads the same and
    # costs one line. Applied centrally in `#add_comment` rather than per caller,
    # since the text comes from the LLM as often as from opilot and prompt guidance
    # alone doesn't hold.
    #
    # Fenced blocks are left alone (a leading `#` there is a code comment or a
    # shell prompt), and so are setext headings — `---` is usually a rule.
    def self.demote_headings(text)
      fenced = false
      text.to_s.lines.map do |line|
        body    = line.chomp
        newline = line.end_with?("\n") ? "\n" : ""
        fenced = !fenced if body.lstrip.start_with?("```", "~~~")
        next line if fenced
        # A hash run with no text after it is still a heading (an empty one);
        # `#tag` with no space is not.
        m = body.match(/\A {0,3}\#{1,6}(?:[ \t]+(.*))?\z/)
        next line unless m
        title = m[1].to_s.sub(/[ \t]*#+[ \t]*\z/, "").strip   # drop an optional closing run
        (title.empty? ? "" : "**#{title}**") + newline
      end.join
    end

    # Defang every OpenProject WP link (http→hxxp). The link is there so a PR can
    # be traced back to its WP and later adopted, but OpenProject's GitHub
    # integration also scans PR bodies for it and would auto-reference the WP,
    # cluttering its activity tab with a fork PR nobody has taken over. `hxxp://`
    # fails the integration's `https?://…/(?:work_packages|wp)/<id>` matcher while
    # leaving the id readable; `op_ticket_id` reads it back and `opilot-adopt` re-fangs
    # it. Host-scoped, idempotent, and a no-op when the host is unknown.
    def neutralize_wp_links(text)
      host = op_link_host
      return text if host.to_s.empty?
      text.to_s.gsub(
        %r{http(s?://#{Regexp.escape(host)}(?::\d+)?/(?:\S+?/)*?(?:work_packages|wp)/)}i,
        "hxxp\\1"
      )
    end
  end
end
