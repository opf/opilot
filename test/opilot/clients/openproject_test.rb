require_relative "../../test_helper"

module OPilot
  module Clients
    class OpenProjectTest < Minitest::Test
      BASE = "https://op.test".freeze

      def setup
        @op = OpenProject::Client.new(BASE, "tok")
      end

      def documents_url(project_id)
        filters = HTTP.encode_filters(%Q([{"project":{"operator":"=","values":["#{project_id}"]}}]))
        "#{BASE}/api/v3/documents?pageSize=100&offset=1&filters=#{filters}"
      end

      def stub_documents(project_id)
        stub_request(:get, documents_url(project_id))
          .to_return(status: 200, body: '{"_embedded":{"elements":[]}}')
      end

      def test_add_comment_demotes_headings_so_the_activity_tab_stays_readable
        posted = nil
        stub_request(:post, "#{BASE}/api/v3/work_packages/42/activities")
          .with { |req| posted = JSON.parse(req.body); true }
          .to_return(status: 201, body: '{"id":9}')

        code, = @op.add_comment(42, comment: "## Approach\n\nDo the thing.", internal: false)

        assert_equal 201, code
        assert_equal "**Approach**\n\nDo the thing.", posted.dig("comment", "raw"),
                     "every comment goes through here, so the demotion belongs here"
        assert_equal false, posted["internal"], "visibility is untouched"
      end

      def test_documents_filters_on_a_numeric_id_directly
        listing = stub_documents(42)
        code, = @op.documents("42")

        assert_equal 200, code
        assert_requested listing
      end

      def test_documents_refuses_an_identifier_that_would_match_nothing
        listing = stub_request(:get, %r{/api/v3/documents})
        assert_raises(ArgumentError) { @op.documents("my-project") }
        assert_not_requested listing
      end

      def test_filter_emits_the_literals_its_three_call_sites_used_to_interpolate
        assert_equal %Q([{"involved":{"operator":"=","values":["42"]}}]),
                     OpenProject::Query.filter("involved", "=", 42),
                     "work_package_relations"
        assert_equal %Q([{"project":{"operator":"=","values":["7"]}}]),
                     OpenProject::Query.filter("project", "=", 7),
                     "documents"
        assert_equal %Q([{"comment":{"operator":"~","values":#{JSON.generate(["OPilot Bot"])}}}]),
                     OpenProject::Query.filter("comment", "~", "OPilot Bot"),
                     "OpenProject::Pull#mention_filter_json"
      end

      def test_filter_stringifies_values_because_the_encoded_query_is_the_identity
        # documents passes body["id"], an Integer. Left unstringified it emits
        # [42] rather than ["42"] and silently changes every URL built here.
        assert_equal OpenProject::Query.filter("project", "=", "7"), OpenProject::Query.filter("project", "=", 7)
      end

      def test_filter_escapes_through_json_so_a_display_name_cannot_break_the_query
        name = %Q(Bo"t \u{1F916})
        assert_equal [{ "comment" => { "operator" => "~", "values" => [name] } }],
                     JSON.parse(OpenProject::Query.filter("comment", "~", name))
      end

      # --- work_packages defaults ---------------------------------------------

      def test_work_packages_defaults_match_the_poll_that_used_to_hardcode_them
        sort = HTTP.encode_filters(OpenProject::Query::SORT_UPDATED_AT)
        poll = stub_request(:get, "#{BASE}/api/v3/work_packages?pageSize=50&offset=1" \
                                  "&filters=#{HTTP.encode_filters("[]")}&sortBy=#{sort}" \
                                  "&includeSubprojects=true")
               .to_return(status: 200, body: "{}")

        @op.work_packages(filters_json: "[]")

        assert_requested poll, times: 1
      end

      def test_work_packages_lets_a_caller_override_the_polls_policy
        sort  = HTTP.encode_filters(%Q([["id","asc"]]))
        other = stub_request(:get, "#{BASE}/api/v3/work_packages?pageSize=5&offset=2" \
                                   "&filters=#{HTTP.encode_filters("[]")}&sortBy=#{sort}" \
                                   "&includeSubprojects=false")
                .to_return(status: 200, body: "{}")

        @op.work_packages(filters_json: "[]", page: 2, page_size: 5,
                          sort_by: %Q([["id","asc"]]), include_subprojects: false)

        assert_requested other, times: 1
      end

      # --- attachment downloads and the API token -----------------------------

      def test_work_package_attachments_reads_the_nested_collection
        listing = stub_request(:get, "#{BASE}/api/v3/work_packages/PROJ-42/attachments")
                  .to_return(status: 200, body: '{"_embedded":{"elements":[]}}')

        code, = @op.work_package_attachments("PROJ-42")

        assert_equal 200, code
        assert_requested listing
      end

      def test_an_attachment_is_read_by_id
        # The route a comment's picture needs: it is claimed by the comment, so
        # the work package's own collection never carries it.
        one = stub_request(:get, "#{BASE}/api/v3/attachments/30381")
              .to_return(status: 200, body: '{"id":30381,"fileName":"shot.png"}')

        code, body = @op.attachment(30381)

        assert_equal 200, code
        assert_equal "shot.png", body["fileName"]
        assert_requested one
      end

      def test_a_relative_download_location_is_resolved_against_this_instance
        # `downloadLocation` is absolute only on external storage. With the files
        # on the instance itself it is the bare API path, which has no host to
        # connect to — and would read as "not this instance", withholding the
        # token from our own API.
        content = stub_request(:get, "#{BASE}/api/v3/attachments/5/content")
                  .with(basic_auth: ["apikey", "tok"])
                  .to_return(status: 200, body: "bytes")

        code, body = @op.download_attachment("/api/v3/attachments/5/content")

        assert_equal 200, code
        assert_equal "bytes", body
        assert_requested content
      end

      def test_download_attachment_authenticates_against_this_instance
        content = stub_request(:get, "#{BASE}/api/v3/attachments/5/content")
                  .with(basic_auth: ["apikey", "tok"])
                  .to_return(status: 200, body: "bytes")

        code, body = @op.download_attachment("#{BASE}/api/v3/attachments/5/content")

        assert_equal 200, code
        assert_equal "bytes", body
        assert_requested content
      end

      def test_download_attachment_withholds_the_token_from_any_other_host
        # `op doc download` takes this URL from argv, and a downloadLocation may
        # legitimately point straight at presigned storage. Either way the
        # OpenProject key must not be handed to somebody else's host.
        sent = nil
        stub_request(:get, "https://attacker.example/x")
          .with { |req| sent = req.headers.to_h.transform_keys(&:downcase); true }
          .to_return(status: 200, body: "bytes")

        @op.download_attachment("https://attacker.example/x")

        refute_nil sent, "the request was made"
        refute sent.key?("authorization"), "no credential of any kind left for that host"
      end

      def test_download_attachment_still_works_against_presigned_storage
        # The S3 shape: an off-origin URL that authenticates itself in its query
        # string. Withholding the token must not break it.
        presigned = stub_request(:get, "https://s3.example/bucket/f?X-Amz-Signature=abc")
                    .to_return(status: 200, body: "png")

        code, body = @op.download_attachment("https://s3.example/bucket/f?X-Amz-Signature=abc")

        assert_equal 200, code
        assert_equal "png", body
        assert_requested presigned
      end

      def test_on_this_instance_compares_scheme_host_and_port
        assert @op.on_this_instance?("#{BASE}/api/v3/attachments/5/content")
        refute @op.on_this_instance?("http://op.test/x"),      "scheme differs"
        refute @op.on_this_instance?("https://op.test:8443/x"), "port differs"
        refute @op.on_this_instance?("https://op.test.evil/x"), "host differs"
        refute @op.on_this_instance?("not a url"),              "unparseable is not this instance"
        assert @op.on_this_instance?("/api/v3/attachments/5/content"),
               "a relative path in this API's own response IS this instance"
      end

      def test_the_lock_version_helper_is_private_so_the_locking_dance_stays_in_one_place
        refute_respond_to @op, :with_lock_version
        assert @op.respond_to?(:with_lock_version, true), "still there, just not part of the surface"
      end

      def test_update_retries_once_on_a_conflict_with_a_fresh_lock_version
        stub_request(:get, "#{BASE}/api/v3/work_packages/42")
          .to_return({ status: 200, body: '{"lockVersion":1}' }, { status: 200, body: '{"lockVersion":2}' })
        sent = []
        stub_request(:patch, "#{BASE}/api/v3/work_packages/42?notify=false")
          .with { |req| sent << JSON.parse(req.body)["lockVersion"]; true }
          .to_return({ status: 409, body: "{}" }, { status: 200, body: '{"id":42}' })

        code, = @op.update_work_package(42, { "subject" => "New" })

        assert_equal 200, code
        assert_equal [1, 2], sent
      end

      def test_statuses_answers_a_code_like_every_other_read
        stub_request(:get, "#{BASE}/api/v3/statuses").to_return(status: 404, body: "{}")
        assert_equal 404, @op.statuses.code
      end

      def test_lookup_reads_reach_their_endpoints
        {
          -> { @op.priorities }                          => "#{BASE}/api/v3/priorities",
          -> { @op.project_versions("demo") }            => "#{BASE}/api/v3/projects/demo/versions",
          -> { @op.work_package_available_assignees(42) } => "#{BASE}/api/v3/work_packages/42/available_assignees",
          -> { @op.work_package_schema(7, 5) }           => "#{BASE}/api/v3/work_packages/schemas/7-5",
        }.each do |call, url|
          endpoint = stub_request(:get, url).to_return(status: 200, body: "{}")
          assert_equal 200, call.call.code
          assert_requested endpoint
        end
      end

      def test_principals_and_projects_carry_the_filter_and_paging
        filter = OpenProject::Query.filter("name", "=", "Jane Doe")
        principals = stub_request(:get, "#{BASE}/api/v3/principals?pageSize=100&offset=1&filters=#{HTTP.encode_filters(filter)}")
                     .to_return(status: 200, body: "{}")
        projects = stub_request(:get, "#{BASE}/api/v3/projects?pageSize=20&offset=2&filters=#{HTTP.encode_filters("[]")}")
                   .to_return(status: 200, body: "{}")

        @op.principals(filters_json: filter)
        @op.projects(page: 2, page_size: 20)

        assert_requested principals
        assert_requested projects
      end

      def test_update_form_validates_with_the_current_lock_version_and_saves_nothing
        stub_request(:get, "#{BASE}/api/v3/work_packages/42").to_return(status: 200, body: '{"lockVersion":3}')
        posted = nil
        form = stub_request(:post, "#{BASE}/api/v3/work_packages/42/form")
               .with { |req| posted = JSON.parse(req.body); true }
               .to_return(status: 200, body: '{"_embedded":{"validationErrors":{}}}')
        patch = stub_request(:patch, %r{/api/v3/work_packages/42})

        code, = @op.update_work_package_form(42, { "subject" => "New" })

        assert_equal 200, code
        assert_requested form
        assert_equal({ "subject" => "New", "lockVersion" => 3 }, posted,
                     "the update contract rejects a stale or missing lockVersion, so the form needs it too")
        assert_not_requested patch
      end

      def test_an_unreadable_work_package_answers_with_the_read_code_not_a_conflict
        stub_request(:get, "#{BASE}/api/v3/work_packages/42").to_return(status: 404, body: "{}")
        writes = stub_request(:any, %r{/work_packages/42(/form)?\?|/form})

        assert_equal 404, @op.update_work_package_form(42, { "subject" => "New" }).code
        assert_equal 404, @op.update_work_package(42, { "subject" => "New" }).code
        assert_not_requested writes
      end
    end
  end
end
