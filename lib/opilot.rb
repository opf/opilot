require "zeitwerk"

module OPilot
  FatalError = Class.new(StandardError)

  # Seconds between two polls, for every agent loop.
  POLL_INTERVAL = 20

  # Zeitwerk loads lib/opilot/ on first reference: one constant per file, named
  # after the file. `require "opilot"` is the only require a caller needs.
  LOADER = Zeitwerk::Loader.new.tap do |loader|
    root = File.join(__dir__, "opilot")
    loader.tag = "opilot"
    loader.push_dir(root, namespace: OPilot)

    loader.inflector.inflect(
      "cli"              => "CLI",
      "ui"               => "UI",
      "pd"               => "PD",
      "http"             => "HTTP",
      "github"           => "GitHub",
      "openproject"      => "OpenProject",
      "openrouter"       => "OpenRouter",
      "appsignal"        => "AppSignal",
      "openspec"         => "OpenSpec",
      "appsignal_runner" => "AppSignalRunner"
    )

    # Folders that group files without adding a namespace.
    loader.collapse("#{root}/runners", "#{root}/github")

    # Files that reopen a module or hold several constants. Their index file
    # requires them, so they are always loaded with it.
    loader.ignore(
      "#{root}/helpers",                        # reopen Helpers; helpers.rb
      "#{root}/prompts/_shared.rb",             # Prompts::Prompt, Sections, the blocks; prompts.rb
      "#{root}/prompts/_blocks",                # prompt text, no Ruby
      "#{root}/roles.rb",                       # reopens Harness; harness.rb
      "#{root}/clients/openproject/errors.rb"   # the error classes; openproject.rb
    )

    loader.setup
  end
end
