require_relative "../test_helper"

module OPilot
  # The charter and its grant rules are the system prompt (Harness#run sends
  # them), so no builder may carry them: a pasted copy would state the grant twice,
  # and a resumed session would keep an earlier role's.
  class PromptsTest < Minitest::Test
    REPOS = [{ name: "openproject", path: "/repos/openproject", description: "core" }].freeze
    PR = { worktree: "/w", repo: "o/r", pr_number: 5, title: "T", item: "/i", plan: "/p", pr_thread: "/t" }.freeze

    BUILDERS = {
      [Prompts::Planner, :plan] => { repos_summary: "", repos: REPOS, item: "/i", item_id: 1, title: "T", allow_options: true },
      [Prompts::Planner, :replan] => { repos_summary: "", repos: REPOS, item: "/i", plan: "/p", feedback: "f", item_id: 1, title: "T" },
      [Prompts::Advisor, :chat] => { item_id: 1, subject: "S", item: "/i", plan: "/p", message: "m" },
      [Prompts::Advisor, :plan_chat] => { item_id: 1, subject: "S", item: "/i", plan: "/p", message: "m" },
      [Prompts::Advisor, :free_chat] => { state: "/s", wp_root: "/s/w", repos: REPOS, message: "m" },
      [Prompts::Advisor, :room_chat] => { state: "/s", wp_root: "/s/w", repos: REPOS, message: "m", sender: "@a:l" },
      [Prompts::WpWriter, :create_wp] => { item_id: 1, subject: "S", item: "/i", request: "r", project: "P", types: "Task", max: 5 },
      [Prompts::Triager, :appsignal_wp] => { incident: "/x", number: 7, app: "a", repos: REPOS, types: "Bug" },
      [Prompts::Auditor, :health] => { item_id: 1, subject: "S", item: "/i", facts: "/f" },
      [Prompts::Implementer, :implement] => { repos: REPOS, plan: "/p" },
      [Prompts::Implementer, :implement_task] => { repo: "op", repo_path: "/r", change_id: "c", change_dir: "/c", wp_label: "#1",
                                                   section: "S", tasks: "- [ ] t", item: "/i" },
      [Prompts::SpecWriter, :propose] => { change_id: "c", change_dir: "/c", intake_dir: "/c/i", specs_dir: "/s", repo: "op",
                                           repo_path: "/r", instructions: "I" },
      [Prompts::SpecWriter, :propose_feedback] => { change_id: "c", change_dir: "/c", pr_thread: "/t", comment_section: "C" },
      [Prompts::PrAuthor, :gh_reply] => PR.merge(comment: "c", author: "a", comment_id: 1),
      [Prompts::PrAuthor, :fix_ci] => PR.merge(ci: "/ci"),
      [Prompts::PrRefresher, :pr_refresh] => PR.merge(base: "dev", ci: "/ci", conflicts: ["a.rb"], feedback_count: 1),
      [Prompts::PrAdvisor, :pr_review] => { repo: "o/r", pr_number: 5, title: "T", worktree: "/w", base: "dev", pr_thread: "/t",
                                            comment: "c", author: "a", comment_id: 1 },
      [Prompts::Scribe, :pr_description] => { item: "/i", plan: "/p", diff_stat: "d", template_section: "" },
      [Prompts::Scribe, :commit_subject] => { diff: "d" },
    }.freeze

    # Sent inside a session the role's first prompt already opened.
    FOLLOW_UPS = [[Prompts::SpecWriter, :propose_revise], [Prompts::Advisor, :room_follow_up],
                  [Prompts::Advisor, :chat_follow_up]].freeze

    def render(mod, name) = mod.public_send(name, **BUILDERS.fetch([mod, name]))

    def test_every_builder_is_covered
      builders = Prompts.constants.map { |c| Prompts.const_get(c) }
                        .select { |m| m.is_a?(Module) && m.singleton_class.include?(Prompts::Sections) }
                        .flat_map { |m| m.singleton_methods(false).map { |n| [m, n] } }
                        .select { |m, n| m.method(n).parameters.any? { |type, _| type == :keyreq } }
      assert_equal (BUILDERS.keys + FOLLOW_UPS).sort_by(&:inspect), builders.sort_by(&:inspect)
    end

    def test_no_builder_carries_a_charter_or_a_grant_block
      BUILDERS.each_key do |mod, name|
        text = render(mod, name)
        label = "#{mod}.#{name}"
        refute_includes text, Harness.role(mod.role).charter, label
        refute_includes text, Prompts::READ_ONLY, label
        refute_includes text, Prompts::WRITE_GRANT, label
        assert_equal mod.role, text.role, label
      end
    end

    def test_the_system_prompt_holds_the_charter_and_only_its_own_grant
      Harness::ROLES.each_value do |role|
        own, other = role.write? ? [Prompts::WRITE_GRANT, Prompts::READ_ONLY] : [Prompts::READ_ONLY, Prompts::WRITE_GRANT]
        text = Prompts.charter(role.name)
        assert text.start_with?(role.charter), role.name
        assert_includes text, own, role.name
        refute_includes text, other, role.name
      end
    end

    # Each role is a pair side by side: <role>.yml and <role>.rb, whose module is the role's.
    def test_each_role_is_a_yml_and_rb_pair
      dir = Harness::ROLES_DIR
      rb = dir.glob("[a-z]*.rb").map { |f| f.basename(".rb").to_s }
      assert_equal Harness::ROLES.keys.map(&:to_s).sort, rb.sort
      (BUILDERS.keys + FOLLOW_UPS).each do |mod, name|
        assert_equal dir / "#{mod.role}.rb", Pathname(mod.method(name).source_location.first), "#{mod}.#{name}"
      end
    end

    # The OpenProject tools come first, except in a Matrix room: its audience
    # rule reads the internal flag of a mirrored comment.
    def test_the_lookup_line_puts_the_tools_first_except_in_the_room
      wp = Prompts::Advisor.chat(**BUILDERS.fetch([Prompts::Advisor, :chat]), op_mcp: true)
      assert_includes wp, "Use them FIRST for anything outside this work package"
      free = Prompts::Advisor.free_chat(**BUILDERS.fetch([Prompts::Advisor, :free_chat]), op_mcp: true)
      assert_includes free, "Use them FIRST to read a work package"
      assert_includes free, "read work packages with the OpenProject tools"
      room = Prompts::Advisor.room_chat(**BUILDERS.fetch([Prompts::Advisor, :room_chat]), op_mcp: true)
      assert_includes room, "Read the mirror first"
      refute_includes room, "Use them FIRST"
    end

    def test_the_light_related_index_names_no_mirror
      plan = Prompts::Planner.plan(**BUILDERS.fetch([Prompts::Planner, :plan]), related: "/r.json", op_mcp: true)
      assert_includes plan, "numeric_id"
      refute_includes plan, "item_path"
      plan = Prompts::Planner.plan(**BUILDERS.fetch([Prompts::Planner, :plan]), related: "/r.json")
      assert_includes plan, "item_path"
    end

    def test_blocks_load_from_files
      assert_equal (Prompts::BLOCKS_DIR / "plain_english.md").read.strip, Prompts::PLAIN_ENGLISH
    end

    # The language rule is in the system prompt of every role that publishes
    # prose, so a builder never repeats it. Scribe keeps it inline: its commit
    # subject is out of scope, and the implementer writes code.
    def test_the_language_rule_is_in_the_system_prompt_of_the_publishing_roles
      inline = %i[scribe implementer]
      Harness::ROLES.each_key do |name|
        check = inline.include?(name) ? :refute_includes : :assert_includes
        send(check, Prompts.charter(name), Prompts::PLAIN_ENGLISH, name)
      end
      BUILDERS.each_key do |mod, name|
        next if inline.include?(mod.role)
        refute_includes render(mod, name), Prompts::PLAIN_ENGLISH, "#{mod}.#{name}"
      end
    end

    def test_the_search_stop_rule_is_in_the_system_prompt_of_the_roles_that_read_the_tree
      %i[planner advisor].each { |name| assert_includes Prompts.charter(name), Prompts::SEARCH_STOP_RULE, name }
      refute_includes Prompts.charter(:auditor), Prompts::SEARCH_STOP_RULE
      BUILDERS.each_key { |mod, name| refute_includes render(mod, name), Prompts::SEARCH_STOP_RULE, "#{mod}.#{name}" }
    end

    def test_only_the_own_pr_reply_and_refresh_offer_a_description_edit
      assert_includes render(Prompts::PrAuthor, :gh_reply), "BEGIN DESCRIPTION"
      assert_includes render(Prompts::PrRefresher, :pr_refresh), "BEGIN DESCRIPTION"
      refute_includes render(Prompts::PrAuthor, :fix_ci), "BEGIN DESCRIPTION"
      refute_includes render(Prompts::PrAdvisor, :pr_review), "BEGIN DESCRIPTION", "an upstream PR is not opilot's"
    end

    def test_a_refresh_after_a_base_merge_says_to_read_files_again
      args = BUILDERS.fetch([Prompts::PrRefresher, :pr_refresh])
      assert_includes Prompts::PrRefresher.pr_refresh(**args, merged: true), "read each file again"
      refute_includes Prompts::PrRefresher.pr_refresh(**args), "read each file again"
    end
  end
end
