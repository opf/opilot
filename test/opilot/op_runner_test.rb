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
