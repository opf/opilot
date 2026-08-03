require_relative "../../test_helper"
require "tmpdir"

module Chomper
  module PD
    # Stage 0 of the `pd` pipeline: resolve everything the later stages write
    # against, by name, and fail listing every problem at once. The point of the
    # class is that a mismatch surfaces HERE rather than as an opaque 422 (or a
    # warning after a spec PR is already up), so the tests are mostly about what
    # ends up in that message.
    class ResolvedIdsTest < Minitest::Test
      class FakeOP
        def initialize(project: nil, types: nil, statuses: nil, project_code: 200)
          @project      = project || { "name" => "Product X", "_links" => { "createWorkPackageImmediately" => {} } }
          @project_code = project_code
          @types        = types || [{ "id" => 7, "name" => "FEATURE" }, { "id" => 9, "name" => "IMPLEMENTATION" }]
          @statuses     = statuses || [{ "id" => 1, "name" => "New", "isClosed" => false },
                                       { "id" => 7, "name" => "In progress", "isClosed" => false },
                                       { "id" => 9, "name" => "Developed", "isClosed" => false },
                                       { "id" => 12, "name" => "Closed", "isClosed" => true }]
        end

        def project(_id)      = [@project_code, @project]
        def project_types(_id) = [200, { "_embedded" => { "elements" => @types } }]
        def statuses           = [200, { "_embedded" => { "elements" => @statuses } }]
      end

      def setup
        @tmpdir = Pathname(Dir.mktmpdir)
        @ctx    = Context.build(@tmpdir)
        @saved  = ENV.to_hash.slice("CHOMPER_PD_IMPLEMENTING_STATUS", "CHOMPER_PD_IMPLEMENTED_STATUS")
      end

      def teardown
        %w[CHOMPER_PD_IMPLEMENTING_STATUS CHOMPER_PD_IMPLEMENTED_STATUS].each do |key|
          @saved.key?(key) ? ENV[key] = @saved[key] : ENV.delete(key)
        end
        FileUtils.rm_rf(@tmpdir)
      end

      def resolve(op = FakeOP.new)
        ResolvedIds.new(@ctx, op: op).resolve!("42")
      end

      def test_it_caches_ids_types_and_statuses_with_their_closed_flags
        data = resolve

        assert_equal "42", data["project_id"]
        assert_equal 7, data.dig("types", "parent", "id")
        assert_equal 9, data.dig("types", "child", "id")
        assert_equal [12], ResolvedIds.closed_status_ids(data)
        assert_equal data, ResolvedIds.new(@ctx, op: Object.new).read, "and it round-trips through the cache"
      end

      # --- the statuses `pd implement` transitions through -------------------

      def test_a_missing_status_fails_here_rather_than_mid_implementation
        # Otherwise it surfaces as a warning at implement time — after the spec PR
        # is up and the code is committed.
        op = FakeOP.new(statuses: [{ "id" => 1, "name" => "New", "isClosed" => false }])
        error = assert_raises(Chomper::FatalError) { resolve(op) }

        assert_match(/no status named "In progress"/, error.message)
        assert_match(/no status named "Developed"/, error.message)
        assert_match(/Statuses on this instance: New/, error.message)
        assert_match(/CHOMPER_PD_IMPLEMENTING_STATUS/, error.message)
      end

      def test_status_names_match_case_insensitively
        # Instances style them inconsistently ("In progress", "In Progress").
        op = FakeOP.new(statuses: [{ "id" => 3, "name" => "In Progress" }, { "id" => 4, "name" => "DEVELOPED" }])
        resolve(op) # must not raise
      end

      def test_an_empty_status_name_is_not_required_to_exist
        ENV["CHOMPER_PD_IMPLEMENTED_STATUS"] = ""
        op = FakeOP.new(statuses: [{ "id" => 3, "name" => "In progress" }])
        resolve(op) # the transition is switched off, so nothing to resolve
      end

      def test_the_status_list_is_only_printed_when_a_status_is_what_failed
        # It is long on a real instance and would bury the type message.
        op = FakeOP.new(types: [{ "id" => 7, "name" => "FEATURE" }])
        error = assert_raises(Chomper::FatalError) { resolve(op) }

        assert_match(/no work-package type named "IMPLEMENTATION"/, error.message)
        refute_match(/Statuses on this instance/, error.message)
      end

      # --- write permission -------------------------------------------------

      def test_a_read_only_token_fails_before_a_proposal_exists
        # generate-wp POSTs work packages; OpenProject renders createWorkPackage*
        # only for a user with :add_work_packages, so their absence is an answer.
        op = FakeOP.new(project: { "name" => "Product X", "_links" => { "self" => {} } })
        error = assert_raises(Chomper::FatalError) { resolve(op) }

        assert_match(/cannot create work packages in project 42/, error.message)
        assert_match(/add_work_packages/, error.message)
      end

      def test_either_create_link_proves_the_permission
        op = FakeOP.new(project: { "name" => "Product X", "_links" => { "createWorkPackage" => {} } })
        resolve(op) # must not raise
      end

      def test_every_problem_is_reported_in_one_pass
        # One round trip of fixing, rather than one error per re-run.
        op = FakeOP.new(project: { "name" => "X", "_links" => {} }, types: [],
                        statuses: [{ "id" => 1, "name" => "New" }])
        error = assert_raises(Chomper::FatalError) { resolve(op) }

        assert_match(/cannot create work packages/, error.message)
        assert_match(/no work-package type named "FEATURE"/, error.message)
        assert_match(/no status named "In progress"/, error.message)
      end

      def test_an_unreadable_project_is_reported_as_such
        error = assert_raises(Chomper::FatalError) { resolve(FakeOP.new(project_code: 404)) }
        assert_match(/project 42 is not readable \(HTTP 404\)/, error.message)
      end
    end
  end
end
