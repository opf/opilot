require_relative "../test_helper"

module OPilot
  # `./opilot appsignal fix` — the guard that lets this command exist, and the
  # gates around a work package that can never be deleted.
  class AppSignalRunnerTest < Minitest::Test
    include TestFixtures

    API    = "https://op.example.com/api/v3".freeze
    # The client posts with notify=false, so the query string is part of the URL.
    CREATE = "#{API}/work_packages?notify=false".freeze
    # AppSignal app ids are 24 hex characters; the runner tells an id from a name
    # by that shape, so the fixture has to use a real-shaped one.
    APP    = "0123456789abcdef01234567".freeze

    class FakeHarness
      attr_reader :prompts
      def initialize(*replies)
        @replies = replies
        @prompts = []
      end

      def ensure_available!; end

      def run(prompt, **)
        @prompts << prompt
        @replies.shift.to_s
      end
    end

    class FakeAppSignal
      attr_reader :fetched, :apps_called
      REPORT = { "number" => 4711, "exceptionName" => "NoMethodError",
                 "request" => { "payload" => { "id" => 1 } } }.freeze

      def initialize(incident = REPORT, apps: [{ "id" => APP, "name" => "op", "environment" => "production" }])
        @incident    = incident
        @apps        = apps
        @fetched     = []
        @apps_called = 0
      end

      def applications
        @apps_called += 1
        @apps
      end

      def incident(app, number)
        @fetched << [app, number]
        @incident
      end
    end

    class FakeFixRunner
      attr_reader :shipped
      def initialize = @shipped = []
      def ship_ids(*ids) = @shipped.concat(ids)
    end

    DRAFT = <<~REPLY.freeze
      Looking at the backtrace now.
      ANSWER:
      BEGIN WORK PACKAGE
      SUBJECT: Guard against a nil author when rendering an activity
      TYPE: BUG

      The activity list crashes when a comment's author was deleted.
      END WORK PACKAGE
    REPLY

    def setup
      @tmpdir = Pathname(Dir.mktmpdir)
      @ctx    = build_ctx(@tmpdir, contributor_token: "gh-token")
      stub_project
      stub_types
    end

    def teardown
      FileUtils.remove_entry(@tmpdir)
    end

    def stub_project(create_allowed: true)
      links = { "self" => { "href" => "/api/v3/projects/COMMS" } }
      links["createWorkPackage"] = { "href" => "/api/v3/projects/COMMS/work_packages/form" } if create_allowed
      stub_request(:get, "#{API}/projects/COMMS")
        .to_return(status: 200, body: JSON.generate("name" => "Comms", "_links" => links))
    end

    def stub_types
      stub_request(:get, "#{API}/projects/COMMS/types")
        .to_return(status: 200, body: JSON.generate(
          "_embedded" => { "elements" => [{ "id" => 7, "name" => "BUG" }] }
        ))
    end

    def stub_form(errors = {})
      stub_request(:post, "#{API}/work_packages/form")
        .to_return(status: 200, body: JSON.generate("_embedded" => { "validationErrors" => errors }))
    end

    def stub_create(id: 991)
      stub_request(:post, CREATE)
        .to_return(status: 201, body: JSON.generate("id" => id, "subject" => "x"))
    end

    def runner(harness: FakeHarness.new(DRAFT), appsignal: FakeAppSignal.new, fix_runner: FakeFixRunner.new, ctx: @ctx)
      AppSignalRunner.new(ctx, harness: harness, appsignal: appsignal, fix_runner: fix_runner)
    end

    # Answer the one confirmation prompt.
    def with_answer(answer)
      original = $stdin
      $stdin = StringIO.new("#{answer}\n")
      capture_io { yield }
    ensure
      $stdin = original
    end

    # ── the guard ───────────────────────────────────────────────────────────
    #
    # This command sends production error data to the model. TODO.md blocked the
    # whole integration on exactly that, so the gate is the feature.

    def test_fix_refuses_when_the_model_is_not_local
      ctx = build_ctx(@tmpdir, contributor_token: "gh-token", inference_private: false,
                               inference_url: "https://openrouter.ai/api/v1")
      appsignal = FakeAppSignal.new
      err = assert_raises(OPilot::FatalError) { runner(ctx: ctx, appsignal: appsignal).run(%w[fix 4711]) }

      assert_includes err.message, "cannot confirm the model is local"
      assert_includes err.message, "https://openrouter.ai/api/v1", "the reader needs to know which endpoint"
      assert_includes err.message, "a test said no", "and WHY — a not-running inference-gw looks the same otherwise"
      assert_empty appsignal.fetched, "nothing may be fetched once the guard has refused"
      assert_not_requested :post, CREATE
    end

    # ── preflights before anything irreversible ─────────────────────────────

    def test_fix_refuses_without_a_publishing_token_before_fetching
      ctx = build_ctx(@tmpdir, contributor_token: nil)
      appsignal = FakeAppSignal.new
      err = assert_raises(OPilot::FatalError) { runner(ctx: ctx, appsignal: appsignal).run(%w[fix 4711]) }

      assert_includes err.message, "GITHUB_CONTRIBUTOR_TOKEN"
      assert_empty appsignal.fetched
    end

    def test_fix_refuses_when_the_token_cannot_create_work_packages
      WebMock.reset!
      stub_project(create_allowed: false)
      harness = FakeHarness.new(DRAFT)
      err = assert_raises(OPilot::FatalError) { runner(harness: harness).run(%w[fix 4711]) }

      assert_includes err.message, "add_work_packages"
      assert_empty harness.prompts, "the permission check must cost a request, not a whole draft"
    end

    # ── the happy path ──────────────────────────────────────────────────────

    def test_fix_creates_the_work_package_then_hands_it_to_the_build_pipeline
      stub_form
      stub_create(id: 991)
      fix_runner = FakeFixRunner.new
      appsignal  = FakeAppSignal.new

      with_answer("y") { runner(appsignal: appsignal, fix_runner: fix_runner).run(%w[fix 4711]) }

      assert_equal [[APP, "4711"]], appsignal.fetched
      assert_requested(:post, CREATE) do |req|
        body = JSON.parse(req.body)
        body["subject"] == "Guard against a nil author when rendering an activity" &&
          body.dig("_links", "type", "href") == "/api/v3/types/7"
      end
      assert_equal ["991"], fix_runner.shipped, "the existing pipeline does the rest"
    end

    def test_the_incident_is_cached_under_the_openproject_host
      stub_form
      stub_create
      with_answer("y") { runner.run(%w[fix 4711]) }

      cached = @ctx.state_dir / "appsignal" / "op.example.com" / APP / "4711" / "incident.json"
      assert cached.exist?, "namespaced by instance, like work_packages/"
      assert_equal 4711, JSON.parse(cached.read)["number"]
    end

    # A work package can never be deleted, so a second run must find the record
    # rather than mint a second one for the same error.
    def test_a_second_run_reports_the_existing_work_package_and_creates_nothing
      stub_form
      stub_create(id: 991)
      with_answer("y") { runner.run(%w[fix 4711]) }
      WebMock.reset!
      stub_project
      stub_types

      fix_runner = FakeFixRunner.new
      harness    = FakeHarness.new(DRAFT)
      capture_io { runner(harness: harness, fix_runner: fix_runner).run(%w[fix 4711]) }

      assert_empty harness.prompts, "no second draft"
      assert_not_requested :post, CREATE
      assert_equal ["991"], fix_runner.shipped, "it still builds the one that exists"
    end

    # ── draft persistence ───────────────────────────────────────────────────
    #
    # The LLM call that writes the draft is the expensive part of `fix`, so
    # nothing should ever pay for it twice for the same incident.

    def test_a_usable_draft_is_persisted_before_the_confirm_prompt
      stub_form
      with_answer("a") { runner.run(%w[fix 4711]) } # abort — nothing gets created

      cached = JSON.parse((Helpers.incident_dir(@ctx, APP, "4711") / "draft.json").read)
      assert_equal "Guard against a nil author when rendering an activity", cached["subject"]
    end

    def test_a_cached_draft_is_reused_without_a_new_llm_call
      dir = Helpers.incident_dir(@ctx, APP, "4711")
      dir.mkpath
      (dir / "draft.json").write(JSON.generate(
        "subject" => "Cached subject", "type" => "BUG", "description" => "Cached body."
      ))
      stub_form
      stub_create
      harness   = FakeHarness.new # no replies queued — a draft call would blow up
      appsignal = FakeAppSignal.new

      with_answer("y") { runner(harness: harness, appsignal: appsignal).run(%w[fix 4711]) }

      assert_empty harness.prompts, "no LLM call for a draft already on disk"
      assert_empty appsignal.fetched, "no incident re-fetch either"
      assert_requested(:post, CREATE) { |req| JSON.parse(req.body)["subject"] == "Cached subject" }
    end

    def test_declining_the_prompt_creates_nothing
      stub_form
      fix_runner = FakeFixRunner.new
      with_answer("a") { runner(fix_runner: fix_runner).run(%w[fix 4711]) }

      assert_not_requested :post, CREATE
      assert_empty fix_runner.shipped
    end

    # ── the form preflight ──────────────────────────────────────────────────

    def test_a_required_custom_field_aborts_before_the_create
      stub_form("customField12" => { "message" => "Release train can't be blank" })
      fix_runner = FakeFixRunner.new
      _out, = with_answer("y") { runner(fix_runner: fix_runner).run(%w[fix 4711]) }

      assert_not_requested :post, CREATE
      assert_empty fix_runner.shipped
    end

    def test_the_field_the_project_demands_is_named_in_its_own_words
      stub_form("customField12" => { "message" => "Release train can't be blank" })
      out, = with_answer("y") { runner.run(%w[fix 4711]) }
      assert_includes out, "Release train can't be blank"
    end

    # ── the allowlisted custom-field hack ───────────────────────────────────
    #
    # A narrow, explicit exception: these four are opilot's own manufactured
    # test fields on the "Chomper testing area" project, matched by name so
    # nothing with real business meaning is ever touched.

    CF_SCHEMA = {
      "customField158" => {
        "name" => "Bug found in version", "type" => "[]Version",
        "_links" => { "allowedValues" => [
          { "href" => "/api/v3/versions/10", "title" => "adsf" },
          { "href" => "/api/v3/versions/633", "title" => "adsf" }
        ] }
      },
      "customField205" => {
        "name" => "Cécile List Type Multi Select Custom Field", "type" => "[]CustomOption",
        "_links" => { "allowedValues" => [
          { "href" => "/api/v3/custom_options/684", "title" => "1 - wahad" }
        ] }
      },
      # The real field name carries a trailing space — the match must survive it.
      "customField223" => {
        "name" => "Cécile Hierarchy NotAfilter SingleSelect Required CF ",
        "type" => "CustomField::Hierarchy::Item",
        "_links" => { "allowedValues" => { "href" => "/api/v3/custom_fields/223/items" } }
      },
      "customField286" => {
        "name" => "Cécile's 1st Scored List", "type" => "CustomField::Hierarchy::Item",
        "_links" => { "allowedValues" => { "href" => "/api/v3/custom_fields/286/items" } }
      }
    }.freeze

    CF_ERRORS = CF_SCHEMA.to_h { |field, node| [field, { "message" => "#{node["name"]} can't be blank." }] }.freeze

    def stub_schema_form(schema, errors, retry_errors: {})
      stub_request(:post, "#{API}/work_packages/form")
        .to_return(status: 200, body: JSON.generate(
          "_embedded" => { "validationErrors" => errors, "schema" => schema }
        )).then.to_return(status: 200, body: JSON.generate(
          "_embedded" => { "validationErrors" => retry_errors, "schema" => schema }
        ))
    end

    def stub_hierarchy_items(id, leaf_id)
      stub_request(:get, "#{API}/custom_fields/#{id}/items").to_return(status: 200, body: JSON.generate(
        "_embedded" => { "elements" => [
          { "id" => 0, "label" => nil, "_links" => { "self" => { "href" => "/api/v3/custom_field_items/root" } } },
          { "id" => leaf_id, "label" => "a leaf",
            "_links" => { "self" => { "href" => "/api/v3/custom_field_items/#{leaf_id}" } } }
        ] }
      ))
    end

    def test_allowlisted_fields_are_filled_and_the_work_package_is_created
      stub_schema_form(CF_SCHEMA, CF_ERRORS)
      stub_hierarchy_items(223, 61)
      stub_hierarchy_items(286, 1801)
      stub_create(id: 991)

      out, = with_answer("y") { runner.run(%w[fix 4711]) }

      refute_includes out, "needs values I must not invent"
      assert_requested(:post, CREATE) do |req|
        links = JSON.parse(req.body)["_links"]
        links["customField158"] == [{ "href" => "/api/v3/versions/633" }] && # highest id
          links["customField205"] == [{ "href" => "/api/v3/custom_options/684" }] &&
          links["customField223"] == { "href" => "/api/v3/custom_field_items/61" } &&
          links["customField286"] == { "href" => "/api/v3/custom_field_items/1801" }
      end
    end

    # A required field the allowlist does not recognize must still refuse, even
    # alongside three the hack can fill.
    def test_an_unrecognized_field_among_allowlisted_ones_still_refuses
      schema = CF_SCHEMA.merge(
        "customField12" => { "name" => "Release train", "type" => "String", "_links" => {} }
      )
      errors = CF_ERRORS.merge("customField12" => { "message" => "Release train can't be blank" })
      stub_schema_form(schema, errors, retry_errors: { "customField12" => errors["customField12"] })
      stub_hierarchy_items(223, 61)
      stub_hierarchy_items(286, 1801)

      out, = with_answer("y") { runner.run(%w[fix 4711]) }

      assert_includes out, "Release train can't be blank"
      assert_not_requested :post, CREATE
    end

    # ── the writer's answer ─────────────────────────────────────────────────

    def test_needs_info_creates_nothing
      harness = FakeHarness.new("ANSWER:\nNEEDS_INFO\nThe backtrace is entirely inside activerecord.")
      out, = capture_io { runner(harness: harness).run(%w[fix 4711]) }

      assert_includes out, "activerecord"
      assert_not_requested :post, CREATE
    end

    # Safe to retry precisely because nothing has been created yet.
    def test_an_unusable_answer_is_retried_once_with_the_miss_named
      harness = FakeHarness.new("ANSWER:\nno block here", DRAFT)
      stub_form
      stub_create
      with_answer("y") { runner(harness: harness).run(%w[fix 4711]) }

      assert_equal 2, harness.prompts.length
      assert_includes harness.prompts.last, "BEGIN WORK PACKAGE"
      assert_requested :post, CREATE
    end

    def test_two_unusable_answers_stop_without_creating
      harness = FakeHarness.new("ANSWER:\nnope", "ANSWER:\nstill nope")
      capture_io { runner(harness: harness).run(%w[fix 4711]) }

      assert_equal 2, harness.prompts.length
      assert_not_requested :post, CREATE
    end

    # ── arguments ───────────────────────────────────────────────────────────

    def test_project_flag_overrides_the_configured_default
      stub_request(:get, "#{API}/projects/OTHER")
        .to_return(status: 200, body: JSON.generate(
          "name" => "Other", "_links" => { "createWorkPackage" => { "href" => "/x" } }
        ))
      stub_request(:get, "#{API}/projects/OTHER/types")
        .to_return(status: 200, body: JSON.generate("_embedded" => { "elements" => [] }))
      stub_form
      stub_create

      with_answer("y") { runner.run(%w[fix 4711 --project OTHER]) }

      assert_requested(:post, CREATE) do |req|
        JSON.parse(req.body).dig("_links", "project", "href") == "/api/v3/projects/OTHER"
      end
    end

    # ── which app ───────────────────────────────────────────────────────────
    #
    # The token is the only thing that MUST be configured. With no app id,
    # opilot SHOWS the apps this token can see rather than choosing one: an app
    # id is a hex string nobody types from memory, and picking one would mean
    # guessing between a staging and a production app.

    def test_no_app_id_shows_the_apps_and_asks
      ctx = build_ctx(@tmpdir, contributor_token: "gh-token", appsignal_app_id: nil)
      appsignal = FakeAppSignal.new(apps: [
        { "id" => "a1", "name" => "op", "environment" => "production" },
        { "id" => "a2", "name" => "op", "environment" => "staging" }
      ])
      err = assert_raises(OPilot::FatalError) { runner(ctx: ctx, appsignal: appsignal).run(%w[fix 4711]) }

      assert_includes err.message, "--app <app-id-or-name>"
      assert_includes err.message, "a2  op (staging)", "the ids are listed so one can be copied"
      assert_empty appsignal.fetched
    end

    # Listing apps is a second API call that a restricted token may refuse. That
    # must not turn "name your app" into an API error.
    def test_a_token_that_cannot_list_apps_still_gets_the_instruction
      ctx = build_ctx(@tmpdir, contributor_token: "gh-token", appsignal_app_id: nil)
      appsignal = Object.new
      def appsignal.applications = raise(Clients::AppSignal::Error, "forbidden")

      err = assert_raises(OPilot::FatalError) { runner(ctx: ctx, appsignal: appsignal).run(%w[fix 4711]) }
      assert_includes err.message, "APPSIGNAL_APP_ID"
      assert_includes err.message, "forbidden"
    end

    def test_the_configured_app_never_lists_apps
      appsignal = FakeAppSignal.new
      stub_form
      stub_create
      with_answer("y") { runner(appsignal: appsignal).run(%w[fix 4711]) }

      assert_equal 0, appsignal.apps_called
      assert_equal [[APP, "4711"]], appsignal.fetched
    end

    def test_the_app_flag_wins_over_the_configured_one
      appsignal = FakeAppSignal.new
      stub_form
      stub_create
      with_answer("y") { runner(appsignal: appsignal).run(["fix", "4711", "--app", "89abcdef0123456789abcdef"]) }

      assert_equal [["89abcdef0123456789abcdef", "4711"]], appsignal.fetched
    end

    # An app NAME is what a person reads off the AppSignal URL bar; the API only
    # takes the 24-hex id, and answers a name with a bare "Object not found".
    def test_an_app_name_is_resolved_to_its_id
      ctx = build_ctx(@tmpdir, contributor_token: "gh-token", appsignal_app_id: "edge-trials")
      appsignal = FakeAppSignal.new(apps: [
        { "id" => "0123456789abcdef01234567", "name" => "edge-trials", "environment" => "production" }
      ])
      stub_form
      stub_create
      with_answer("y") { runner(ctx: ctx, appsignal: appsignal).run(%w[fix 4711]) }

      assert_equal [["0123456789abcdef01234567", "4711"]], appsignal.fetched
    end

    # One name in two environments. staging and production must never be guessed
    # between.
    def test_an_ambiguous_app_name_is_refused
      ctx = build_ctx(@tmpdir, contributor_token: "gh-token", appsignal_app_id: "edge")
      appsignal = FakeAppSignal.new(apps: [
        { "id" => "0123456789abcdef01234567", "name" => "edge", "environment" => "production" },
        { "id" => "89abcdef0123456789abcdef", "name" => "edge", "environment" => "staging" }
      ])
      err = assert_raises(OPilot::FatalError) { runner(ctx: ctx, appsignal: appsignal).run(%w[fix 4711]) }

      assert_includes err.message, "names 2 apps"
      assert_empty appsignal.fetched
    end

    def test_an_unknown_app_name_lists_what_the_token_can_see
      ctx = build_ctx(@tmpdir, contributor_token: "gh-token", appsignal_app_id: "typo")
      err = assert_raises(OPilot::FatalError) { runner(ctx: ctx).run(%w[fix 4711]) }

      assert_includes err.message, "No AppSignal app is named \"typo\""
      assert_includes err.message, "#{APP}  op (production)"
    end

    # An API failure is a fact about the run, not a bug in opilot.
    def test_a_client_error_reads_as_one_line_not_a_backtrace
      appsignal = Object.new
      def appsignal.applications = []
      def appsignal.incident(*) = raise(Clients::AppSignal::Error, "HTTP 400: Object not found.")

      err = assert_raises(OPilot::FatalError) { runner(appsignal: appsignal).run(%w[fix 4711]) }
      assert_includes err.message, "AppSignal: HTTP 400"
    end

    # `fix` is the only verb, so a bare number cannot mean anything else.
    def test_a_bare_incident_number_is_accepted
      appsignal = FakeAppSignal.new
      stub_form
      stub_create
      with_answer("y") { runner(appsignal: appsignal).run(%w[4711]) }

      assert_equal [[APP, "4711"]], appsignal.fetched
    end

    # --project decides where a work package is CREATED, so it is asked for only
    # on the path that creates one. A re-run resumes the build and creates
    # nothing, and must not be refused for a project it will never use.
    def test_an_already_created_incident_resumes_the_build_without_a_project
      dir = Helpers.incident_dir(@ctx, APP, "4711")
      dir.mkpath
      (dir / "wp_id.txt").write("991")

      ctx       = build_ctx(@tmpdir, contributor_token: "gh-token", appsignal_project: nil)
      fix_runner = FakeFixRunner.new
      appsignal  = FakeAppSignal.new
      capture_io { runner(ctx: ctx, appsignal: appsignal, fix_runner: fix_runner).run(%w[fix 4711]) }

      assert_equal ["991"], fix_runner.shipped
      assert_empty appsignal.fetched, "a re-run must not re-read the incident"
    end

    # The operator can see the project's real type list; the writer is guessing
    # from a backtrace. So --type wins over the drafted TYPE: line.
    def test_the_type_flag_overrides_the_drafted_type
      stub_form
      stub_create
      # The draft names no type this project has, so only the flag can supply one.
      draft = DRAFT.sub("TYPE: BUG", "TYPE: Nonsense")
      with_answer("y") { runner(harness: FakeHarness.new(draft)).run(%w[fix 4711 --type BUG]) }

      assert_requested(:post, CREATE) do |req|
        JSON.parse(req.body).dig("_links", "type", "href") == "/api/v3/types/7"
      end
    end

    # A well-shaped call with a bad flag gets a complaint that names the flags
    # the command takes — not a usage line pretending the flag was an argument.
    def test_an_unknown_flag_names_the_flags_that_exist
      _out, err = capture_io do
        assert_raises(OPilot::FatalError) { runner.run(%w[fix 4711 --bogus x]) }
      end
      assert_includes err, "unknown flag --bogus"
      assert_includes err, "--project"
    end

    def test_no_project_anywhere_is_a_named_failure
      ctx = build_ctx(@tmpdir, contributor_token: "gh-token", appsignal_project: nil)
      err = assert_raises(OPilot::FatalError) { runner(ctx: ctx).run(%w[fix 4711]) }
      assert_includes err.message, "OPILOT_APPSIGNAL_PROJECT"
    end

    def test_a_non_numeric_incident_is_rejected
      assert_raises(OPilot::FatalError) { capture_io { runner.run(%w[fix not-a-number]) } }
    end

    def test_an_unknown_subcommand_is_rejected
      assert_raises(OPilot::FatalError) { capture_io { runner.run(%w[explode]) } }
    end
  end
end
