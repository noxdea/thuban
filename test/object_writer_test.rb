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
    tree = @repository.write_tree([])
    refute @repository.odb.exist?("0" * 40)
    assert_raises(ArgumentError) { @repository.odb.exist?("../config") }
    assert_raises(ArgumentError) { @repository.odb.write("evil", "content") }
    assert_raises(ArgumentError) { @repository.write_tree([Thuban::TreeEntry.new(path: "../bad", oid: blob, mode: 0o100644)]) }
    assert_raises(ArgumentError) { @repository.write_tree([Thuban::TreeEntry.new(path: ".GIT", oid: blob, mode: 0o100644)]) }
    assert_raises(ArgumentError) { @repository.write_tree([Thuban::TreeEntry.new(path: "bad", oid: blob, mode: 0o040000)]) }
    assert_raises(ArgumentError) { @repository.write_commit(tree: blob, author: @signature, message: "bad") }
    assert_raises(TypeError) { @repository.write_commit(tree: tree, author: Object.new, message: "bad") }
    invalid = @signature.dup.tap { |signature| signature.name = "bad\0name" }
    assert_raises(ArgumentError) { @repository.write_commit(tree: tree, author: invalid, message: "bad") }
  end

  def test_matches_git_tree_order_and_accepts_a_missing_gitlink
    blob = @repository.write_blob("content")
    subtree = @repository.write_tree([])
    gitlink = "1" * 40
    entries = [
      Thuban::TreeEntry.new(path: "foo0", oid: gitlink, mode: 0o160000),
      Thuban::TreeEntry.new(path: "foo", oid: subtree, mode: 0o040000),
      Thuban::TreeEntry.new(path: "foo.bar", oid: blob, mode: 0o100644)
    ]
    input = "100644 blob #{blob}\tfoo.bar\n040000 tree #{subtree}\tfoo\n160000 commit #{gitlink}\tfoo0\n"
    expected, error, status = Open3.capture3("git", "-C", @directory, "mktree", stdin_data: input, binmode: true)
    assert status.success?, error

    assert_equal expected.strip, @repository.write_tree(entries)
  end

  def test_matches_git_commit_tree_bytes_and_validates_signatures
    tree = @repository.write_tree([])
    committer = Thuban::Signature.new(name: "Committer", email: "committer@example.invalid", time: 1_700_000_001, offset: "-0430")
    environment = {
      "GIT_AUTHOR_NAME" => @signature.name, "GIT_AUTHOR_EMAIL" => @signature.email,
      "GIT_AUTHOR_DATE" => "#{@signature.time} #{@signature.offset}",
      "GIT_COMMITTER_NAME" => committer.name, "GIT_COMMITTER_EMAIL" => committer.email,
      "GIT_COMMITTER_DATE" => "#{committer.time} #{committer.offset}"
    }
    expected, error, status = Open3.capture3(environment, "git", "-C", @directory, "commit-tree", tree,
      stdin_data: "Exact commit\n", binmode: true)
    assert status.success?, error
    actual = @repository.write_commit(tree: tree, author: @signature, committer: committer, message: "Exact commit")
    assert_equal expected.strip, actual
    data = git("cat-file", "commit", actual)
    assert_includes data, "author Fixture Author <fixture@example.invalid> 1700000000 +0900\n"
    assert_includes data, "committer Committer <committer@example.invalid> 1700000001 -0430\n"

    ["+2400", "+1260", "0900", Object.new].each do |offset|
      invalid = @signature.dup.tap { |signature| signature.offset = offset }
      assert_raises(ArgumentError) { @repository.write_commit(tree: tree, author: invalid, message: "bad") }
    end
    invalid = @signature.dup.tap { |signature| signature.time = Object.new }
    assert_raises(ArgumentError) { @repository.write_commit(tree: tree, author: invalid, message: "bad") }
  end

  def test_rejects_a_symlinked_loose_object_directory
    outside = Dir.mktmpdir("thuban-object-outside-")
    content = (0..).lazy.map(&:to_s).find { |candidate| Thuban::ObjectDatabase.hash("blob", candidate).start_with?("aa") }
    File.symlink(outside, File.join(@directory, ".git", "objects", "aa"))
    assert_raises(ArgumentError) { @repository.write_blob(content) }
    assert_empty Dir.children(outside)
  ensure
    FileUtils.remove_entry(outside) if outside && File.exist?(outside)
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
