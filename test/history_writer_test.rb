# frozen_string_literal: true

require_relative "test_helper"

class HistoryWriterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-history-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "core.autocrlf", "false")
    write("shared.txt", "first\nmiddle\nlast\n")
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

  def test_each_commit_walks_a_merge_once_in_parent_order_and_requires_a_limit
    merge = commit_object(@main, "Merge", parents: [@main, @topic])

    history = @repository.each_commit(merge, limit: 10)
    assert_kind_of Enumerator, history
    assert_equal [merge, @main, @topic, @base], history.map(&:oid)
    assert_equal [merge, @main], @repository.each_commit(merge, limit: 2).map(&:oid)
    assert_empty @repository.each_commit("missing", limit: 10).to_a
    [0, -1, nil, 1.5].each do |limit|
      assert_raises(ArgumentError) { @repository.each_commit(limit: limit) }
    end

    write(".git/refs/heads/main", "invalid\n")
    assert_raises(Thuban::CorruptObject) { @repository.each_commit(limit: 1).to_a }
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

  def test_cherry_pick_keeps_the_internal_identity_fallback
    git("config", "--unset-all", "user.name")
    git("config", "--unset-all", "user.email")
    environment = {
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => File.join(@directory, "missing-global-config"),
      "GIT_COMMITTER_NAME" => nil,
      "GIT_COMMITTER_EMAIL" => nil
    }
    with_environment(environment) do
      picked = @repository.cherry_pick(@topic)
      assert_equal "unknown@localhost", @repository.commit(picked).signature(role: :committer).email
    end
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

  def test_cherry_pick_and_revert_merge_non_overlapping_text_changes
    git("checkout", "-q", "topic")
    write("shared.txt", "topic\nmiddle\nlast\n")
    git("commit", "-qam", "Topic text")
    incoming = git("rev-parse", "HEAD").strip
    git("checkout", "-q", "main")
    write("shared.txt", "first\nmiddle\nmain\n")
    git("commit", "-qam", "Main text")

    picked = @repository.cherry_pick(incoming)
    assert_equal "topic\nmiddle\nmain\n", File.binread(File.join(@directory, "shared.txt"))

    write("shared.txt", "topic\ncurrent\nmain\n")
    git("commit", "-qam", "Later text")
    @repository.revert(picked)
    assert_equal "first\ncurrent\nmain\n", File.binread(File.join(@directory, "shared.txt"))
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

  def test_repository_state_replacement_rejects_a_concurrent_index_update
    index_path = File.join(@directory, ".git", "index")
    lock_path = index_path + ".lock"
    File.binwrite(File.join(@directory, "external.txt"), "external\n")
    open = File.method(:open)
    raced = false
    replacement = lambda do |path, *arguments, **options, &block|
      unless raced || path != lock_path
        raced = true
        git("add", "external.txt")
      end
      open.call(path, *arguments, **options, &block)
    end

    error = File.stub(:open, replacement) do
      assert_raises(Thuban::RefLockError) { @repository.reset(@base, mode: :hard) }
    end

    assert_match(/index changed/, error.message)
    assert_equal "external.txt", git("ls-files", "external.txt").strip
    assert_equal "external\n", File.binread(File.join(@directory, "external.txt"))
    refute File.exist?(lock_path)
  end

  def test_reset_restores_the_worktree_and_index_when_ref_replacement_fails
    write("main.txt", "dirty\n")
    git("add", "main.txt")
    index_path = File.join(@directory, ".git", "index")
    before_index = File.binread(index_path)
    before_reflog = git("reflog", "show", "--format=%H %gs")
    ref_path = File.join(@directory, ".git", "refs", "heads", "main")
    rename = File.method(:rename)
    failing = lambda do |source, target|
      raise Errno::EACCES, target if source == ref_path + ".lock" && target == ref_path

      rename.call(source, target)
    end

    %i[mixed hard].each do |mode|
      File.stub(:rename, failing) do
        assert_raises(Errno::EACCES) { @repository.reset(@base, mode: mode) }
      end
      assert_equal @main, @repository.head
      assert_equal "dirty\n", File.binread(File.join(@directory, "main.txt"))
      assert_equal before_index, File.binread(index_path)
      assert_equal before_reflog, git("reflog", "show", "--format=%H %gs")
      refute File.exist?(ref_path + ".lock")
    end
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

  def with_environment(values)
    previous = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
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
