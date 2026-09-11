# frozen_string_literal: true

require_relative "lib/thuban/version"

Gem::Specification.new do |spec|
  spec.name = "thuban"
  spec.version = Thuban::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "A pure Ruby Git repository reader"
  spec.homepage = "https://github.com/noxdea/thuban"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "sig/**/*.rbs", "README.md", "CHANGELOG.md", "LICENSE.txt"].select { |path| File.file?(path) } }
  spec.require_paths = ["lib"]
  spec.add_dependency "porrima", "~> 0.1.0"
end
