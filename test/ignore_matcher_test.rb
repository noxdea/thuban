# frozen_string_literal: true

require_relative "test_helper"

class IgnoreMatcherTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-ignore-")
    @config_home = Dir.mktmpdir("thuban-config-")
    git("init", "-q")
  end

  def teardown
    FileUtils.remove_entry(@directory)
    FileUtils.remove_entry(@config_home)
  end

  def test_load_matches_git_precedence_and_globs
    write(File.join(@config_home, "git", "ignore"), "*.global\n")
    write(".git/info/exclude", "!keep.global\n*.info\n")
    patterns = <<~'IGNORE'
      *.log
      !important.log
      !keep.info
      /build/
      doc/**/*.md
      **/cache/
      [ab]?.tmp
    IGNORE
    write(".gitignore", patterns + "space\\ \ntrailing   \n")
    write("lib/.gitignore", "!debug.log\n/private.txt\n")
    paths = %w[
      drop.global keep.global drop.info keep.info trace.log important.log build/out.rb
      doc/readme.md doc/a/b/readme.md cache/data.txt lib/cache/data.txt
      ab.tmp c.tmp trailing lib/debug.log lib/private.txt lib/source.rb
    ] + ["space "]
    paths.each { |path| write(path, "x") }

    with_global_ignore do
      matcher = Thuban::IgnoreMatcher.load(@directory)
      paths.each do |path|
        assert_equal git_ignored?(path), matcher.ignored?(path), path
      end
    end
  end

  def test_load_can_disable_global_ignore
    write(File.join(@config_home, "git", "ignore"), "*.global\n")
    write("drop.global", "x")

    with_global_ignore do
      assert Thuban::IgnoreMatcher.load(@directory).ignored?("drop.global")
      refute Thuban::IgnoreMatcher.load(@directory, global: false).ignored?("drop.global")
    end
  end

  def test_load_reads_dot_ignore_and_explicit_extra_files_last
    write(".gitignore", "*.tmp\n")
    write(".ignore", "*.generated\n")
    write("config/editor.ignore", "!keep.tmp\n*.cache\n")
    matcher = Thuban::IgnoreMatcher.load(@directory, extra_files: ["config/editor.ignore"], global: false)

    assert matcher.ignored?("file.tmp")
    assert matcher.ignored?("file.generated")
    refute matcher.ignored?("config/keep.tmp")
    assert matcher.ignored?("config/file.cache")
    refute matcher.ignored?("file.cache")
  end

  def test_load_does_not_apply_ignore_files_below_an_ignored_directory
    write(".gitignore", "locked/\n!locked/keep.txt\n")
    write("locked/.gitignore", "!keep.txt\n")
    write("locked/keep.txt", "x")

    assert Thuban::IgnoreMatcher.load(@directory, global: false).ignored?("locked/keep.txt")
  end

  private

  def git(*arguments)
    _output, error, status = Open3.capture3("git", "-C", @directory, *arguments)
    assert status.success?, error
  end

  def git_ignored?(path)
    _output, _error, status = Open3.capture3(
      {"XDG_CONFIG_HOME" => @config_home, "HOME" => @config_home},
      "git", "-C", @directory, "check-ignore", "--no-index", "-q", "--", path
    )
    status.success?
  end

  def write(path, contents)
    absolute = File.absolute_path(path, @directory)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def with_global_ignore
    previous_xdg, previous_home = ENV["XDG_CONFIG_HOME"], ENV["HOME"]
    ENV["XDG_CONFIG_HOME"] = ENV["HOME"] = @config_home
    yield
  ensure
    ENV["XDG_CONFIG_HOME"], ENV["HOME"] = previous_xdg, previous_home
  end
end
