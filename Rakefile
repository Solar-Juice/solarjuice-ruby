# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  # Warnings are on because a shadowed variable or an uninitialised ivar in a
  # gem with no dependencies is nearly always a real bug.
  t.warning = true
end

desc "Check every Ruby file parses"
task :lint do
  # A syntax check rather than a style tool: it catches the mistakes that matter
  # in CI without pulling a linter and its dependency tree into a gem whose
  # whole point is having none.
  files = FileList["lib/**/*.rb", "test/**/*.rb", "*.gemspec", "Rakefile"]
  failed = files.reject { |file| system("ruby", "-c", file, out: File::NULL) }
  raise "Syntax errors in: #{failed.join(', ')}" unless failed.empty?

  puts "#{files.size} files parse cleanly"
end

desc "Build the gem into pkg/"
task :build do
  require "fileutils"
  require_relative "lib/solar_juice/partner_api/version"

  FileUtils.mkdir_p("pkg")
  sh "gem build solarjuice-partner-api.gemspec " \
     "--output pkg/solarjuice-partner-api-#{SolarJuice::PartnerApi::VERSION}.gem"
end

task default: %i[lint test]
