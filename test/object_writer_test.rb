# frozen_string_literal: true

require_relative "test_helper"

class ObjectWriterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-write-")
    git("init", "-q", "-b", "main")
    @repository = Thuban::Repository.new(@directory)
    @signature = Thuban::Signature.new(name: "Fixture Author", email: "fixture@example.invalid", time: 1_700_000_000, offset: "+0900")
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_writes_loose_objects_readable_by_git
    blob = @repository.write_blob("hello\n")
    assert_equal blob, @repository.write_blob("hello\n")
    assert @repository.odb.exist?(blob)
    assert_equal "blob", git("cat-file", "-t", blob).strip
    assert_equal "hello\n", git("cat-file", "blob", blob)

    subtree = @repository.write_tree([Thuban::TreeEntry.new(path: "child.txt", oid: blob, mode: 0o100644)])
    tree = @repository.write_tree([Thuban::TreeEntry.new(path: "dir", oid: subtree, mode: 0o040000)])
    commit = @repository.write_commit(tree: tree, author: @signature, message: "Write objects")

    assert_equal "tree", git("cat-file", "-t", tree).strip
    assert_equal "dir/child.txt\n", git("ls-tree", "-r", "--name-only", tree)
    assert git("cat-file", "commit", commit).end_with?("\n\nWrite objects\n")
    assert_git_fsck
  end

  def test_rejects_invalid_objects_and_tree_entries
    blob = @repository.write_blob("content")
    refute @repository.odb.exist?("0" * 40)
    assert_raises(ArgumentError) { @repository.odb.exist?("../config") }
    assert_raises(ArgumentError) { @repository.odb.write("evil", "content") }
    assert_raises(ArgumentError) { @repository.write_tree([Thuban::TreeEntry.new(path: "../bad", oid: blob, mode: 0o100644)]) }
    assert_raises(ArgumentError) { @repository.write_tree([Thuban::TreeEntry.new(path: "bad", oid: blob, mode: 0o040000)]) }
    assert_raises(ArgumentError) { @repository.write_commit(tree: blob, author: @signature, message: "bad") }
  end

  private

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(" ")}: #{error}"
    output
  end

  def assert_git_fsck
    output, status = Open3.capture2e("git", "-C", @directory, "fsck", "--strict")
    assert status.success?, output
  end
end
