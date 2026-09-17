# frozen_string_literal: true

require_relative "test_helper"
require "rbconfig"

class LoadingTest < Minitest::Test
  def test_default_require_does_not_load_remote_providers_or_fiddle
    library = File.expand_path("../lib", __dir__)
    script = <<~'RUBY'
      require "thuban"
      providers = $LOADED_FEATURES.select do |feature|
        feature.tr("\\", "/").match?(%r{thuban/remote/(?:credentials|protocol|http|fetch|push|ssh|local)\.rb\z})
      end
      abort "remote providers loaded: #{providers.join(", ")}" unless providers.empty?
      abort "Fiddle loaded" if defined?(Fiddle) || $LOADED_FEATURES.any? { |feature| feature.match?(%r{(?:\A|[/\\])fiddle(?:[/\\.]|\z)}i) }
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-I#{library}", "-e", script)

    assert status.success?, output
  end

  def test_relative_require_loads_the_local_remote_provider
    library = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require #{File.join(library, "thuban.rb").inspect}
      connection = Thuban::Remote.open("https://example.invalid/repo.git")
      expected = #{File.join(library, "thuban", "remote", "http.rb").inspect}
      suffix = File.join("thuban", "remote", "http.rb")
      loaded = $LOADED_FEATURES.map { |feature| File.expand_path(feature) }.select { |feature| feature.end_with?(suffix) }
      abort "wrong HTTP provider: \#{loaded.join(", ")}" unless loaded == [expected]
      abort "wrong connection class" unless connection.instance_of?(Thuban::Remote::Connection)
      connection.close
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-e", script)

    assert status.success?, output
  end
end
