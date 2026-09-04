require "json"

module OPilot
  # Mirrors the pictures a work package shows into its own state directory, so
  # the LLM can see them.
  #
  # pi's `read` tool inlines png/jpeg/gif/webp/bmp as image attachments, but it
  # has no fetch tool and the harness has no egress: an
  # `/api/v3/attachments/<id>/content` URL in the mirrored text is dead until the
  # bytes are on disk AND the reference points at them. Downloading alone is not
  # enough — a directory of unlinked files is a set of pictures with no subject,
  # so #rewrite_refs is as load-bearing as the download.
  #
  # Nothing here parses an image. The bytes are written through untouched (the
  # same passthrough PD::Intake::Converter gives one), and the decode happens in
  # the contained harness rather than in the runner, which holds both API tokens.
  module ItemPictures
    module_function

    # What pi sniffs and inlines (its utils/mime.js). Anything else is recorded
    # as skipped rather than downloaded: to pi an SVG is markup and a PDF is
    # bytes it will not send, so mirroring them buys nothing.
    TYPES = {
      "image/png"  => ".png",
      "image/jpeg" => ".jpg",
      "image/gif"  => ".gif",
      "image/webp" => ".webp",
      "image/bmp"  => ".bmp"
    }.freeze

    MAX_BYTES = 10 * 1024 * 1024   # one picture
    MAX_TOTAL = 40 * 1024 * 1024   # every picture on one work package
    MAX_COUNT = 20                 # attachments looked at, per work package

    DIR = "pictures".freeze

    # How an inline picture is stored in a description or a comment. The id is
    # the one handle that resolves whatever container holds the attachment.
    #
    # The editor writes the bare path, but a person can paste the absolute URL —
    # and the host has to be part of the match, or the rewrite leaves it glued to
    # a local path (`https://op.test/state/…`), which is neither a link nor a
    # file. Matching it means both forms end up pointing at the same mirror.
    INLINE = %r{(?:https?://[^\s)"'\]]*)?/api/v3/attachments/(\d+)/content}

    # Mirror `item`'s pictures under `dir`, point every inline reference at the
    # mirrored file, and index them all in "pictures". Returns the item.
    #
    # Never raises: a picture must not cost a poll. Every failure degrades to a
    # "pictures_skipped" entry naming the file and the reason, because a reader
    # who attached a screenshot needs to know it was not read.
    def mirror(item, dir:, api:, ctx:)
      code, attached = collection(api, item["id"])
      return unfinished(item) if retryable?(code)

      # A permanent failure (403, 404) IS an answer about the collection, and
      # anything a reference names may still be readable by id — so that one
      # carries on with an empty collection rather than stopping.
      wanted = wanted_attachments(item, attached)
      pictures, skipped, pending = write_all(wanted, dir / DIR, api: api, ctx: ctx)
      # Only a complete answer may delete files: pruning against a half-read
      # collection throws away pictures that are still there.
      prune(dir / DIR, pictures) unless pending

      result = rewrite_refs(item, pictures)
      result["pictures"] = pictures
      result["pictures_skipped"] = skipped
      result.delete("pictures_skipped") if skipped.empty?
      pending ? unfinished(result) : result
    rescue StandardError => e
      puts "  Warning: could not mirror pictures for #{item["id"]}: #{e.class}: #{e.message}"
      unfinished(item)
    end

    # An attachment read failed, which is not the same answer as "there are no
    # pictures". The marker is what `Pull#fetch_work_package_item` adds to its
    # updated_at cache gate: without it this incomplete index reads as current
    # until somebody edits the work package, and for a quiet one that is never.
    # Whatever the last complete run mirrored is carried over untouched
    # (`Pull::CARRIED_KEYS`), so a transient failure loses nothing.
    def unfinished(item)
      item.merge("pictures_pending" => true)
    end

    # Every attachment the work package shows, inline references FIRST: where a
    # picture sits in the text is what says what it is of, and the caps below cut
    # from the end.
    #
    # `attached` covers the work package's own attachments, which is not the same
    # set — a picture pasted into a comment is claimed by that comment, so it is
    # reachable only by the id in the reference (see #attachment_meta).
    def wanted_attachments(item, attached)
      wanted = {}

      inline_refs(item).each do |id, where|
        wanted[id] ||= { "id" => id, "where" => where, "meta" => attached[id] }
      end
      attached.each do |id, meta|
        wanted[id] ||= { "id" => id, "where" => "attached", "meta" => meta }
      end
      wanted.values
    end

    # [code, {id => metadata}] — the code is returned because an empty
    # collection and a collection this run could not read are different answers,
    # and only the caller can tell them apart.
    def collection(api, wp_id)
      code, body = api.work_package_attachments(wp_id)
      return [code, {}] unless code == 200
      elements = body&.dig("_embedded", "elements") || []
      [code, elements.to_h { |a| [a["id"].to_s, a] }]
    end

    # Whether a status could answer differently next time. 429 and 5xx have
    # already been retried by the transport (Clients::HTTP), so one arriving here
    # means the instance is having a bad minute — while a 404 means the
    # attachment is gone and asking again forever would only cost requests.
    def retryable?(code)
      code.to_i.zero? || code.to_i == 429 || code.to_i >= 500
    end

    # [id, where] for every inline reference, in reading order.
    def inline_refs(item)
      texts = [["description", item["description"]]]
      Array(item["comments"]).each { |c| texts << ["comment #{c["id"]}", c["text"]] }

      texts.flat_map do |where, text|
        text.to_s.scan(INLINE).flatten.map { |id| [id, where] }
      end
    end

    # [pictures, skipped, pending]. `pending` is set by a skip that could go away
    # on its own — a failed read or download. A cap or a type never will, so
    # those are a final answer and do not ask for a retry.
    def write_all(wanted, dir, api:, ctx:)
      pictures = []
      skipped  = []
      total    = 0
      pending  = false

      wanted.first(MAX_COUNT).each do |want|
        entry, retry_later = write_one(want, dir, api: api, ctx: ctx, budget: MAX_TOTAL - total)
        if entry["reason"]
          pending ||= retry_later
          skipped << entry
        else
          total += entry["bytes"].to_i
          pictures << entry
        end
      end

      left = wanted.length - MAX_COUNT
      if left.positive?
        skipped << { "name" => "#{left} more attachment(s)",
                     "reason" => "not read — over the #{MAX_COUNT}-attachment limit" }
      end
      [pictures, skipped, pending]
    end

    # [entry, retry_later] — see #write_all.
    def write_one(want, dir, api:, ctx:, budget:)
      meta, code = want["meta"] ? [want["meta"], 200] : attachment_meta(api, want["id"])
      return [skip(want, nil, "could not be read (HTTP #{code})"), retryable?(code)] unless meta

      name = meta["fileName"].to_s
      ext  = TYPES[content_type(meta)]
      return [skip(want, name, "not a picture (#{meta["contentType"]})"), false] unless ext

      size = meta["fileSize"].to_i
      if size > MAX_BYTES
        return [skip(want, name, "larger than #{mb(MAX_BYTES)} (#{size} bytes)"), false]
      end
      if size > budget
        return [skip(want, name, "over the #{mb(MAX_TOTAL)} budget for one work package"), false]
      end

      dest = dir / file_name(want["id"], name, ext)
      unless mirrored?(dest, size)
        bytes, reason, status = download(api, meta)
        return [skip(want, name, reason), retryable?(status)] if reason

        dir.mkpath
        dest.binwrite(bytes)
      end

      [{ "id" => want["id"], "where" => want["where"], "name" => name,
         "content_type" => meta["contentType"], "bytes" => dest.size,
         "file" => Helpers.state_container_path(ctx, dest) }, false]
    end

    # An attachment by id — the route that answers for a comment's picture too.
    # Skipped when the collection already carried it, which is the common case:
    # a picture pasted into the description belongs to the work package.
    def attachment_meta(api, id)
      code, body = api.attachment(id)
      [code == 200 ? body : nil, code]
    end

    # [bytes, nil, code] or [nil, reason, code].
    def download(api, meta)
      url = meta.dig("_links", "downloadLocation", "href")
      # 200 as a sentinel: the API answered, the answer just carries no location.
      # There is nothing here for a later poll to find, so this must not retry.
      return [nil, "no download location", 200] if url.to_s.empty?

      code, bytes = api.download_attachment(url)
      return [nil, "download failed with HTTP #{code}", code] unless code == 200 && bytes
      [bytes, nil, code]
    end

    # Already on disk at the size the API reports, so the bytes are not fetched
    # again — a new comment re-runs the whole mirror, and re-downloading every
    # screenshot on every edit is the one cost this feature can easily repeat.
    # A missing or zero fileSize gives no such proof, so it downloads.
    def mirrored?(dest, size)
      size.positive? && dest.exist? && dest.size == size
    end

    def file_name(id, name, ext)
      "#{id}-#{Helpers.slugify(File.basename(name.to_s, ".*"), fallback: "picture")}#{ext}"
    end

    # "image/png; charset=binary" — compare the type alone.
    def content_type(meta)
      meta["contentType"].to_s.split(";").first.to_s.strip.downcase
    end

    def skip(want, name, reason)
      { "id" => want["id"], "where" => want["where"],
        "name" => name.to_s.empty? ? "attachment #{want["id"]}" : name, "reason" => reason }
    end

    def mb(bytes)
      "#{bytes / 1024 / 1024}MB"
    end

    # Point every inline reference at the mirrored file, in the description and
    # in every comment. An id that did not land keeps its original URL: it is
    # dead either way, and leaving it says a picture is there.
    def rewrite_refs(item, pictures)
      paths = pictures.to_h { |p| [p["id"], p["file"]] }
      return item if paths.empty?

      result = item.merge("description" => rewrite(item["description"], paths))
      if item.key?("comments")
        result["comments"] = Array(item["comments"]).map { |c| c.merge("text" => rewrite(c["text"], paths)) }
      end
      result
    end

    def rewrite(text, paths)
      text.to_s.gsub(INLINE) { paths[Regexp.last_match(1)] || Regexp.last_match(0) }
    end

    # A picture dropped from an edited comment has to disappear, and one still
    # there must not be downloaded again — so prune by name rather than clearing
    # the directory before each run.
    def prune(dir, pictures)
      return unless dir.exist?
      keep = pictures.map { |p| File.basename(p["file"].to_s) }
      dir.children.each { |f| f.delete if f.file? && !keep.include?(f.basename.to_s) }
    end
  end
end
