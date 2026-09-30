require "uri"

module OPilot
  module Clients
    module OpenProject
      # Attachment metadata and bytes, for work packages and documents alike.
      module Attachments
        # Attachment metadata for a work package: fileName, contentType, fileSize
        # and _links.downloadLocation for each. Not paginated — the endpoint
        # renders `container.attachments` whole.
        #
        # It holds only what is attached to the WORK PACKAGE. A picture pasted into
        # a comment is claimed by that comment
        # (WorkPackages::ActivitiesTab::CommentAttachmentsClaims), so it is absent
        # here and has to be read by id with #attachment.
        def work_package_attachments(wp_id)
          get("work_packages/#{wp_id}/attachments")
        end

        # One attachment by id, whatever container holds it — the only route that
        # answers for a comment's picture as well as a work package's. The id is
        # what an inline `![](/api/v3/attachments/<id>/content)` reference carries,
        # and the endpoint checks Attachment#visible? against the token, so an
        # attachment this token may not read 404s.
        def attachment(attachment_id)
          get("attachments/#{attachment_id}")
        end

        # Raw attachment bytes, as the Response body; the download location 302s
        # to wherever the file actually lives, which HTTP.get_binary follows.
        #
        # The token rides along ONLY for a URL on this instance. get_binary already
        # drops it from hop 2 onward; hop 1 needs the same rule, because
        # `downloadLocation` is a direct presigned URL on S3-backed storage and
        # `op doc download` takes it from a caller. Withheld, not refused, so the
        # presigned shape keeps working.
        def download_attachment(download_url)
          url = absolute_url(download_url)
          path = begin URI(url).path rescue "attachment" end
          send_request("GET #{path}") do
            HTTP.get_binary(url, token: on_this_instance?(url) ? @token : nil)
          end
        end

        # Whether a URL points at the instance this client is configured for —
        # scheme, host and port all matching. A URL that cannot be parsed is not.
        def on_this_instance?(url)
          given = URI(absolute_url(url))
          base  = URI(@base.to_s)
          given.scheme == base.scheme && given.host == base.host && given.port == base.port
        rescue URI::InvalidURIError
          false
        end

        # `downloadLocation` is only absolute on external storage; with the files
        # on the instance itself it is the bare API path, which has no host to
        # connect to and reads as "not this instance" (so the token would be
        # withheld from our own API). Resolve against the base before either
        # decision, in one place, so both answers agree.
        def absolute_url(url)
          URI.join(@base.to_s, url.to_s).to_s
        rescue URI::Error
          url.to_s
        end
      end
    end
  end
end
