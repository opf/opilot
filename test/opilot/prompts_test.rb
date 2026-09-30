require_relative "../test_helper"

module OPilot
  # Every builder that opens a conversation carries its role's charter, and the
  # charter's grant rules appear exactly once. The likely mistake is a builder
  # that still pastes a grant block the charter now adds.
  class PromptsTest < Minitest::Test
    REPOS = [{ name: "openproject", path: "/repos/openproject", description: "core" }].freeze
    PR = { worktree: "/w", repo: "o/r", pr_number: 5, title: "T", item: "/i", plan: "/p", pr_thread: "/t" }.freeze

    BUILDERS = {
      [Prompts::Planner, :plan] => { repos_summary: "", repos: REPOS, item: "/i", item_id: 1, title: "T", allow_options: true },
      [Prompts::Planner, :replan] => { repos_summary: "", repos: REPOS, item: "/i", plan: "/p", feedback: "f", item_id: 1, title: "T" },
      [Prompts::Advisor, :chat] => { item_id: 1, subject: "S", item: "/i", plan: "/p", message: "m" },
      [Prompts::Advisor, :plan_chat] => { item_id: 1, subject: "S", item: "/i", plan: "/p", message: "m" },
      [Prompts::Advisor, :free_chat] => { state: "/s", wp_root: "/s/w", repos: REPOS, message: "m" },
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
    FOLLOW_UPS = [[Prompts::SpecWriter, :propose_revise]].freeze

    def render(mod, name) = mod.public_send(name, **BUILDERS.fetch([mod, name]))

    def test_every_builder_is_covered
      builders = Prompts.constants.map { |c| Prompts.const_get(c) }
                        .select { |m| m.is_a?(Module) && m.const_defined?(:ROLE, false) }
                        .flat_map { |m| m.singleton_methods(false).map { |n| [m, n] } }
                        .select { |m, n| m.method(n).parameters.any? { |type, _| type == :keyreq } }
      assert_equal (BUILDERS.keys + FOLLOW_UPS).sort_by(&:inspect), builders.sort_by(&:inspect)
    end

    def test_each_builder_opens_with_its_charter_and_its_grant_once
      BUILDERS.each_key do |mod, name|
        text = render(mod, name)
        role = Harness.role(mod::ROLE)
        own, other = role.write? ? [Prompts::WRITE_GRANT, Prompts::READ_ONLY] : [Prompts::READ_ONLY, Prompts::WRITE_GRANT]
        label = "#{mod}.#{name}"
        assert text.start_with?(role.charter), label
        assert_equal 1, text.scan(own).size, "#{label}: its grant block once"
        refute_includes text, other, "#{label}: the other grant's block"
        refute_match(/You are (the WRITER|the IMPLEMENTER|opilot,)/, text, label)
        assert_equal mod::ROLE, text.role, label
      end
    end

    # Each role is a pair side by side: <role>.yml and <role>.rb, whose module is the role's.
    def test_each_role_is_a_yml_and_rb_pair
      dir = Harness::ROLES_DIR
      rb = dir.glob("[a-z]*.rb").map { |f| f.basename(".rb").to_s }
      assert_equal Harness::ROLES.keys.map(&:to_s).sort, rb.sort
      (BUILDERS.keys + FOLLOW_UPS).each do |mod, name|
        assert_equal dir / "#{mod::ROLE}.rb", Pathname(mod.method(name).source_location.first), "#{mod}.#{name}"
      end
    end

    def test_a_follow_up_carries_no_charter
      text = Prompts::SpecWriter.propose_revise(change_id: "c", change_dir: "/c", failures: "f", attempt: 1, max_attempts: 2)
      refute_includes text, Harness.role(:spec_writer).charter
    end

    def test_blocks_load_from_files
      assert_equal (Prompts::BLOCKS_DIR / "plain_english.md").read.strip, Prompts::PLAIN_ENGLISH
      assert Prompts::REPLY_CONTRACT.end_with?(Prompts::PLAIN_ENGLISH)
    end
  end
end
