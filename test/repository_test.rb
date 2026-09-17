# frozen_string_literal: true

require_relative "test_helper"

class RepositoryTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-git-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "core.autocrlf", "false")
    git("config", "maintenance.auto", "false")
    write("text.txt", "first\nsecond\nthird\n")
    git("add", ".")
    git("commit", "-qm", "Initial text")
    @first = git("rev-parse", "HEAD").strip
    @repository = Thuban::Repository.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def git(*arguments, input: "")
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, stdin_data: input, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end

  def write(path, contents)
    absolute = File.join(@directory, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def test_loose_objects_refs_index_and_status
    assert_equal @first, @repository.head
    assert_equal "main", @repository.branch
    assert_equal ["main"], @repository.branches
    assert_equal "first\nsecond\nthird\n", @repository.blob("text.txt")
    assert_empty @repository.status
    write("text.txt", "first\nchanged\nthird\n")
    write("new.txt", "new")
    assert_equal({"new.txt" => "??", "text.txt" => " M"}, @repository.status.to_h { |entry| [entry.path, entry.code] })
    write(".gitignore", "ignored.txt\n")
    write("ignored.txt", "ignored")
    refute @repository.status.any? { |entry| entry.path == "ignored.txt" }
    File.symlink("missing.txt", File.join(@directory, "dangling"))
    assert_equal "??", @repository.status.find { |entry| entry.path == "dangling" }.code
    git("add", "text.txt")
    File.unlink(File.join(@directory, "text.txt"))
    assert_equal "MD", @repository.status.find { |entry| entry.path == "text.txt" }.code
    git("tag", "-a", "v1", "-m", "Version one", @first)
    git("pack-refs", "--all")
    assert_equal @first, @repository.commit("v1").oid
    assert_equal @first, @repository.resolve("main")
    assert_raises(ArgumentError) { @repository.resolve("../../config") }
  end

  def test_current_author_and_committer_signatures
    author = @repository.signature
    assert_equal ["Fixture Author", "fixture@example.invalid"], [author.name, author.email]
    assert_instance_of Time, author.time
    assert_equal author.time.utc_offset, author.offset

    environment = {
      "GIT_AUTHOR_NAME" => "Environment Author",
      "GIT_AUTHOR_EMAIL" => "author@example.invalid",
      "GIT_COMMITTER_NAME" => "Environment Committer",
      "GIT_COMMITTER_EMAIL" => "committer@example.invalid"
    }
    with_environment(environment) do
      author = @repository.signature(role: :author)
      committer = @repository.signature(role: :committer)
      assert_equal ["Environment Author", "author@example.invalid"],
        [author.name, author.email]
      assert_equal ["Environment Committer", "committer@example.invalid"],
        [committer.name, committer.email]
    end
  end

  def test_signature_rejects_missing_identity_and_invalid_role
    git("config", "--unset-all", "user.name")
    git("config", "--unset-all", "user.email")
    environment = {
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => File.join(@directory, "missing-global-config"),
      "GIT_AUTHOR_NAME" => nil,
      "GIT_AUTHOR_EMAIL" => nil
    }
    with_environment(environment) do
      error = assert_raises(ArgumentError) { @repository.signature }
      assert_equal "Git author identity is missing name and email", error.message
    end
    error = assert_raises(ArgumentError) { @repository.signature(role: :reviewer) }
    assert_equal "role must be :author or :committer", error.message
  end

  def test_filemode_uses_git_boolean_values_and_worktree_configuration
    git("config", "--unset-all", "core.filemode")
    environment = {
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => File.join(@directory, "missing-global-config")
    }
    with_environment(environment) do
      assert @repository.filemode?
      %w[false no off 0].each do |value|
        git("config", "core.filemode", value)
        refute @repository.filemode?, value
      end

      git("config", "core.filemode", "true")
      git("config", "extensions.worktreeConfig", "true")
      linked = File.join(@directory, "linked")
      git("worktree", "add", "-q", "-b", "linked", linked)
      other = Thuban::Repository.new(linked)
      File.binwrite(File.join(other.git_dir, "config.worktree"), "[core]\n filemode = false\n")
      assert @repository.filemode?
      refute other.filemode?
    end
  end

  def test_status_honors_core_filemode
    path = File.join(@directory, "text.txt")
    git("config", "core.filemode", "true")
    File.chmod(0o755, path)
    skip "filesystem does not expose executable bits" unless (File.stat(path).mode & 0o100).positive?

    assert_equal " M", @repository.status.find { |entry| entry.path == "text.txt" }.code
    git("config", "core.filemode", "false")
    assert_empty @repository.status
  end

  def test_status_detects_content_changes_when_filemode_is_disabled
    path = File.join(@directory, "text.txt")
    git("config", "core.filemode", "false")
    File.binwrite(path, "content changed\n")
    assert_equal " M", @repository.status.find { |entry| entry.path == "text.txt" }.code
  end

  def test_status_does_not_hide_type_changes_when_filemode_is_disabled
    path = File.join(@directory, "text.txt")
    git("config", "core.filemode", "false")
    File.unlink(path)
    File.symlink("missing.txt", path)
    assert_equal " T", @repository.status.find { |entry| entry.path == "text.txt" }.code
  end

  def test_blame_tracks_changes_and_renames
    write("text.txt", "first\nchanged\nthird\n")
    git("add", ".")
    git("commit", "-qm", "Change middle line")
    second = @repository.head
    blame = @repository.blame("text.txt")
    assert_equal [@first, second, @first], blame.map(&:commit)
    assert_equal [1, 2, 3], blame.map(&:original_line)
    git("mv", "text.txt", "renamed.txt")
    git("commit", "-qm", "Rename text")
    assert_equal [@first, second, @first], @repository.blame("renamed.txt").map(&:commit)
  end

  def test_packed_objects_and_both_delta_encodings
    12.times do |number|
      write("large.txt", (1..400).map { |line| "#{line}: persistent text #{line == number + 1 ? number : 0}\n" }.join)
      git("add", ".")
      git("commit", "-qm", "Revise text #{number}")
    end
    all = git("rev-list", "--objects", "--all").lines.map { |line| line.split.first }
    expected = all.to_h { |oid| [oid, [git("cat-file", "-t", oid).strip, git("cat-file", "-p", oid)]] }
    # cat-file -p prints a tree; use the raw type request for the byte oracle.
    expected.each { |oid, object| object[1] = git("cat-file", object[0], oid) }
    %w[--delta-base-offset --no-delta-base-offset].each do |encoding|
      packed = git("pack-objects", "--stdout", "--revs", "--all", "--window=50", "--depth=50", encoding)
      pack_path = File.join(@directory, "fixture.pack")
      File.binwrite(pack_path, packed)
      git("index-pack", pack_path)
      pack = Thuban::Pack.new(pack_path.sub(/\.pack$/, ".idx"))
      expected.each do |oid, object|
        assert_equal object.map(&:b), pack.read(oid) { |base| @repository.odb.read(base) }.map(&:b), "#{encoding}: #{oid}"
      end
      File.unlink(pack_path.sub(/\.pack$/, ".idx"))
    end
    git("gc", "--aggressive", "--prune=now")
    expected.each { |oid, object| assert_equal object.map(&:b), @repository.odb.read(oid).map(&:b) }
  end

  def test_index_version_four_and_git_worktree
    %w[a/b/one.txt a/b/two.txt a/c/three.txt].each { |path| write(path, path) }
    git("add", ".")
    git("update-index", "--index-version=4")
    assert_equal 4, @repository.index.version
    assert_equal %w[a/b/one.txt a/b/two.txt a/c/three.txt text.txt], @repository.index.entries.map(&:path)
    git("commit", "-qm", "Add nested paths")
    linked = File.join(@directory, "linked")
    git("worktree", "add", "-q", "-b", "linked", linked)
    other = Thuban::Repository.new(linked)
    assert_equal @repository.head, other.head
    assert_equal "linked", other.branch
    assert_empty other.status
  end

  def test_checkout_preserves_untracked_and_rejects_dirty_or_colliding_files
    git("checkout", "-qb", "other")
    write("text.txt", "other content\n")
    write("added.txt", "added")
    git("add", ".")
    git("commit", "-qm", "Other branch text")
    git("checkout", "-q", "main")
    write("untracked.txt", "keep")
    assert_equal "other", @repository.checkout("other")
    assert_equal "other content\n", File.read(File.join(@directory, "text.txt"))
    assert_equal "keep", File.read(File.join(@directory, "untracked.txt"))
    assert_equal "other", git("branch", "--show-current").strip
    assert_equal "?? untracked.txt\n", git("status", "--porcelain")
    @repository.checkout("main")
    write("added.txt", "collision")
    assert_raises(ArgumentError) { @repository.checkout("other") }
    assert_equal "main", @repository.branch
    assert_equal "collision", File.read(File.join(@directory, "added.txt"))
    write("text.txt", "dirty")
    assert_raises(ArgumentError) { @repository.checkout("other") }
  end

  def test_corruption_is_reported
    index_path = File.join(@directory, ".git", "index")
    bytes = File.binread(index_path)
    bytes.setbyte(20, bytes.getbyte(20) ^ 1)
    File.binwrite(index_path, bytes)
    assert_raises(Thuban::CorruptObject) { @repository.index }
    assert_raises(Thuban::CorruptObject) { Thuban::Pack.apply_delta("abc", "\x03\x04\x91\x01\x04".b) }
  end

  def test_checkout_handles_file_directory_transitions_and_ignored_collisions
    git("checkout", "-qb", "directory")
    File.unlink(File.join(@directory, "text.txt"))
    write("text.txt/nested.txt", "nested")
    git("add", ".")
    git("commit", "-qm", "Replace file with directory")
    git("checkout", "-q", "main")
    @repository.checkout("directory")
    assert_equal "nested", File.read(File.join(@directory, "text.txt", "nested.txt"))
    @repository.checkout("main")
    assert_equal "first\nsecond\nthird\n", File.read(File.join(@directory, "text.txt"))
    @repository.checkout("directory")
    write(".git/info/exclude", "*.secret\n")
    write("text.txt/keep.secret", "ignored but preserved")
    assert_raises(ArgumentError) { @repository.checkout("main") }
    assert_equal "ignored but preserved", File.read(File.join(@directory, "text.txt", "keep.secret"))
    assert_equal "directory", @repository.branch
  end

  def test_blame_handles_deep_histories_without_ruby_recursion
    tree = @repository.commit.tree
    parent = @first
    1500.times do |number|
      contents = "tree #{tree}\nparent #{parent}\nauthor Fixture Author <fixture@example.invalid> #{number} +0000\ncommitter Fixture Author <fixture@example.invalid> #{number} +0000\n\nUnchanged text #{number}\n"
      oid = Thuban::ObjectDatabase.hash("commit", contents)
      write(".git/objects/#{oid[0, 2]}/#{oid[2..]}", Zlib::Deflate.deflate("commit #{contents.bytesize}\0" + contents))
      parent = oid
    end
    write(".git/refs/heads/main", "#{parent}\n")
    assert_equal [@first, @first, @first], @repository.blame("text.txt").map(&:commit)
  end

  def with_environment(values)
    previous = values.to_h { |key, _| [key, ENV[key]] }
    values.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    yield
  ensure
    previous.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

end
