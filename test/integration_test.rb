# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

class IntegrationTest < Minitest::Test
  Edit = Struct.new(:kind, :old_line, :new_line)

  def setup
    @directory = Dir.mktmpdir("thuban-integration-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "core.autocrlf", "false")
    git("config", "maintenance.auto", "false")
    File.binwrite(File.join(@directory, "text.txt"), "first\nsecond\nthird\n")
    git("add", ".")
    git("commit", "-qm", "Initial text")
    @repository = Thuban::Repository.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_porrima_composes_with_staged_and_worktree_content
    before = @repository.staged_blob("text.txt")
    after = "first\nchanged\nthird\nnew\n"
    @repository.write("text.txt", after)
    diff = Porrima.diff(before, @repository.worktree_content("text.txt"), context: 0)

    assert_equal 2, diff.hunks.length
    restored = Porrima.revert(after, diff.hunks.last)
    @repository.write("text.txt", restored)
    assert_equal "first\nchanged\nthird\n", @repository.worktree_content("text.txt")
  end

  def test_blame_accepts_an_injected_differ
    File.binwrite(File.join(@directory, "text.txt"), "first\nchanged\nthird\n")
    git("add", ".")
    git("commit", "-qm", "Change middle line")
    calls = []
    differ = Object.new
    differ.define_singleton_method(:edits) do |before, after|
      calls << [before, after]
      [Edit.new(:equal, 1, 1), Edit.new(:equal, 3, 3)]
    end

    assert_equal [@repository.commit.parents.first, @repository.head, @repository.commit.parents.first],
      @repository.blame("text.txt", differ: differ).map(&:commit)
    assert_equal 1, calls.length
  end

  def test_write_preserves_mode_and_rejects_symlinks
    path = File.join(@directory, "text.txt")
    File.chmod(0o755, path)
    mode = File.stat(path).mode & 0o777
    @repository.write("text.txt", "updated\n")
    assert_equal mode, File.stat(path).mode & 0o777

    File.symlink("text.txt", File.join(@directory, "link.txt"))
    assert_raises(ArgumentError) { @repository.write("link.txt", "unsafe") }
  end

  def test_write_closes_temporary_file_and_preserves_a_failed_replacement
    path = File.join(@directory, "text.txt")
    with_closed_temporary_rename { @repository.write("text.txt", "updated\n") }
    assert_equal "updated\n", File.binread(path)

    with_closed_temporary_rename(fail_rename: true) do
      assert_raises(Errno::EACCES) { @repository.write("text.txt", "lost\n") }
    end
    assert_equal "updated\n", File.binread(path)
  end

  private

  def with_closed_temporary_rename(fail_rename: false)
    create, rename = Tempfile.method(:create), File.method(:rename)
    temporary = {}
    renames = 0
    create_file = lambda do |*args, **options, &block|
      create.call(*args, **options) do |file|
        temporary[file.path] = file
        block.call(file)
      end
    end
    replace_file = lambda do |source, destination|
      assert temporary.fetch(source).closed?
      assert_equal File.dirname(destination), File.dirname(source)
      renames += 1
      raise Errno::EACCES, destination if fail_rename
      rename.call(source, destination)
    end
    Tempfile.stub(:create, create_file) do
      File.stub(:rename, replace_file) { yield }
    end
    assert_equal 1, renames
  end

  def git(*arguments)
    _output, error, status = Open3.capture3("git", "-C", @directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
  end
end
