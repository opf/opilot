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
  end
end
