require_relative "../../../test_helper"

module OPilot
  class OpenProjectLookupTest < Minitest::Test
    Lookup = Clients::OpenProject::Lookup
    Href   = Clients::OpenProject::Href

    BASE = "https://op.test".freeze

    def setup
      @api = Clients::OpenProject::Client.new(BASE, "tok")
      @lookup = Lookup.new(@api)
    end

    def collection(*elements)
      { status: 200, body: JSON.generate({ "_embedded" => { "elements" => elements } }) }
    end

    # --- resolvers ----------------------------------------------------------

    def test_status_is_resolved_by_name_and_the_list_is_read_once
      statuses = stub_request(:get, "#{BASE}/api/v3/statuses")
                 .to_return(collection({ "id" => 1, "name" => "New" }, { "id" => 3, "name" => "In progress" }))

      assert_equal 3, @lookup.status("in progress")["id"]
      assert_nil @lookup.status("Rejected"), "read fine, name absent: nil"
      assert_requested statuses, times: 1
    end

    def test_an_unreadable_list_raises_rather_than_reading_as_absent
      stub_request(:get, "#{BASE}/api/v3/priorities").to_return(status: 403, body: "{}")

      error = assert_raises(Clients::OpenProject::Forbidden) { @lookup.priority("High") }
      assert_equal 403, error.code
      assert_includes error.message, "priorities"
    end

    def test_a_network_failure_is_a_read_error_too
      stub_request(:get, "#{BASE}/api/v3/statuses").to_raise(SocketError.new("no route"))

      error = assert_raises(Clients::OpenProject::NetworkError) { @lookup.status("New") }
      assert_nil error.code
    end

    def test_type_takes_a_name_or_a_numeric_id
      stub_request(:get, "#{BASE}/api/v3/projects/demo/types").to_return(collection({ "id" => 5, "name" => "Bug" }))

      assert_equal 5, @lookup.type("demo", "BUG")["id"]
      assert_equal "Bug", @lookup.type("demo", "5")["name"]
      assert_nil @lookup.type("demo", "6")
    end

    def test_version_is_resolved_in_its_project
      stub_request(:get, "#{BASE}/api/v3/projects/demo/versions").to_return(collection({ "id" => 9, "name" => "17.6" }))
      assert_equal 9, @lookup.version("demo", "17.6")["id"]
    end

    def test_principal_uses_the_exact_name_filter_and_refuses_an_ambiguous_name
      filter = Clients::HTTP.encode_filters(Clients::OpenProject::Query.filter("name", "=", "Jane Doe"))
      stub_request(:get, "#{BASE}/api/v3/principals?pageSize=100&offset=1&filters=#{filter}")
        .to_return(collection({ "id" => 5, "name" => "Jane Doe" }))
      assert_equal 5, @lookup.principal("Jane Doe")["id"]

      two = Clients::HTTP.encode_filters(Clients::OpenProject::Query.filter("name", "=", "Sam"))
      stub_request(:get, "#{BASE}/api/v3/principals?pageSize=100&offset=1&filters=#{two}")
        .to_return(collection({ "id" => 1, "name" => "Sam" }, { "id" => 2, "name" => "Sam" }))
      assert_raises(Lookup::AmbiguousName) { @lookup.principal("Sam") }
    end

    def test_ids_pass_a_numeric_id_through_without_a_request
      assert_equal "42", @lookup.project_id("42")
      assert_equal "7", @lookup.work_package_id(7)
      assert_not_requested :get, %r{/api/v3/}
    end

    def test_ids_resolve_an_identifier_once
      project = stub_request(:get, "#{BASE}/api/v3/projects/my-project").to_return(status: 200, body: '{"id":42}')
      wp = stub_request(:get, "#{BASE}/api/v3/work_packages/PROJ-12").to_return(status: 200, body: '{"id":59942}')

      2.times do
        assert_equal "42", @lookup.project_id("my-project")
        assert_equal "59942", @lookup.work_package_id("PROJ-12")
      end
      assert_requested project, times: 1
      assert_requested wp, times: 1
    end

    def test_an_unreadable_id_raises_with_its_code
      stub_request(:get, "#{BASE}/api/v3/projects/nope").to_return(status: 403, body: "{}")
      assert_equal 403, assert_raises(Clients::OpenProject::Error) { @lookup.project_id("nope") }.code
    end

    # --- pagination ---------------------------------------------------------

    def test_all_work_packages_pages_until_the_total_and_stops_at_max
      stub_request(:get, %r{/api/v3/work_packages\?.*offset=1}).to_return(
        status: 200, body: JSON.generate({ "total" => 3, "_embedded" => { "elements" => [{ "id" => 1 }, { "id" => 2 }] } })
      )
      stub_request(:get, %r{/api/v3/work_packages\?.*offset=2}).to_return(
        status: 200, body: JSON.generate({ "total" => 3, "_embedded" => { "elements" => [{ "id" => 3 }] } })
      )

      code, all, total = @lookup.all_work_packages("[]", page_size: 2)
      assert_equal [200, [1, 2, 3], 3], [code, all.map { |w| w["id"] }, total]

      _code, capped, total = @lookup.all_work_packages("[]", page_size: 2, max: 1)
      assert_equal [[1], 3], [capped.map { |w| w["id"] }, total], "the total still says how many there are"
    end

    def test_all_work_packages_returns_the_failing_code_without_elements
      stub_request(:get, %r{/api/v3/work_packages\?}).to_return(status: 403, body: "{}")
      assert_equal [403, nil, 0], @lookup.all_work_packages("[]")
    end
  end
end
