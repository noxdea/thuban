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

  def test_locks_prevent_push_or_pop_from_changing_the_worktree
    write("worktree.txt", "push change\n")
    ref_lock = path(".git/refs/stash.lock")
    File.binwrite(ref_lock, "held")
    assert_raises(Thuban::RefLockError) { @repository.stash_push }
    assert_equal "push change\n", File.binread(path("worktree.txt"))
    File.unlink(ref_lock)

    oid = @repository.stash_push
    log_lock = path(".git/logs/refs/stash.lock")
    File.binwrite(log_lock, "held")
    assert_raises(Thuban::RefLockError) { @repository.stash_pop }
    assert_equal "old worktree\n", File.binread(path("worktree.txt"))
    assert_equal oid, @repository.stash_list.first.oid
    assert_equal "held", File.binread(log_lock)
  end

  def test_pop_applies_changes_on_top_of_a_new_head
    write("worktree.txt", "stashed\n")
    oid = @repository.stash_push
    write("later.txt", "later commit\n")
    git("add", "later.txt")
    git("commit", "-qm", "Later")

    assert_equal oid, @repository.stash_pop
    assert_equal "later commit\n", File.binread(path("later.txt"))
    assert_equal "stashed\n", File.binread(path("worktree.txt"))
    assert_equal " M worktree.txt\n", git("status", "--porcelain=v1")
  end

  def test_pop_reports_changes_to_the_same_path_as_a_conflict
    write("worktree.txt", "stashed\n")
    oid = @repository.stash_push
    write("worktree.txt", "later commit\n")
    git("commit", "-qam", "Later")
    current = @repository.head

    error = assert_raises(ArgumentError) { @repository.stash_pop }
    assert_match(/conflicts: worktree.txt/, error.message)
    assert_equal current, @repository.head
    assert_equal "later commit\n", File.binread(path("worktree.txt"))
    assert_equal oid, @repository.stash_list.first.oid
  end

  def test_pop_merges_non_overlapping_text_changes_on_top_of_a_new_head
    write("merge.txt", "first\nmiddle\nlast\n")
    git("add", "merge.txt")
    git("commit", "-qm", "Merge base")
    write("merge.txt", "stash\nmiddle\nlast\n")
    oid = @repository.stash_push
    write("merge.txt", "first\nmiddle\nhead\n")
    git("commit", "-qam", "New head")

    assert_equal oid, @repository.stash_pop
    assert_equal "stash\nmiddle\nhead\n", File.binread(path("merge.txt"))
    assert_equal " M merge.txt\n", git("status", "--porcelain=v1")
    assert_git_fsck
  end

  def test_include_untracked_leaves_globally_ignored_files_alone
    ignore = path(".git/global-ignore")
    File.binwrite(ignore, "ignored.txt\n")
    git("config", "core.excludesFile", ignore)
    write("ignored.txt", "ignored\n")
    write("visible.txt", "visible\n")

    oid = @repository.stash_push(include_untracked: true)
    assert File.exist?(path("ignored.txt"))
    refute File.exist?(path("visible.txt"))
    assert_equal oid, @repository.stash_pop
    assert_equal "ignored\n", File.binread(path("ignored.txt"))
    assert_equal "visible\n", File.binread(path("visible.txt"))
  end

  def test_push_restores_changes_when_the_stash_ref_cannot_be_replaced
    write("worktree.txt", "dirty\n")
    index_path = path(".git/index")
    before_index = File.binread(index_path)
    ref_path = path(".git/refs/stash")
    rename = File.method(:rename)
    failing = lambda do |source, target|
      raise Errno::EACCES, target if source == ref_path + ".lock" && target == ref_path

      rename.call(source, target)
    end

    File.stub(:rename, failing) do
      assert_raises(Errno::EACCES) { @repository.stash_push }
    end
    assert_equal "dirty\n", File.binread(path("worktree.txt"))
    assert_equal before_index, File.binread(index_path)
    assert_empty @repository.stash_list
    assert_empty git("stash", "list")
    refute File.exist?(ref_path + ".lock")
  end

  def test_pop_restores_state_when_the_stash_ref_cannot_be_deleted
    write("worktree.txt", "stashed\n")
    oid = @repository.stash_push
    index_path = path(".git/index")
    before_index = File.binread(index_path)
    ref_path = path(".git/refs/stash")
    unlink = File.method(:unlink)
    failing = lambda do |target|
      raise Errno::EACCES, target if target == ref_path

      unlink.call(target)
    end

    File.stub(:unlink, failing) do
      assert_raises(Errno::EACCES) { @repository.stash_pop }
    end
    assert_equal "old worktree\n", File.binread(path("worktree.txt"))
    assert_equal before_index, File.binread(index_path)
    assert_equal oid, @repository.stash_list.first.oid
    assert_equal ["stash@{0}: WIP on main: #{@head[0, 7]} Initial files"], git("stash", "list").lines.map(&:chomp)
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
