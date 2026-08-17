require_relative "../../test_helper"

module OPilot
  module Clients
    class OpenProjectTest < Minitest::Test
      BASE = "https://op.test".freeze

      def setup
        @op = OpenProject.new(BASE, "tok")
      end

      def documents_url(project_id)
        filters = HTTP.encode_filters(%Q([{"project":{"operator":"=","values":["#{project_id}"]}}]))
        "#{BASE}/api/v3/documents?pageSize=100&offset=1&filters=#{filters}"
      end

      def stub_documents(project_id)
        stub_request(:get, documents_url(project_id))
          .to_return(status: 200, body: '{"_embedded":{"elements":[]}}')
      end

      def test_post_activity_demotes_headings_so_the_activity_tab_stays_readable
        posted = nil
        stub_request(:post, "#{BASE}/api/v3/work_packages/42/activities")
          .with { |req| posted = JSON.parse(req.body); true }
          .to_return(status: 201, body: '{"id":9}')

        code, = @op.post_activity(42, comment: "## Approach\n\nDo the thing.", internal: false)

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

      def test_documents_resolves_a_project_identifier_first
        # The filter coerces its values to integers: an identifier matches
        # nothing rather than erroring, so the sweep would come back empty.
        lookup = stub_request(:get, "#{BASE}/api/v3/projects/my-project")
                 .to_return(status: 200, body: '{"id":42,"identifier":"my-project"}')
        listing = stub_documents(42)

        code, = @op.documents("my-project")

        assert_equal 200, code
        assert_requested lookup
        assert_requested listing
      end

      def test_documents_memoizes_the_resolved_identifier
        lookup = stub_request(:get, "#{BASE}/api/v3/projects/my-project")
                 .to_return(status: 200, body: '{"id":42}')
        stub_documents(42)

        3.times { @op.documents("my-project") }

        assert_requested lookup, times: 1
      end

      def test_documents_returns_the_failing_lookup_code_when_the_project_is_unreadable
        stub_request(:get, "#{BASE}/api/v3/projects/nope").to_return(status: 403, body: "{}")
        # The listing must not be attempted with an unresolved project.
        listing = stub_request(:get, %r{/api/v3/documents})

        code, body = @op.documents("nope")

        assert_equal 403, code
        assert_nil body
        assert_not_requested listing
      end

      def test_project_numeric_id_passes_a_numeric_id_through_without_a_request
        assert_equal [200, 42], @op.project_numeric_id("42")
        assert_not_requested :get, %r{/api/v3/projects}
      end
    end
  end
end
