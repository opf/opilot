module OPilot
  # An inbound instruction parsed from an @opilot comment (see OpPull#poll_intents).
  # `user` / `user_href` identify the commenter, so replies can address them.
  # `internal` is the trigger comment's visibility, so the reply can mirror it
  # (an internal @opilot prompt gets an internal answer, a public one a public).
  Intent = Struct.new(:item_id, :subject, :type, :command, :text, :comment_at,
                      :user, :user_href, :internal, keyword_init: true)
end
