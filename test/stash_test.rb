# frozen_string_literal: true

require_relative "test_helper"

class StashTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-stash-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "core.autocrlf", "false")
    write("staged.txt", "old staged\n")
    write("worktree.txt", "old worktree\n")
    git("add", ".")
    git("commit", "-qm", "Initial files")
    @head = git("rev-parse", "HEAD").strip
    @repository = Thuban::Repository.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_stashes_and_restores_staged_and_worktree_changes
    write("staged.txt", "new staged\n")
    git("add", "staged.txt")
    write("worktree.txt", "new worktree\n")
    write("kept.txt", "untracked\n")

    oid = @repository.stash_push(message: "save changes")
    assert_equal oid, @repository.stash_list.first.oid
    assert_equal ["stash@{0}: On main: save changes"], git("stash", "list").lines.map(&:chomp)
    assert_equal "old staged\n", File.binread(path("staged.txt"))
    assert_equal "old worktree\n", File.binread(path("worktree.txt"))
    assert_equal "untracked\n", File.binread(path("kept.txt"))
    assert_equal "?? kept.txt\n", git("status", "--porcelain=v1")
    assert_git_fsck

    assert_equal oid, @repository.stash_pop
    assert_empty @repository.stash_list
    assert_empty git("stash", "list")
    assert_equal "new staged\n", File.binread(path("staged.txt"))
    assert_equal "new worktree\n", File.binread(path("worktree.txt"))
    assert_equal [" M worktree.txt", "?? kept.txt", "M  staged.txt"], git("status", "--porcelain=v1").lines.map(&:chomp).sort
    assert_git_fsck
  end

  def test_include_untracked_round_trips_files_and_symlinks
    write("new.txt", "untracked\n")
    File.symlink("new.txt", path("link"))

    oid = @repository.stash_push(include_untracked: true)
    refute File.exist?(path("new.txt"))
    refute File.symlink?(path("link"))
    assert_empty git("status", "--porcelain=v1")
    assert_equal 3, @repository.commit(oid).parents.length
    assert_git_fsck

    @repository.stash_pop
    assert_equal "untracked\n", File.binread(path("new.txt"))
    assert_equal "new.txt", File.readlink(path("link"))
    assert_equal ["?? link", "?? new.txt"], git("status", "--porcelain=v1").lines.map(&:chomp).sort
  end

  def test_lists_and_pops_an_older_stash
    write("worktree.txt", "first stash\n")
    first = @repository.stash_push(message: "first")
    write("worktree.txt", "second stash\n")
    second = @repository.stash_push(message: "second")

    assert_equal [second, first], @repository.stash_list.map(&:oid)
    assert_equal first, @repository.stash_pop(1)
    assert_equal "first stash\n", File.binread(path("worktree.txt"))
    assert_equal [second], @repository.stash_list.map(&:oid)
    assert_equal ["stash@{0}: On main: second"], git("stash", "list").lines.map(&:chomp)
  end

  def test_returns_nil_without_selected_changes_and_rejects_pop_collisions
    assert_nil @repository.stash_push
    write("untracked.txt", "not selected\n")
    assert_nil @repository.stash_push
    oid = @repository.stash_push(include_untracked: true)
    write("untracked.txt", "replacement\n")

    error = assert_raises(ArgumentError) { @repository.stash_pop }
    assert_match(/collision/, error.message)
    assert_equal oid, @repository.stash_list.first.oid
    assert_equal "replacement\n", File.binread(path("untracked.txt"))
  end

  private

  def path(relative) = File.join(@directory, relative)

  def write(relative, contents)
    absolute = path(relative)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end

  def assert_git_fsck
    output, status = Open3.capture2e("git", "-C", @directory, "fsck", "--strict")
    assert status.success?, output
  end
end
