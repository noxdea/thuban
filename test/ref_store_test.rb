# frozen_string_literal: true

require_relative "test_helper"

class RefStoreTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-refs-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    File.binwrite(File.join(@directory, "file.txt"), "one\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    @repository = Thuban::Repository.new(@directory)
    @first = @repository.head
    @second = commit_object(@first, "Second")
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_updates_symbolic_head_and_writes_git_reflogs
    assert_equal @second, @repository.update_ref("HEAD", @second, old_oid: @first, message: "commit: Second")
    assert_equal @second, git("rev-parse", "main").strip
    assert_equal @second, git("reflog", "show", "-1", "--format=%H", "HEAD").strip
    assert_equal @second, git("reflog", "show", "-1", "--format=%H", "refs/heads/main").strip
    assert_match(/\A#{@first} #{@second} .+\tcommit: Second\z/, @repository.reflog("main").last)
    assert_raises(Thuban::RefLockError) { @repository.update_ref("HEAD", @first, old_oid: @first) }
    assert_equal @second, @repository.head
  end

  def test_creates_updates_and_deletes_loose_and_packed_branches
    assert_equal "feature", @repository.create_branch("feature", @first)
    git("pack-refs", "--all", "--prune")
    refute File.exist?(File.join(@directory, ".git", "refs", "heads", "feature"))
    @repository.update_ref("refs/heads/feature", @second, old_oid: @first, message: "advance")
    assert_equal @second, git("rev-parse", "feature").strip
    assert_equal "feature", @repository.delete_branch("feature")
    _output, _error, status = Open3.capture3("git", "-C", @directory, "show-ref", "--verify", "refs/heads/feature", binmode: true)
    refute status.success?

    @repository.create_branch("packed", @first)
    git("pack-refs", "--all", "--prune")
    assert_equal @first, @repository.delete_ref("refs/heads/packed", old_oid: @first)
    refute_includes File.binread(File.join(@directory, ".git", "packed-refs")), "refs/heads/packed"
  end

  def test_symbolic_refs_support_an_unborn_branch
    assert_equal "refs/heads/fresh", @repository.symbolic_ref("HEAD", "refs/heads/fresh")
    assert_nil @repository.head
    assert_equal @first, @repository.update_ref("HEAD", @first, old_oid: nil, message: "commit (initial): Fresh")
    assert_equal "fresh", @repository.branch
    assert_equal @first, git("rev-parse", "fresh").strip
  end

  def test_rejects_invalid_names_and_preserves_foreign_locks
    assert_raises(ArgumentError) { @repository.update_ref("../config", @first) }
    assert_raises(ArgumentError) { @repository.create_branch("bad..name", @first) }
    assert_raises(ArgumentError) { @repository.create_branch("bad.LOCK", @first) }
    assert_raises(ArgumentError) { @repository.create_branch("bad\x7fname", @first) }
    lock = File.join(@directory, ".git", "refs", "heads", "main.lock")
    File.binwrite(lock, "held")
    assert_raises(Thuban::RefLockError) { @repository.update_ref("HEAD", @second) }
    assert_equal "held", File.binread(lock)
    refute File.exist?(File.join(@directory, ".git", "HEAD.lock"))
  end

  def test_rejects_reference_directories_symlinked_within_git_metadata
    tags = File.join(@directory, ".git", "refs", "tags")
    Dir.rmdir(tags)
    File.symlink(File.join(@directory, ".git", "refs", "heads"), tags)

    assert_raises(ArgumentError) { @repository.update_ref("refs/tags/main", @second) }
    assert_equal @first, @repository.head
  end

  def test_keeps_a_foreign_lock_created_after_replacement
    lock = File.join(@directory, ".git", "refs", "heads", "main.lock")
    rename = File.method(:rename)
    replacement = lambda do |source, target|
      rename.call(source, target)
      File.binwrite(source, "foreign") if source == lock
    end

    File.stub(:rename, replacement) { @repository.update_ref("refs/heads/main", @second) }
    assert_equal "foreign", File.binread(lock)
  end

  def test_rejects_symlinked_reference_directories
    outside = Dir.mktmpdir("thuban-ref-outside-")
    tags = File.join(@directory, ".git", "refs", "tags")
    Dir.rmdir(tags)
    File.symlink(outside, tags)
    assert_raises(ArgumentError) { @repository.update_ref("refs/tags/unsafe", @first) }
    assert_empty Dir.children(outside)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
  end

  private

  def commit_object(parent, message)
    signature = Thuban::Signature.new(name: "Fixture Author", email: "fixture@example.invalid", time: 1_700_000_000, offset: "+0000")
    @repository.write_commit(tree: @repository.commit(parent).tree, parents: [parent], author: signature, message: message)
  end

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(" ")}: #{error}"
    output
  end
end
