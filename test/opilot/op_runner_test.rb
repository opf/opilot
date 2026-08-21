require_relative "../test_helper"
require "tmpdir"

module OPilot
  class OpRunnerTest < Minitest::Test
    BASE = "https://op.test".freeze

    # `op` needs the OpenProject credentials and nothing else — notably not the
    # repo registry, which is why it calls #load_openproject_config! rather than
    # #load_config!. A double with no `repos` at all proves that stays true.
    CtxDouble = Struct.new(:op_url, :token, keyword_init: true) do
      def load_openproject_config!; end
    end

    def setup
      @ctx = CtxDouble.new(op_url: BASE, token: "tok")
    end

    def run_op(*args)
      capture_io { OpRunner.new(@ctx).run(args) }
    end

    def run_op!(*args)
      out = err = nil
      error = nil
      out, err = capture_io { error = assert_raises(OPilot::FatalError) { OpRunner.new(@ctx).run(args) } }
      [out, err, error]
    end

    # --- the stdout contract ------------------------------------------------

    def test_stdout_carries_only_pretty_json_so_it_pipes
      stub_request(:get, "#{BASE}/api/v3/users/me").to_return(status: 200, body: '{"name":"OPilot Bot"}')

      out, err = run_op("me")

      assert_equal JSON.pretty_generate({ "name" => "OPilot Bot" }) + "\n", out,
                   "no log_script prefix, no ANSI, nothing but the payload"
      assert_empty err
      assert_equal({ "name" => "OPilot Bot" }, JSON.parse(out), "and it round-trips through a parser")
    end

    def test_a_failing_request_puts_the_body_on_stdout_and_the_status_on_stderr
      # A 422's validation payload is the whole reason to run this by hand, so it
      # has to survive `| jq` — which means stdout, not stderr.
      stub_request(:get, "#{BASE}/api/v3/work_packages/42")
        .to_return(status: 422, body: '{"message":"bad filter"}')

      out, err, error = run_op!("wp", "get", "42")

      assert_equal({ "message" => "bad filter" }, JSON.parse(out))
      assert_includes err, "HTTP 422"
      assert_equal error.class.name, error.message,
                   "a bare FatalError, so bin/opilot exits 1 without an Error: line burying the body"
    end

    def test_a_non_json_response_is_reported_rather_than_printed_as_nothing
      # HTTP.get_json swallows an unparseable body in its `rescue nil`, so an
      # HTML 502 from a proxy would otherwise print absolutely nothing.
      stub_request(:get, "#{BASE}/api/v3/users/me")
        .to_return(status: 200, body: "<html>502 Bad Gateway</html>")

      out, err, = run_op!("me")

      assert_empty out
      assert_includes err, "response body was not JSON"
    end

    def test_a_network_failure_is_reported_without_a_ruby_backtrace
      stub_request(:get, "#{BASE}/api/v3/users/me").to_raise(SocketError.new("no route"))

      out, err, = run_op!("me")

      assert_empty out
      assert_includes err, "HTTP request failed"
      refute_includes err, "op_runner.rb:", "an exception trace is not a user-facing error"
    end

    # --- one command per client read method ---------------------------------

    def test_every_read_command_reaches_its_own_endpoint
      {
        %w[me]                     => "#{BASE}/api/v3/users/me",
        %w[wp get 42]              => "#{BASE}/api/v3/work_packages/42",
        %w[wp inspect 42]          => "#{BASE}/api/v3/work_packages/42",
        %w[wp activities 42]       => "#{BASE}/api/v3/work_packages/42/activities",
        %w[wp reactions 42]        => "#{BASE}/api/v3/work_packages/42/activities_emoji_reactions",
        %w[project get 7]          => "#{BASE}/api/v3/projects/7",
        %w[project types 7]        => "#{BASE}/api/v3/projects/7/types",
        %w[status list]            => "#{BASE}/api/v3/statuses",
        %w[doc get 3]              => "#{BASE}/api/v3/documents/3",
        %w[doc attachments 3]      => "#{BASE}/api/v3/documents/3/attachments?pageSize=100",
      }.each do |args, url|
        endpoint = stub_request(:get, url).to_return(status: 200, body: "{}")
        out, err = run_op(*args)
        assert_requested endpoint, times: 1
        assert_equal "{}\n", out, "#{args.join(" ")} emitted JSON"
        assert_empty err, "#{args.join(" ")} said nothing on stderr"
        WebMock.reset!
      end
    end

    def test_wp_relations_resolves_the_numeric_id_before_filtering_on_it
      # The `involved` filter coerces to Integer, so a semantic display id
      # matches nothing at all — an empty result that reads as "no relations".
      lookup = stub_request(:get, "#{BASE}/api/v3/work_packages/STC-162")
               .to_return(status: 200, body: '{"id":9182,"displayId":"STC-162"}')
      filters = Clients::HTTP.encode_filters(Clients::OpenProject.filter("involved", "=", 9182))
      relations = stub_request(:get, "#{BASE}/api/v3/relations?filters=#{filters}&pageSize=100")
                  .to_return(status: 200, body: '{"total":0}')

      out, = run_op("wp", "relations", "STC-162")

      assert_requested lookup
      assert_requested relations
      assert_equal({ "total" => 0 }, JSON.parse(out))
    end

    def test_wp_relations_reports_an_unreadable_work_package_rather_than_filtering_on_nothing
      stub_request(:get, "#{BASE}/api/v3/work_packages/42").to_return(status: 404, body: "{}")
      never = stub_request(:get, %r{/api/v3/relations})

      _out, err, = run_op!("wp", "relations", "42")

      assert_includes err, "could not read the work package"
      assert_not_requested never
    end

    def test_status_list_survives_the_one_read_method_that_raises
      # `statuses` uses get_json!, which raises on non-200 while every sibling
      # returns [code, nil]. The surface must not leak that asymmetry.
      stub_request(:get, "#{BASE}/api/v3/statuses").to_return(status: 404, body: "{}")

      out, err, = run_op!("status", "list")

      assert_empty out
      assert_includes err, "404"
      refute_includes err, "Clients::HTTP::Error", "reported, not raised through"
    end

    def test_doc_list_resolves_a_project_identifier_the_way_the_client_does
      lookup = stub_request(:get, "#{BASE}/api/v3/projects/my-project")
               .to_return(status: 200, body: '{"id":7}')
      filters = Clients::HTTP.encode_filters(Clients::OpenProject.filter("project", "=", 7))
      listing = stub_request(:get, "#{BASE}/api/v3/documents?pageSize=100&offset=1&filters=#{filters}")
                .to_return(status: 200, body: '{"total":2}')

      out, = run_op("doc", "list", "my-project")

      assert_requested lookup
      assert_requested listing
      assert_equal({ "total" => 2 }, JSON.parse(out))
    end

    # --- wp create ----------------------------------------------------------
    #
    # The one action that writes. A work package can never be deleted, so the
    # payload must be exactly what the flags say and --dry-run must POST nothing.

    def create_url;  "#{BASE}/api/v3/work_packages?notify=false"; end

    def stub_create(status: 201, body: '{"id":99,"subject":"Add a toast"}')
      stub_request(:post, create_url).to_return(status: status, body: body)
    end

    def created_payload
      payload = nil
      stub_request(:post, create_url).to_return do |req|
        payload = JSON.parse(req.body)
        { status: 201, body: '{"id":99,"subject":"Add a toast"}' }
      end
      yield
      payload
    end

    def test_wp_create_sends_the_flags_as_the_v3_payload
      payload = created_payload do
        run_op("wp", "create", "--project", "demo", "--type", "5", "--subject", "Add a toast",
               "--description", "Rosanna asked for it.")
      end

      assert_equal "Add a toast", payload["subject"]
      assert_equal "/api/v3/projects/demo", payload.dig("_links", "project", "href")
      assert_equal({ "format" => "markdown", "raw" => "Rosanna asked for it." }, payload["description"])
      assert_equal "/api/v3/types/5", payload.dig("_links", "type", "href"), "every payload names its type"
    end

    def test_wp_create_prints_the_created_work_package_on_stdout
      stub_create
      out, err = run_op("wp", "create", "--project", "7", "--type", "5", "--subject", "Add a toast")
      assert_equal({ "id" => 99, "subject" => "Add a toast" }, JSON.parse(out))
      assert_empty err
    end

    def test_wp_create_needs_a_project_and_a_subject
      never = stub_request(:post, create_url)

      _out, err, = run_op!("wp", "create", "--type", "5", "--subject", "Add a toast")
      assert_includes err, "Usage:"
      _out, err, = run_op!("wp", "create", "--project", "7", "--type", "5")
      assert_includes err, "Usage:"

      assert_not_requested never
    end

    def test_wp_create_resolves_a_type_name_on_the_project
      types = stub_request(:get, "#{BASE}/api/v3/projects/7/types").to_return(
        status: 200, body: JSON.generate("_embedded" => { "elements" => [
          { "id" => 5, "name" => "Feature" }, { "id" => 8, "name" => "BUG" }
        ] })
      )

      payload = created_payload do
        # Case-insensitive: instances style these names inconsistently.
        run_op("wp", "create", "--project", "7", "--subject", "Add a toast", "--type", "bug")
      end

      assert_requested types
      assert_equal "/api/v3/types/8", payload.dig("_links", "type", "href")
    end

    def test_wp_create_passes_a_numeric_type_straight_through
      never = stub_request(:get, "#{BASE}/api/v3/projects/7/types")

      payload = created_payload do
        run_op("wp", "create", "--project", "7", "--subject", "Add a toast", "--type", "5")
      end

      assert_equal "/api/v3/types/5", payload.dig("_links", "type", "href")
      assert_not_requested never
    end

    def test_wp_create_lists_the_projects_types_when_the_name_is_unknown
      stub_request(:get, "#{BASE}/api/v3/projects/7/types").to_return(
        status: 200, body: JSON.generate("_embedded" => { "elements" => [{ "id" => 5, "name" => "Feature" }] })
      )
      never = stub_request(:post, create_url)

      _out, err, = run_op!("wp", "create", "--project", "7", "--subject", "x", "--type", "Epic")

      assert_includes err, "no type named"
      assert_includes err, "Feature", "and what it does offer"
      # The name is resolved before the write, not turned into an opaque 422.
      assert_not_requested never
    end

    def test_wp_create_takes_the_description_from_a_file
      Dir.mktmpdir do |dir|
        path = File.join(dir, "body.md")
        File.write(path, "## Context\nRosanna asked for it.\n")

        payload = created_payload do
          run_op("wp", "create", "--project", "7", "--type", "5", "--subject", "x", "--description-file", path)
        end

        assert_includes payload.dig("description", "raw"), "Rosanna asked for it."
      end
    end

    def test_wp_create_refuses_both_description_forms
      never = stub_request(:post, create_url)
      _out, err, = run_op!("wp", "create", "--project", "7", "--type", "5", "--subject", "x",
                           "--description", "a", "--description-file", "b")
      assert_includes err, "not both"
      assert_not_requested never
    end

    def test_wp_create_payload_json_is_sent_whole
      payload = created_payload do
        run_op("wp", "create", "--payload-json", '{"subject":"Raw one"}')
      end
      assert_equal({ "subject" => "Raw one" }, payload)
    end

    # Rejected, not merged: a half-overridden payload is the kind of thing you
    # only notice after a POST that cannot be undone.
    def test_wp_create_refuses_payload_json_together_with_the_field_flags
      never = stub_request(:post, create_url)

      _out, err, = run_op!("wp", "create", "--payload-json", "{}", "--subject", "x")
      assert_includes err, "not both"
      assert_includes err, "--subject", "and which flag was the other one"

      _out, err, = run_op!("wp", "create", "--payload-json", "not json")
      assert_includes err, "not valid JSON"

      assert_not_requested never
    end

    # The `parent` link setter resolves by primary key only
    # (WorkPackage.visible.find_by(id:)), so a semantic id must be looked up here
    # or it reaches the API as an unresolvable link.
    def test_wp_create_resolves_a_semantic_parent_to_its_numeric_id
      lookup = stub_request(:get, "#{BASE}/api/v3/work_packages/PROJ-12")
        .to_return(status: 200, body: '{"id":42,"displayId":"PROJ-12"}')

      payload = created_payload do
        run_op("wp", "create", "--project", "7", "--type", "5", "--subject", "x", "--parent", "PROJ-12")
      end

      assert_requested lookup
      assert_equal "/api/v3/work_packages/42", payload.dig("_links", "parent", "href")
    end

    # Resolved BEFORE the POST: a wrong id must fail while nothing exists yet.
    def test_wp_create_resolves_the_references_before_creating_anything
      stub_request(:get, "#{BASE}/api/v3/work_packages/PROJ-99").to_return(status: 404, body: "{}")
      never = stub_request(:post, create_url)

      _out, err, = run_op!("wp", "create", "--project", "7", "--type", "5", "--subject", "x", "--relates", "PROJ-99")

      assert_includes err, "could not read that work package"
      assert_not_requested never
    end

    def test_wp_create_relates_resolves_both_sides_to_numeric_ids
      stub_create
      lookup = stub_request(:get, "#{BASE}/api/v3/work_packages/PROJ-12")
        .to_return(status: 200, body: '{"id":42}')
      relation = stub_request(:post, "#{BASE}/api/v3/work_packages/99/relations?notify=false")
        .with(body: { "type" => "relates",
                      "_links" => { "to" => { "href" => "/api/v3/work_packages/42" } } })
        .to_return(status: 201, body: "{}")

      run_op("wp", "create", "--project", "7", "--type", "5", "--subject", "x", "--relates", "proj-12")

      assert_requested lookup
      assert_requested relation
    end

    def test_wp_create_prints_the_work_package_even_when_the_relation_fails
      stub_create
      stub_request(:get, "#{BASE}/api/v3/work_packages/42").to_return(status: 200, body: '{"id":42}')
      stub_request(:post, "#{BASE}/api/v3/work_packages/99/relations?notify=false")
        .to_return(status: 403, body: '{"message":"no permission"}')

      out, err, = run_op!("wp", "create", "--project", "7", "--type", "5", "--subject", "x", "--relates", "42")

      assert_includes out, '"id": 99', "the create cannot be undone, so the id must reach the operator"
      assert_includes err, "created but not linked"
    end

    # --- wp form, and the fields a project requires -------------------------

    def form_url; "#{BASE}/api/v3/work_packages/form"; end

    FORM_BODY = JSON.generate(
      "_type" => "Form",
      "_embedded" => {
        "validationErrors" => {
          "customField205" => { "message" => "Cécile List Type Multi Select Custom Field can't be blank." }
        }
      }
    ).freeze

    def form_payload
      payload = nil
      stub_request(:post, form_url).to_return do |req|
        payload = JSON.parse(req.body)
        { status: 200, body: FORM_BODY }
      end
      yield
      payload
    end

    # The form answers 200 for a payload it rejects — validation errors are its
    # normal output — so the body must reach stdout, not a raised error.
    def test_wp_form_prints_what_the_project_requires
      stub_request(:post, form_url).to_return(status: 200, body: FORM_BODY)

      out, err = run_op("wp", "form", "--project", "TTP2", "--type", "1")

      assert_includes out, "customField205"
      assert_includes JSON.parse(out).dig("_embedded", "validationErrors").keys, "customField205"
      assert_empty err
    end

    # Only --project: being told what is missing is the point, so a missing
    # subject is part of the answer rather than a reason to refuse the call.
    def test_wp_form_needs_only_a_project
      payload = form_payload { run_op("wp", "form", "--project", "TTP2", "--type", "1") }

      refute payload.key?("subject")
      assert_equal "/api/v3/projects/TTP2", payload.dig("_links", "project", "href")
    end

    # The schema object also holds _type, _links and _dependencies, so the
    # summary must not treat a string value as a field.
    SCHEMA_FORM = JSON.generate(
      "_type" => "Form",
      "_embedded" => {
        "validationErrors" => {
          "customField223" => { "message" => "Cécile Hierarchy SingleSelect Required CF can't be blank." }
        },
        "schema" => {
          "_type" => "Schema",
          "_dependencies" => [],
          "subject" => { "type" => "String", "name" => "Subject", "required" => true, "writable" => true },
          "createdAt" => { "type" => "DateTime", "name" => "Created on", "required" => true, "writable" => false },
          "assignee" => { "type" => "User", "name" => "Assignee", "required" => false, "writable" => true },
          # A list field carries its values; a hierarchy field carries one href.
          "customField205" => {
            "type" => "[]CustomOption", "name" => "Multi Select", "required" => true, "writable" => true,
            "_links" => { "allowedValues" => [{ "href" => "/api/v3/custom_options/1", "title" => "A" }] }
          },
          "customField223" => {
            "type" => "CustomField::Hierarchy::Item", "name" => "Hierarchy CF",
            "required" => true, "writable" => true,
            "_links" => { "allowedValues" => { "href" => "/api/v3/custom_fields/223/items" } }
          }
        }
      }
    ).freeze

    def test_wp_form_required_lists_only_what_must_be_filled
      stub_request(:post, form_url).to_return(status: 200, body: SCHEMA_FORM)

      out, err = run_op("wp", "form", "--project", "TTP2", "--type", "1", "--required")

      fields = JSON.parse(out).fetch("requiredFields")
      names  = fields.map { |f| f["field"] }
      assert_equal %w[subject customField205 customField223], names,
                   "required and writable only — not createdAt, not the optional assignee"
      assert_empty err

      # The shape of allowedValues is the answer to "where are the values":
      # an array means here, an object means fetch that href.
      list = fields.find { |f| f["field"] == "customField205" }
      assert_kind_of Array, list["allowedValues"]
      hierarchy = fields.find { |f| f["field"] == "customField223" }
      assert_equal "/api/v3/custom_fields/223/items", hierarchy.dig("allowedValues", "href")
      assert_includes hierarchy["error"], "can't be blank", "and what the instance says about it now"
    end

    def test_cf_items_lists_a_hierarchy_fields_values
      items = stub_request(:get, "#{BASE}/api/v3/custom_fields/223/items")
        .to_return(status: 200, body: '{"_embedded":{"elements":[{"id":9,"label":"Tier one"}]}}')

      out, err = run_op("cf", "items", "223")

      assert_requested items
      assert_equal "Tier one", JSON.parse(out).dig("_embedded", "elements", 0, "label")
      assert_empty err
    end

    def test_cf_rejects_an_unknown_action
      _out, err, = run_op!("cf", "options", "223")
      assert_includes err, "unknown cf action"
      assert_includes err, "items"
    end

    def test_wp_create_dry_run_asks_openproject_and_creates_nothing
      never = stub_request(:post, create_url)
      form = stub_request(:post, form_url).to_return(status: 200, body: FORM_BODY)

      out, = run_op("wp", "create", "--project", "TTP2", "--type", "1", "--subject", "x", "--dry-run")

      assert_requested form
      assert_not_requested never
      assert_includes out, "customField205", "the instance's verdict, not opilot's own JSON"
    end

    def test_wp_create_field_and_link_fill_custom_fields
      payload = created_payload do
        # --type is mandatory alongside a custom field; a numeric one needs no lookup.
        run_op("wp", "create", "--project", "7", "--subject", "x", "--type", "5",
               "--field", "customField12=some text",
               "--link", "customField223=/api/v3/custom_options/9")
      end

      assert_equal "some text", payload["customField12"]
      assert_equal({ "href" => "/api/v3/custom_options/9" }, payload.dig("_links", "customField223"))
    end

    # A repeated --link is a multi-value field. A single one stays an object,
    # which the API accepts for those too (its setter flattens either shape).
    def test_wp_create_repeated_link_becomes_an_array
      payload = created_payload do
        run_op("wp", "create", "--project", "7", "--subject", "x", "--type", "5",
               "--link", "customField205=/api/v3/custom_options/1",
               "--link", "customField205=/api/v3/custom_options/2")
      end

      assert_equal [{ "href" => "/api/v3/custom_options/1" }, { "href" => "/api/v3/custom_options/2" }],
                   payload.dig("_links", "customField205")
    end

    # An id alone cannot become a link: the namespace differs per field type
    # (custom_options for a list, users for a user field), so it would be a guess.
    def test_wp_create_link_needs_an_href_and_says_where_to_find_one
      never = stub_request(:post, create_url)

      _out, err, = run_op!("wp", "create", "--project", "7", "--subject", "x", "--type", "5",
                           "--link", "customField205=9")

      assert_includes err, "needs an href"
      assert_includes err, "op wp form", "and where to get one"
      assert_not_requested never
    end

    def test_wp_create_accepts_custom_fields_alongside_a_type
      stub_request(:get, "#{BASE}/api/v3/projects/TTP2/types").to_return(
        status: 200, body: JSON.generate("_embedded" => { "elements" => [{ "id" => 1, "name" => "Task" }] })
      )

      payload = created_payload do
        run_op("wp", "create", "--project", "TTP2", "--subject", "x", "--type", "Task",
               "--link", "customField205=/api/v3/custom_options/685")
      end

      assert_equal "/api/v3/types/1", payload.dig("_links", "type", "href")
      assert_equal({ "href" => "/api/v3/custom_options/685" }, payload.dig("_links", "customField205"))
    end

    # --type is required of every payload, not only one carrying custom fields.
    # The API would pick a default, but a schema is per project AND type, and the
    # payload representer reads a custom field only when the type is named — so an
    # unnamed type is a value silently dropped waiting to happen.
    def test_wp_create_and_form_both_require_a_type
      never = stub_request(:post, create_url)
      never_form = stub_request(:post, form_url)

      _out, err, = run_op!("wp", "create", "--project", "7", "--subject", "x")
      assert_includes err, "--type <name|id>"

      _out, err, = run_op!("wp", "form", "--project", "7")
      assert_includes err, "--type <name|id>"

      assert_not_requested never
      assert_not_requested never_form
    end

    def test_wp_create_rejects_a_malformed_field_pair
      never = stub_request(:post, create_url)
      _out, err, = run_op!("wp", "create", "--project", "7", "--subject", "x", "--type", "5",
                           "--field", "customField12")
      assert_includes err, "<name>=<value>"
      assert_not_requested never
    end

    def test_wp_create_reports_a_rejected_payload_with_its_body
      stub_create(status: 422, body: '{"message":"subject can\'t be blank"}')

      out, err, = run_op!("wp", "create", "--project", "7", "--type", "5", "--subject", "x")

      assert_equal({ "message" => "subject can't be blank" }, JSON.parse(out))
      assert_includes err, "HTTP 422"
    end

    # --- wp list flags ------------------------------------------------------

    def wp_list_url(filters_json, page: 1, page_size: 50)
      filters = Clients::HTTP.encode_filters(filters_json)
      sort    = Clients::HTTP.encode_filters(Clients::OpenProject::SORT_UPDATED_AT)
      "#{BASE}/api/v3/work_packages?pageSize=#{page_size}&offset=#{page}" \
        "&filters=#{filters}&sortBy=#{sort}&includeSubprojects=true"
    end

    def test_wp_list_without_filters_sends_an_explicit_empty_array
      # Omitting `filters` makes OpenProject apply its own default (open WPs);
      # a command for inspecting the API must not silently scope its results.
      listing = stub_request(:get, wp_list_url("[]")).to_return(status: 200, body: '{"count":0}')

      run_op("wp", "list")

      assert_requested listing
    end

    def test_wp_list_builds_filters_from_shorthand
      expected = JSON.generate([{ "subject" => { "operator" => "~", "values" => ["login"] } },
                                { "status"  => { "operator" => "=", "values" => ["7"] } }])
      listing = stub_request(:get, wp_list_url(expected)).to_return(status: 200, body: '{"count":1}')

      run_op("wp", "list", "--filter", "subject~login", "--filter", "status=7")

      assert_requested listing
    end

    def test_wp_list_passes_filter_json_through_untouched
      raw = %Q([{"assignee":{"operator":"=","values":["me"]}}])
      listing = stub_request(:get, wp_list_url(raw)).to_return(status: 200, body: '{"count":1}')

      run_op("wp", "list", "--filter-json", raw)

      assert_requested listing
    end

    def test_wp_list_refuses_both_filter_forms_rather_than_dropping_one
      _out, err, = run_op!("wp", "list", "--filter", "subject~x", "--filter-json", "[]")
      assert_includes err, "not both"
    end

    def test_wp_list_paginates
      listing = stub_request(:get, wp_list_url("[]", page: 3, page_size: 5)).to_return(status: 200, body: "{}")
      run_op("wp", "list", "--page", "3", "--page-size", "5")
      assert_requested listing
    end

    def test_wp_list_rejects_junk_flag_values_before_making_a_request
      never = stub_request(:get, %r{/api/v3/work_packages})

      [%w[--page 0], %w[--page -1], %w[--page abc], %w[--page-size x]].each do |flag, value|
        _out, err, = run_op!("wp", "list", flag, value)
        assert_includes err, "positive integer", "#{flag} #{value}"
      end

      _out, err, = run_op!("wp", "list", "--filter", "no-operator")
      assert_includes err, "--filter must look like"

      assert_not_requested never
    end

    # --- doc download: the one non-JSON payload -----------------------------

    def test_doc_download_writes_bytes_to_out_and_keeps_stdout_empty
      url = "#{BASE}/api/v3/attachments/5/content"
      stub_request(:get, url).to_return(status: 200, body: "\x89PNG\r\n\x1a\n".b)

      Dir.mktmpdir do |dir|
        path = File.join(dir, "out.png")
        out, err = run_op("doc", "download", url, "--out", path)

        assert_equal "\x89PNG\r\n\x1a\n".b, File.binread(path)
        assert_empty out, "binary never goes to stdout"
        assert_includes err, "Wrote 8 bytes"
      end
    end

    def test_doc_download_refuses_without_out_rather_than_dumping_binary
      never = stub_request(:get, %r{/attachments})
      _out, err, = run_op!("doc", "download", "#{BASE}/api/v3/attachments/5/content")
      assert_includes err, "--out <path>"
      assert_not_requested never
    end

    # --- arguments ----------------------------------------------------------

    def test_ids_accept_a_pasted_hash_and_lowercase_semantic_spelling
      { "#42" => "42", " 42 " => "42", "proj-123" => "PROJ-123", "#PROJ-123" => "PROJ-123" }
        .each do |given, wanted|
          endpoint = stub_request(:get, "#{BASE}/api/v3/work_packages/#{wanted}").to_return(status: 200, body: "{}")
          run_op("wp", "get", given)
          assert_requested endpoint
          WebMock.reset!
        end
    end

    def test_an_unknown_resource_or_action_names_what_was_expected
      [%w[bogus], %w[wp bogus], %w[project bogus], %w[doc bogus], %w[status bogus]].each do |args|
        _out, err, = run_op!(*args)
        assert_includes err, "Expected one of:", "#{args.join(" ")} lists the alternatives"
        assert_includes err, "./opilot op --help"
      end
    end

    def test_a_wrongly_shaped_call_gets_an_arg_spec
      never = stub_request(:get, %r{/api/v3})
      { %w[wp get]           => "Usage: ./opilot op wp get <work-package-id>",
        %w[wp get 1 2]       => "Usage: ./opilot op wp get <work-package-id>",
        %w[project types]    => "Usage: ./opilot op project types <project-id-or-identifier>" }
        .each do |args, expected|
          _out, err, = run_op!(*args)
          assert_includes err, expected
        end
      assert_not_requested never
    end

    def test_a_specific_complaint_reads_as_one_rather_than_as_an_arg_spec
      # "Usage: ./opilot op me takes no arguments" answers the wrong question.
      never = stub_request(:get, %r{/api/v3})
      { %w[me extra]                => "op me: takes no arguments",
        %w[status list extra]       => "op status list: takes no arguments",
        %w[wp list --sort id]       => "op wp list: unknown flag --sort",
        %w[wp list --page]          => "op wp list: --page needs a value" }
        .each do |args, expected|
          _out, err, = run_op!(*args)
          assert_includes err, expected
          refute_includes err, "Usage: ./opilot op #{args.join(" ")}", "not dressed up as an arg spec"
        end
      assert_not_requested never
    end
  end
end
