require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/opilot/**/*_test.rb"
  t.verbose = false
end

task default: :test
