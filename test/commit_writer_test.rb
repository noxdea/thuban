# frozen_string_literal: true

require_relative "test_helper"

class CommitWriterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-commit-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    File.binwrite(File.join(@directory, "file.txt"), "initial\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    @repository = Thuban::Repository.new(@directory)
    @initial = @repository.head
    @signature = Thuban::Signature.new(name: "Writer", email: "writer@example.invalid", time: 1_700_000_000, offset: "+0900")
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_commit_operation_remains_public
    assert_respond_to @repository, :commit!
  end

  def test_builds_nested_trees_and_commits_the_index
    write("dir/nested.txt", "nested\n")
    write("script.sh", "#!/bin/sh\n")
    File.chmod(0o755, File.join(@directory, "script.sh"))
    index = @repository.index
    index.stage("dir/nested.txt", @repository.write_blob("nested\n"), 0o100644, stat: File.stat(File.join(@directory, "dir/nested.txt")))
    index.stage("script.sh", @repository.write_blob("#!/bin/sh\n"), 0o100755, stat: File.stat(File.join(@directory, "script.sh")))
    index.write

    oid = @repository.commit!(message: "Add nested files", author: @signature)
    assert_equal oid, git("rev-parse", "HEAD").strip
    assert_equal [@initial], @repository.commit(oid).parents
    assert_equal %w[dir/nested.txt file.txt script.sh], git("ls-tree", "-r", "--name-only", oid).lines.map(&:chomp)
    assert_equal "100755", git("ls-tree", oid, "script.sh").split.first
    assert_equal "Writer <writer@example.invalid>", git("show", "-s", "--format=%an <%ae>", oid).strip
    assert_empty git("status", "--porcelain=v1")
    assert_git_fsck
  end

  def test_amend_replaces_the_tip_and_keeps_its_parents
    first = @repository.commit!(message: "Empty intermediate", author: @signature)
    write("file.txt", "amended\n")
    index = @repository.index
    index.stage("file.txt", @repository.write_blob("amended\n"), 0o100644, stat: File.stat(File.join(@directory, "file.txt")))
    index.write

    amended = @repository.commit!(message: "Amended subject", author: @signature, amend: true)
    refute_equal first, amended
    assert_equal [@initial], @repository.commit(amended).parents
    assert_equal "amended\n", git("show", "#{amended}:file.txt")
    assert_equal "commit (amend): Amended subject", git("reflog", "show", "-1", "--format=%gs").strip
    assert_git_fsck
  end

  def test_amend_can_preserve_the_author_and_update_the_committer
    original = @repository.commit
    author = original.signature(role: :author)
    committer = Thuban::Signature.new(name: "Current User", email: "current@example.invalid", time: 1_800_000_000, offset: "-0430")

    amended = @repository.commit!(message: "Amended identity", author: author, committer: committer, amend: true)
    commit = @repository.commit(amended)

    assert_equal original.author, commit.author
    assert_equal "Current User <current@example.invalid> 1800000000 -0430", commit.committer
    assert_equal author, commit.signature
    assert_equal committer, commit.signature(role: :committer)
    assert_git_fsck
  end

  def test_rejects_an_invalid_signature_role
    error = assert_raises(ArgumentError) { @repository.commit.signature(role: :reviewer) }
    assert_equal "role must be :author or :committer", error.message
  end

  def test_commits_on_a_detached_head_without_advancing_a_branch
    git("checkout", "--detach", "-q")
    oid = @repository.commit!(message: "Detached", author: @signature)

    assert_equal oid, git("rev-parse", "HEAD").strip
    assert_equal @initial, git("rev-parse", "main").strip
    assert_equal [@initial], @repository.commit(oid).parents
    assert_git_fsck
  end

  def test_commits_an_unborn_empty_repository
    empty = Dir.mktmpdir("thuban-unborn-")
    git_in(empty, "init", "-q", "-b", "main")
    git_in(empty, "config", "user.name", "Fixture Author")
    git_in(empty, "config", "user.email", "fixture@example.invalid")
    repository = Thuban::Repository.new(empty)
    oid = repository.commit!(message: "Initial empty", author: @signature)
    assert_equal oid, git_in(empty, "rev-parse", "HEAD").strip
    assert_empty repository.commit.parents
    assert_equal({}, repository.tree)
  ensure
    FileUtils.remove_entry(empty) if empty && File.exist?(empty)
  end

  def test_refuses_to_commit_conflicts_or_amend_an_unborn_branch
    index = @repository.index
    base = index["file.txt"]
    index.remove("file.txt")
    (1..3).each { |stage| index.entries << base.dup.tap { |entry| entry.stage = stage } }
    index.write
    assert_raises(ArgumentError) { @repository.commit!(message: "Conflict", author: @signature) }

    empty = Dir.mktmpdir("thuban-unborn-")
    git_in(empty, "init", "-q", "-b", "main")
    assert_raises(ArgumentError) { Thuban::Repository.new(empty).commit!(message: "No", author: @signature, amend: true) }
  ensure
    FileUtils.remove_entry(empty) if empty && File.exist?(empty)
  end

  def test_refuses_excessive_index_path_nesting
    index = @repository.index
    original = index["file.txt"]
    index.entries.replace([original.dup.tap { |entry| entry.path = (["a"] * 257).join("/") }])
    index.write
    assert_raises(ArgumentError) { @repository.write_tree_from_index }
  end

  private

  def write(path, content)
    absolute = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, content)
  end

  def git(*arguments) = git_in(@directory, *arguments)

  def git_in(directory, *arguments)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(" ")}: #{error}"
    output
  end

  def assert_git_fsck
    output, status = Open3.capture2e("git", "-C", @directory, "fsck", "--strict")
    assert status.success?, output
  end
end
