module OPilot
  module GitHub
    # A trigger on a PR, normalised so GitHub::Agent can act on it.
    #
    # `kind` — :issue (conversation thread), :review (inline on a diff line, carries
    #   `comment_id`, and `in_reply_to` when the trigger is a reply within a thread),
    #   or :ci (no comment at all: `text`/`comment_id` are nil and `head_sha` carries
    #   the commit whose checks failed, which is what the act-state dedupes on).
    # `repo` / `head_repo` — the base repo comments are posted to, vs where the
    #   branch lives (the bot's fork): what gh-agent fetches from and pushes to.
    # `reply_only` — an upstream PR opilot did NOT open: answer, never push.
    # `command` — :refresh for "@opilot refresh" (the full `pr` treatment instead
    #   of a reply), :close for "@opilot close" (close the PR unmerged). Only ever
    #   set for a PR opilot opened itself, never on a reply_only intent; a spec PR
    #   gets :close only (see GitHub::Pull#command_for).
    # `spec_change_id` — the PR is a `pd` proposal, so `item_id` is a change id and
    #   the act-state lives under changes/<host>/<change-id>/, not work_packages/.
    Intent = Struct.new(:item_id, :repo_name, :subject, :branch, :repo, :head_repo, :pr_number, :pr_url,
                        :kind, :command, :comment_id, :in_reply_to, :text, :user_login, :comment_at,
                        :reply_only, :head_sha, :spec_change_id,
                        keyword_init: true) do
      def spec?
        !spec_change_id.nil?
      end
    end
  end
end
