require_relative "../test_helper"

module OPilot
  # A file whose name does not match its constant fails only when code first
  # names that constant. Eager loading finds every such file now.
  class LoaderTest < Minitest::Test
    def test_every_file_defines_its_constant
      OPilot::LOADER.eager_load
      assert defined?(OPilot::PD::Intake::Converter)
      assert defined?(OPilot::Clients::OpenProject::NotFound)
    end

    # A class that mixes in Helpers and defines a method of the same name
    # replaces it for every helper that calls it (Runners::Fix#commit once broke
    # Helpers#implement_plan this way).
    def test_no_class_shadows_a_helper
      OPilot::LOADER.eager_load
      lib = File.expand_path("../../lib", __dir__)
      helpers = Helpers.instance_methods(false) + Helpers.private_instance_methods(false)
      shadows = ObjectSpace.each_object(Class).select { |c| c.include?(Helpers) }.filter_map do |c|
        # Test doubles override helpers on purpose; only lib/ counts.
        own = ((c.instance_methods(false) + c.private_instance_methods(false)) & helpers)
              .select do |m|
                loc = c.instance_method(m).source_location
                loc != Helpers.instance_method(m).source_location && loc&.first&.start_with?(lib)
              end
        "#{c}: #{own.join(", ")}" unless own.empty?
      end
      assert_empty shadows
    end
  end
end
