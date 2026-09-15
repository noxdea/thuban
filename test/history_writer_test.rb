# frozen_string_literal: true

require_relative "test_helper"

class HistoryWriterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-history-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "core.autocrlf", "false")
    write("shared.txt", "base\n")
    write("main.txt", "one\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    @base = git("rev-parse", "HEAD").strip
    git("checkout", "-qb", "topic")
    write("topic.txt", "topic\n")
    git("add", ".")
    git("commit", "-qm", "Topic change", env: {"GIT_AUTHOR_NAME" => "Topic Author", "GIT_AUTHOR_EMAIL" => "topic@example.invalid"})
    @topic = git("rev-parse", "HEAD").strip
    git("checkout", "-q", "main")
    write("main.txt", "two\n")
    git("commit", "-qam", "Main change")
    @main = git("rev-parse", "HEAD").strip
    @repository = Thuban::Repository.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_merge_base_matches_git_for_branches_and_ancestor_commits
    assert_equal git("merge-base", "main", "topic").strip, @repository.merge_base("main", "topic")
    assert_equal git("merge-base", @base, "main").strip, @repository.merge_base(@base, "main")
    assert_nil @repository.merge_base(unrelated_commit, "main")

    descendant = commit_object(@base, "Descendant")
    redundant_merge = commit_object(@base, "Redundant merge", parents: [@base, descendant])
    assert_equal git("merge-base", descendant, redundant_merge).strip, @repository.merge_base(descendant, redundant_merge)
  end

  def test_soft_mixed_and_hard_reset_match_git_state
    write("main.txt", "staged\n")
    git("add", "main.txt")
    assert_equal @base, @repository.reset(@base, mode: :soft)
    assert_equal @base, @repository.head
    assert_equal "staged\n", File.binread(File.join(@directory, "main.txt"))
    assert_equal "M  main.txt\n", git("status", "--porcelain=v1")

    assert_equal @main, @repository.reset(@main)
    assert_equal "staged\n", File.binread(File.join(@directory, "main.txt"))
    assert_equal " M main.txt\n", git("status", "--porcelain=v1")

    assert_equal @base, @repository.reset(@base, mode: :hard)
    assert_equal "one\n", File.binread(File.join(@directory, "main.txt"))
    assert_empty git("status", "--porcelain=v1")
    assert_git_fsck
  end

  def test_cherry_pick_applies_a_single_parent_commit_and_preserves_its_author
    picked = @repository.cherry_pick(@topic)

    assert_equal picked, git("rev-parse", "HEAD").strip
    assert_equal "topic\n", File.binread(File.join(@directory, "topic.txt"))
    assert_equal "Topic Author <topic@example.invalid>", git("show", "-s", "--format=%an <%ae>", picked).strip
    assert_equal "Topic change", git("show", "-s", "--format=%s", picked).strip
    assert_empty git("status", "--porcelain=v1")
    assert_git_fsck
  end

  def test_revert_reverses_a_commit_and_records_a_git_readable_commit
    picked = @repository.cherry_pick(@topic)
    reverted = @repository.revert(picked)

    refute File.exist?(File.join(@directory, "topic.txt"))
    assert_equal "Revert \"Topic change\"", git("show", "-s", "--format=%s", reverted).strip
    assert_match(/This reverts commit #{picked}/, git("show", "-s", "--format=%B", reverted))
    assert_empty git("status", "--porcelain=v1")
    assert_git_fsck
  end

  def test_cherry_pick_conflict_and_dirty_state_leave_the_repository_unchanged
    git("checkout", "-qb", "conflict", @base)
    write("shared.txt", "incoming\n")
    git("commit", "-qam", "Incoming")
    incoming = git("rev-parse", "HEAD").strip
    git("checkout", "-q", "main")
    write("shared.txt", "current\n")
    git("commit", "-qam", "Current")
    current = git("rev-parse", "HEAD").strip

    error = assert_raises(ArgumentError) { @repository.cherry_pick(incoming) }
    assert_match(/conflicts: shared.txt/, error.message)
    assert_equal current, @repository.head
    assert_equal "current\n", File.binread(File.join(@directory, "shared.txt"))

    write("main.txt", "dirty\n")
    assert_raises(ArgumentError) { @repository.cherry_pick(@topic) }
    assert_equal current, @repository.head
  end

  def test_reset_does_not_change_state_when_the_reference_is_locked
    write("main.txt", "dirty\n")
    git("add", "main.txt")
    before_index = File.binread(File.join(@directory, ".git", "index"))
    lock = File.join(@directory, ".git", "refs", "heads", "main.lock")
    File.binwrite(lock, "held")

    assert_raises(Thuban::RefLockError) { @repository.reset(@base, mode: :hard) }
    assert_equal @main, @repository.head
    assert_equal "dirty\n", File.binread(File.join(@directory, "main.txt"))
    assert_equal before_index, File.binread(File.join(@directory, ".git", "index"))
    assert_equal "held", File.binread(lock)
  end

  def test_hard_reset_does_not_change_state_when_the_index_is_locked
    write("main.txt", "dirty\n")
    before = @repository.head
    lock = File.join(@directory, ".git", "index.lock")
    File.binwrite(lock, "held")

    assert_raises(IOError) { @repository.reset(@base, mode: :hard) }
    assert_equal before, @repository.head
    assert_equal "dirty\n", File.binread(File.join(@directory, "main.txt"))
    assert_equal "held", File.binread(lock)
  end

  def test_hard_reset_restores_the_worktree_when_index_replacement_fails
    write("main.txt", "dirty\n")
    index_path = File.join(@directory, ".git", "index")
    before_index = File.binread(index_path)
    rename = File.method(:rename)
    failing = lambda do |source, target|
      raise Errno::EACCES, target if source == index_path + ".lock" && target == index_path

      rename.call(source, target)
    end

    File.stub(:rename, failing) do
      assert_raises(Errno::EACCES) { @repository.reset(@base, mode: :hard) }
    end
    assert_equal @main, @repository.head
    assert_equal "dirty\n", File.binread(File.join(@directory, "main.txt"))
    assert_equal before_index, File.binread(index_path)
    refute File.exist?(index_path + ".lock")
  end

  private

  def unrelated_commit
    tree = @repository.write_tree([])
    signature = Thuban::Signature.new(name: "Other", email: "other@example.invalid", time: 1, offset: "+0000")
    @repository.write_commit(tree: tree, author: signature, message: "Unrelated")
  end

  def commit_object(parent, message, parents: [parent])
    signature = Thuban::Signature.new(name: "Fixture", email: "fixture@example.invalid", time: 1, offset: "+0000")
    @repository.write_commit(tree: @repository.commit(parent).tree, parents: parents, author: signature, message: message)
  end

  def write(path, content)
    absolute = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, content)
  end

  def git(*arguments, env: {})
    output, error, status = Open3.capture3(env, "git", "-C", @directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end

  def assert_git_fsck
    output, status = Open3.capture2e("git", "-C", @directory, "fsck", "--strict")
    assert status.success?, output
  end
end
