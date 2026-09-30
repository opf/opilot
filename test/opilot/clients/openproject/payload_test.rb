require_relative "../../../test_helper"

module OPilot
  class OpenProjectPayloadTest < Minitest::Test
    Payload = Clients::OpenProject::Payload

    def test_a_work_package_body_links_the_project_and_the_type
      body = Payload.work_package(project: 7, type: { "id" => 3 }, subject: "Fix it", description: "Details")

      assert_equal "Fix it", body["subject"]
      assert_equal({ "format" => "markdown", "raw" => "Details" }, body["description"])
      assert_equal({ "project" => { "href" => "/api/v3/projects/7" },
                     "type"    => { "href" => "/api/v3/types/3" } }, body["_links"])
    end

    def test_no_type_leaves_the_link_out_so_the_project_default_applies
      body = Payload.work_package(project: 7, type: nil, subject: "x", description: nil)
      refute body["_links"].key?("type")
      assert_equal "", body.dig("description", "raw")
    end

    def test_the_subject_is_cut_to_the_api_limit
      assert_equal 200, Payload.work_package(project: 7, type: nil, subject: "a" * 300, description: "").dig("subject").length
    end
  end
end
