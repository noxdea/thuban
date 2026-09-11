# frozen_string_literal: true

spec = Gem::Specification.load(File.expand_path("../thuban.gemspec", __dir__))
abort "unexpected runtime dependencies" unless spec.runtime_dependencies.map(&:name).sort == ["porrima"]

Dir[File.expand_path("../lib/**/*.rb", __dir__)].each do |file|
  source = File.read(file)
  abort "application dependency in #{file}" if source.match?(/\b(?:Canopus|Zaniah|Denebola)\b/)
  abort "diff algorithm in #{file}" if source.match?(/\b(?:bisect|myers|shortest_edit|lcs)\b/i)
  abort "display concern in #{file}" if source.include?("\e[")
end

puts "Git reader with a single diff dependency: OK"
