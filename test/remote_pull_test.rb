# frozen_string_literal: true

require_relative "test_helper"

class RemotePullTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-pull-")
    @source = File.join(@directory, "source")
    @remote = File.join(@directory, "remote.git")
    @local = File.join(@directory, "local")
    git(@source, "init", "-q", "-b", "main")
    git(@source, "config", "user.name", "Fixture")
    git(@source, "config", "user.email", "fixture@example.invalid")
    File.binwrite(File.join(@source, "tracked.txt"), "first\n")
    git(@source, "add", ".")
    git(@source, "commit", "-qm", "First")
    git(@remote, "init", "-q", "--bare")
    git(@source, "push", "-q", @remote, "main")
    git(@directory, "clone", "-q", "-b", "main", @remote, @local)
    git(@local, "config", "user.name", "Fixture")
    git(@local, "config", "user.email", "fixture@example.invalid")
    @repository = Thuban::Repository.new(@local)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_fast_forwards_the_current_branch_index_and_worktree
    target = remote_commit("tracked.txt", "second\n", "Second")
    File.binwrite(File.join(@local, "untracked.txt"), "keep\n")

    assert_equal target, @repository.pull
    assert_equal target, @repository.head
    assert_equal target, @repository.resolve("refs/remotes/origin/main")
    assert_equal "second\n", @repository.worktree_content("tracked.txt")
    assert_equal "keep\n", @repository.worktree_content("untracked.txt")
    assert_equal [["untracked.txt", "??"]], @repository.status.map { |entry| [entry.path, entry.code] }
    assert_equal target, @repository.pull
  end

  def test_rejects_non_fast_forward_and_unsupported_or_dirty_states_before_mutation
    File.binwrite(File.join(@local, "tracked.txt"), "local\n")
    git(@local, "add", ".")
    git(@local, "commit", "-qm", "Local")
    local = @repository.head
    target = remote_commit("tracked.txt", "remote\n", "Remote")

    error = assert_raises(Thuban::TransportError) { @repository.pull }
    assert_match(/fast-forward/, error.message)
    assert_equal local, @repository.head
    assert_equal target, @repository.resolve("refs/remotes/origin/main")
    assert_equal "local\n", @repository.worktree_content("tracked.txt")
    assert_raises(ArgumentError) { @repository.pull(ff_only: false) }

    File.binwrite(File.join(@local, "tracked.txt"), "dirty\n")
    opened = false
    replacement = ->(*) { opened = true; raise "connected" }
    assert_raises(ArgumentError) { Thuban::Remote.stub(:open, replacement) { @repository.pull } }
    refute opened
  end

  def test_preserves_untracked_collisions_and_rolls_back_when_the_index_is_locked
    target = remote_commit("new.txt", "remote\n", "Add remote file")
    File.binwrite(File.join(@local, "new.txt"), "local\n")
    old = @repository.head

    assert_raises(ArgumentError) { @repository.pull }
    assert_equal old, @repository.head
    assert_equal "local\n", File.binread(File.join(@local, "new.txt"))
    assert_equal target, @repository.resolve("refs/remotes/origin/main")

    File.unlink(File.join(@local, "new.txt"))
    lock = File.join(@repository.git_dir, "index.lock")
    File.binwrite(lock, "held")
    assert_raises(IOError) { @repository.pull }
    assert_equal old, @repository.head
    assert_equal "held", File.binread(lock)
    refute File.exist?(File.join(@local, "new.txt"))
  end

  def test_rejects_bare_detached_and_concurrent_head_changes
    bare = Thuban::Repository.new(@remote)
    assert_raises(ArgumentError) { bare.pull }

    git(@local, "checkout", "--detach", "-q")
    assert_raises(ArgumentError) { @repository.pull }
    git(@local, "checkout", "main", "-q")

    target = remote_commit("tracked.txt", "second\n", "Second")
    @repository.fetch
    advertised = [Thuban::Ref.new(name: "refs/heads/main", oid: target)]
    local = @local
    @repository.define_singleton_method(:fetch) do |*, **|
      system("git", "-C", local, "checkout", "-q", "-b", "concurrent") || raise("checkout failed")
      advertised
    end

    assert_raises(Thuban::RefLockError) { @repository.pull }
    assert_equal "concurrent", @repository.branch
    refute_equal target, @repository.head
    assert_equal "first\n", @repository.worktree_content("tracked.txt")
  end

  def test_cancellation_after_fetch_does_not_update_head_index_or_worktree
    target = remote_commit("tracked.txt", "second\n", "Second")
    advertised = [Thuban::Ref.new(name: "refs/heads/main", oid: target)]
    before = [@repository.head, File.binread(File.join(@repository.git_dir, "index")), @repository.worktree_content("tracked.txt")]
    calls = 0
    cancelled = -> { calls += 1; calls == 2 }
    @repository.define_singleton_method(:fetch) { |*, **| advertised }

    assert_raises(Thuban::Cancelled) { @repository.pull(cancelled: cancelled) }

    assert_equal before[0], @repository.head
    assert_equal before[1], File.binread(File.join(@repository.git_dir, "index"))
    assert_equal before[2], @repository.worktree_content("tracked.txt")
  end

  def test_cancellation_immediately_before_update_does_not_mutate_repository
    target = remote_commit("tracked.txt", "second\n", "Second")
    advertised = [Thuban::Ref.new(name: "refs/heads/main", oid: target)]
    before = [@repository.head, File.binread(File.join(@repository.git_dir, "index")), @repository.worktree_content("tracked.txt")]
    calls = 0
    cancelled = -> { calls += 1; calls == 3 }
    @repository.define_singleton_method(:fetch) { |*, **| advertised }
    @repository.define_singleton_method(:merge_base) { |*, **| before[0] }

    assert_raises(Thuban::Cancelled) { @repository.pull(cancelled: cancelled) }

    assert_equal before[0], @repository.head
    assert_equal before[1], File.binread(File.join(@repository.git_dir, "index"))
    assert_equal before[2], @repository.worktree_content("tracked.txt")
  end

  private

  def remote_commit(path, contents, message)
    absolute = File.join(@source, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
    git(@source, "add", ".")
    git(@source, "commit", "-qm", message)
    git(@source, "push", "-q", @remote, "main")
    git(@source, "rev-parse", "HEAD").strip
  end

  def git(directory, *arguments)
    FileUtils.mkdir_p(directory) unless File.exist?(directory)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end
end
