# frozen_string_literal: true

require_relative "test_helper"

class IgnoreMatcherTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-ignore-")
    @home = Dir.mktmpdir("thuban-home-")
    @config_home = Dir.mktmpdir("thuban-config-")
    @system_config = File.join(@home, "system.gitconfig")
    git("init", "-q")
  end

  def teardown
    FileUtils.remove_entry(@directory)
    FileUtils.remove_entry(@home)
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

  def test_load_resolves_configured_global_ignore_by_git_precedence
    ignores = {
      system: File.join(@home, "system.ignore"),
      xdg: File.join(@home, "xdg.ignore"),
      home: File.join(@home, "home.ignore"),
      repository: File.join(@home, "repository.ignore")
    }
    ignores.each { |name, path| write(path, "#{name}.ignored\n") }
    ignores.each_key { |name| write("#{name}.ignored", "x") }
    write(@system_config, "[core]\n excludesFile = #{ignores[:system]}\n")

    with_global_ignore do
      assert Thuban::IgnoreMatcher.load(@directory).ignored?("system.ignored")

      write(File.join(@config_home, "git", "config"), "[core]\n excludesFile = #{ignores[:xdg]}\n")
      matcher = Thuban::IgnoreMatcher.load(@directory)
      assert matcher.ignored?("xdg.ignored")
      refute matcher.ignored?("system.ignored")

      write(File.join(@home, ".gitconfig"), "[core]\n excludesFile = ~/home.ignore\n")
      matcher = Thuban::IgnoreMatcher.load(@directory)
      assert matcher.ignored?("home.ignored")
      refute matcher.ignored?("xdg.ignored")

      append(".git/config", "\n[core]\n excludesFile = #{ignores[:repository]}\n")
      matcher = Thuban::IgnoreMatcher.load(@directory)
      assert matcher.ignored?("repository.ignored")
      refute matcher.ignored?("home.ignored")
      ignores.each_key do |name|
        assert_equal git_ignored?("#{name}.ignored"), matcher.ignored?("#{name}.ignored"), name.to_s
      end
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

  def test_extra_files_can_reinclude_a_directory_with_nested_rules
    write(".gitignore", "vendor/\n")
    write("vendor/.gitignore", "*.secret\n")
    write("editor.ignore", "!vendor/\n")

    matcher = Thuban::IgnoreMatcher.load(@directory, extra_files: ["editor.ignore"], global: false)
    refute matcher.ignored?("vendor/file.txt")
    assert matcher.ignored?("vendor/key.secret")
  end

  def test_discovery_does_not_follow_symlinked_ignore_files
    git_ignore = File.join(@home, "git-ignore")
    editor_ignore = File.join(@home, "editor-ignore")
    write(git_ignore, "git-only.txt\n")
    write(editor_ignore, "editor-only.txt\n")
    begin
      File.symlink(git_ignore, File.join(@directory, ".gitignore"))
      File.symlink(editor_ignore, File.join(@directory, ".ignore"))
    rescue NotImplementedError, Errno::EACCES
      skip "symlinks are unavailable"
    end
    write("git-only.txt", "x")
    write("editor-only.txt", "x")

    matcher = Thuban::IgnoreMatcher.load(@directory, global: false)
    refute matcher.ignored?("git-only.txt")
    refute matcher.ignored?("editor-only.txt")
    assert_equal git_ignored?("git-only.txt"), matcher.ignored?("git-only.txt")
  end

  private

  def git(*arguments)
    _output, error, status = Open3.capture3("git", "-C", @directory, *arguments)
    assert status.success?, error
  end

  def git_ignored?(path)
    _output, _error, status = Open3.capture3(
      {"GIT_CONFIG_SYSTEM" => @system_config, "XDG_CONFIG_HOME" => @config_home, "HOME" => @home},
      "git", "-C", @directory, "check-ignore", "--no-index", "-q", "--", path
    )
    status.success?
  end

  def write(path, contents)
    absolute = File.absolute_path(path, @directory)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def append(path, contents)
    File.open(File.absolute_path(path, @directory), "ab") { |file| file.write(contents) }
  end

  def with_global_ignore
    previous_system, previous_xdg, previous_home = ENV["GIT_CONFIG_SYSTEM"], ENV["XDG_CONFIG_HOME"], ENV["HOME"]
    ENV["GIT_CONFIG_SYSTEM"] = @system_config
    ENV["XDG_CONFIG_HOME"] = @config_home
    ENV["HOME"] = @home
    yield
  ensure
    ENV["GIT_CONFIG_SYSTEM"], ENV["XDG_CONFIG_HOME"], ENV["HOME"] = previous_system, previous_xdg, previous_home
  end
end
