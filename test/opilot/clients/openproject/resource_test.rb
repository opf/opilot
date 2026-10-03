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

    # --- schemas ---

    FORM = {
      "_embedded" => {
        "schema" => {
          "_type" => "Schema", "_dependencies" => [], "_links" => {}, "_attributeGroups" => [],
          "subject"        => { "type" => "String", "name" => "Subject", "required" => true, "writable" => true },
          "id"             => { "type" => "Integer", "name" => "ID", "required" => true, "writable" => false },
          "description"    => { "type" => "Formattable", "name" => "Description", "required" => false },
          "customField223" => { "type" => "CustomField::Hierarchy::Item", "name" => "Area", "required" => true,
                                "writable" => true,
                                "_links" => { "allowedValues" => { "href" => "/api/v3/custom_fields/223/items" } } }
        },
        "validationErrors" => { "customField223" => { "message" => "Area can't be blank." } }
      }
    }.freeze

    def test_schema_fields_leave_out_the_keys_that_are_not_fields
      assert_equal %w[subject id description customField223], Resource.schema_fields(FORM.dig("_embedded", "schema")).keys
      assert_equal({}, Resource.schema_fields(nil))
    end

    def test_required_fields_are_the_writable_ones_with_their_error
      fields = Resource.required_fields(FORM)
      assert_equal %w[subject customField223], fields.map { |f| f["field"] }, "id is required but not writable"
      assert_equal "Area can't be blank.", fields.last["error"]
      assert_equal({ "href" => "/api/v3/custom_fields/223/items" }, fields.last["allowedValues"])
      refute fields.first.key?("error")
    end

    def test_schema_and_items_hrefs_give_their_ids
      assert_equal %w[7 5], Resource.schema_ids("/api/v3/work_packages/schemas/7-5")
      assert_nil Resource.schema_ids("/api/v3/work_packages/7")
      assert_equal "223", Resource.items_field_id("/api/v3/custom_fields/223/items")
      assert_nil Resource.items_field_id("/api/v3/work_packages/9/available_assignees")
    end

    def test_custom_field_values_read_attributes_and_links_and_drop_empty_ones
      wp = { "customField1" => { "raw" => " text " }, "customField2" => "", "customField3" => 4,
             "_links" => { "customField5" => { "title" => "Gold" },
                           "customField6" => [{ "title" => "a" }, { "title" => "b" }],
                           "customField7" => [], "status" => { "title" => "New" } } }
      assert_equal({ "customField1" => "text", "customField3" => 4, "customField5" => "Gold",
                     "customField6" => %w[a b] }, Resource.custom_field_values(wp))
    end
  end
end
