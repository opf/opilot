module OPilot
  module Matrix
    # A message addressed to opilot in the Matrix room (see Matrix::Pull#parse).
    # `verb` is :health, :ship, :create_wp, :chat or :unknown; `ids` are the work
    # packages it names. `message` is a command's text after the ids, or the chat
    # message. `thread_root` is the thread replies and the chat session follow.
    Intent = Struct.new(:event_id, :sender, :thread_root, :verb, :ids, :message, :problem, keyword_init: true)
  end
end
