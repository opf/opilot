require_relative "../../../test_helper"

module OPilot
  class OpenProjectResourceTest < Minitest::Test
    Resource = Clients::OpenProject::Resource
    Href     = Clients::OpenProject::Href

    def test_find_named_ignores_case_and_refuses_a_blank_name
      list = [{ "name" => "In progress" }, { "name" => "Closed" }]
      assert_equal "In progress", Resource.find_named(list, "IN PROGRESS")["name"]
      assert_nil Resource.find_named(list, " ")
      assert_nil Resource.find_named(list, "Open")
    end

    def test_type_list_keeps_id_and_name
      body = { "_embedded" => { "elements" => [{ "id" => 5, "name" => "Bug", "color" => "red" }] } }
      assert_equal [{ "id" => 5, "name" => "Bug" }], Resource.type_list(body)
      assert_equal [], Resource.type_list(nil)
    end

    def test_create_wp_allowed_reads_the_projects_own_links
      assert Resource.create_wp_allowed?("_links" => { "createWorkPackage" => { "href" => "/x" } })
      assert Resource.create_wp_allowed?("_links" => { "createWorkPackageImmediately" => { "href" => "/x" } })
      refute Resource.create_wp_allowed?("_links" => { "self" => { "href" => "/x" } })
      refute Resource.create_wp_allowed?({})
      refute Resource.create_wp_allowed?(nil)
    end

    def test_display_id_prefers_the_semantic_id
      assert_equal "PROJ-12", Resource.display_id("id" => 12, "displayId" => "PROJ-12")
      assert_equal "12",      Resource.display_id("id" => 12, "displayId" => "")
      assert_equal "12",      Resource.display_id("id" => 12)
    end

    def test_link_title_link_id_and_href_id_read_a_list_element
      wp = { "_links" => { "status" => { "href" => "/api/v3/statuses/3", "title" => "New" } } }
      assert_equal "New", Resource.link_title(wp, "status")
      assert_equal "3", Resource.link_id(wp, "status")
      assert_nil Resource.link_id(wp, "parent")
      assert_nil Resource.href_id("")
    end

    def test_href_builds_every_payload_link
      assert_equal({ "href" => "/api/v3/statuses/3" }, Href.link(Href.status(3)))
      assert_equal "/api/v3/work_packages/42", Href.work_package(42)
    end
  end
end
