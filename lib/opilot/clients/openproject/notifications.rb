module OPilot
  module Clients
    module OpenProject
      # The token user's own in-app notifications — the bot's inbox, never a
      # project-wide feed. Filters: id, project, readIAN, reason (mentioned,
      # assigned, watched, commented, dateAlert, …), resourceId, resourceType.
      module Notifications
        # The `readIAN` filter takes only "t" and "f"; "true"/"false" answer 400.
        UNREAD = Query.filter("readIAN", "=", "f").freeze

        # Newest first: the server orders the collection by id desc.
        def notifications(filters_json: "[]", page: 1, page_size: 100)
          collection("notifications", filters_json: filters_json, page: page, page_size: page_size)
        end

        def notification(notification_id)
          get("notifications/#{notification_id}")
        end

        # The mark calls answer 204. The `{}` body is only there for the
        # Content-Type header, which the API demands of every POST (406 without).
        def mark_notification_read(notification_id)
          post("notifications/#{notification_id}/read_ian", {})
        end

        def mark_notification_unread(notification_id)
          post("notifications/#{notification_id}/unread_ian", {})
        end

        # Bulk: every notification the filters match. `filters_json` has no
        # default, because "[]" here marks the whole inbox.
        def mark_notifications_read(filters_json:)
          post("notifications/read_ian", {}, filters: filters_json)
        end

        def mark_notifications_unread(filters_json:)
          post("notifications/unread_ian", {}, filters: filters_json)
        end
      end
    end
  end
end
