# frozen_string_literal: true

require_relative "test_helper"

class IndexWriterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-index-write-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    File.binwrite(File.join(@directory, "tracked.txt"), "old\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    @repository = Thuban::Repository.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_stages_removes_and_writes_an_index_git_can_read
    File.binwrite(File.join(@directory, "tracked.txt"), "new\n")
    File.binwrite(File.join(@directory, "added.txt"), "added\n")
    index = @repository.index
    tracked = @repository.write_blob("new\n")
    added = @repository.write_blob("added\n")
    index.stage("tracked.txt", tracked, 0o100644, stat: File.stat(File.join(@directory, "tracked.txt")))
    index.stage("added.txt", added, 0o100644, stat: File.stat(File.join(@directory, "added.txt")))
    index.write

    assert_equal ["A  added.txt", "M  tracked.txt"], git("status", "--porcelain=v1").lines.map(&:chomp).sort
    assert_equal added, git("rev-parse", ":added.txt").strip
    index = @repository.index
    index.remove("added.txt")
    index.unstage("tracked.txt")
    index.write
    assert_equal ["?? added.txt", "?? tracked.txt", "D  tracked.txt"], git("status", "--porcelain=v1").lines.map(&:chomp).sort
  end

  def test_preserves_optional_extensions_and_invalidates_only_entry_caches
    git("config", "core.untrackedCache", "true")
    git("status", "--porcelain=v1")
    git("write-tree")
    add_extension("ZZZZ", "opaque\0bytes".b)

    index = @repository.index
    assert_equal %w[TREE UNTR ZZZZ], signatures(index)
    original_bytes = File.binread(index.path)
    before = index.extensions.map(&:dup)
    index.write
    assert_equal original_bytes, File.binread(index.path)
    assert_equal before, @repository.index.extensions

    blob = @repository.write_blob("old\n")
    index.stage("tracked.txt", blob, 0o100644, stat: File.stat(File.join(@directory, "tracked.txt")))
    assert_equal %w[UNTR ZZZZ], signatures(index)
    index.write
    assert_equal %w[UNTR ZZZZ], signatures(@repository.index)
    assert_empty git("status", "--porcelain=v1")
  end

  def test_round_trips_version_four_and_resolves_conflicts
    %w[a/one.txt a/two.txt].each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(@directory, path)))
      File.binwrite(File.join(@directory, path), path)
    end
    git("add", ".")
    git("update-index", "--index-version=4")
    git("commit", "-qm", "Add nested files")
    original = @repository.index
    assert_equal 4, original.version
    original_bytes = File.binread(original.path)
    original.write
    assert_equal original_bytes, File.binread(original.path)
    assert_equal original.entries.map { |entry| [entry.path, entry.oid] }, @repository.index.entries.map { |entry| [entry.path, entry.oid] }
    assert_empty git("status", "--porcelain=v1")

    oid = @repository.write_blob("resolved\n")
    conflict = @repository.index
    base = conflict["tracked.txt"]
    conflict.remove("tracked.txt")
    (1..3).each { |stage| conflict.entries << base.dup.tap { |entry| entry.stage = stage } }
    conflict.write
    assert_equal [1, 2, 3], @repository.index.conflicts.map(&:stage)
    conflict = @repository.index
    conflict.resolve("tracked.txt", oid, 0o100644)
    conflict.write
    assert_empty @repository.index.conflicts
    assert_equal oid, git("rev-parse", ":tracked.txt").strip
  end

  def test_round_trips_extended_flags_in_versions_three_and_four
    long_path = "a" * 130
    File.binwrite(File.join(@directory, long_path), "long\n")
    git("add", long_path)
    git("update-index", "--skip-worktree", "tracked.txt")
    expected_status = git("status", "--porcelain=v1")
    [3, 4].each do |version|
      git("update-index", "--index-version=#{version}")
      index = @repository.index
      assert_equal version, index.version
      assert_operator index["tracked.txt"].extended_flags, :>, 0
      original = File.binread(index.path)
      index.write
      assert_equal original, File.binread(index.path)
      assert_equal expected_status, git("status", "--porcelain=v1")
    end
  end

  def test_rejects_bad_checksums_and_required_extensions
    path = File.join(@directory, ".git", "index")
    original = File.binread(path)
    File.binwrite(path, original.dup.tap { |bytes| bytes.setbyte(12, bytes.getbyte(12) ^ 1) })
    assert_raises(Thuban::CorruptObject) { @repository.index }

    File.binwrite(path, original)
    bytes = original.byteslice(0...-20) + "link" + [0].pack("N")
    File.binwrite(path, bytes + Digest::SHA1.digest(bytes))
    error = assert_raises(Thuban::CorruptObject) { @repository.index }
    assert_match(/unsupported mandatory index extension link/, error.message)

    File.binwrite(path, original)
    git("update-index", "--split-index")
    assert_raises(Thuban::CorruptObject) { @repository.index }
  end

  def test_keeps_a_foreign_lock_created_after_replacement
    index = @repository.index
    lock = index.path + ".lock"
    rename = File.method(:rename)
    replacement = lambda do |source, target|
      rename.call(source, target)
      File.binwrite(source, "foreign") if source == lock
    end

    File.stub(:rename, replacement) { index.write }
    assert_equal "foreign", File.binread(lock)
  end

  def test_rejects_an_external_index_update_without_overwriting_it
    index = @repository.index
    File.binwrite(File.join(@directory, "external.txt"), "external\n")
    git("add", "external.txt")
    external = File.binread(index.path)

    assert_raises(Thuban::RefLockError) { index.write }
    assert_equal external, File.binread(index.path)
    refute File.exist?(index.path + ".lock")
    assert_equal "external.txt", git("ls-files", "external.txt").strip
  end

  def test_rejects_an_index_created_after_loading_an_absent_index
    path = File.join(@directory, ".git", "index")
    File.unlink(path)
    index = @repository.index
    git("read-tree", "HEAD")
    external = File.binread(path)

    assert_raises(Thuban::RefLockError) { index.write }
    assert_equal external, File.binread(path)
    refute File.exist?(path + ".lock")
    assert_equal "tracked.txt", git("ls-files").strip
  end

  def test_refreshes_the_source_checksum_after_a_successful_write
    index = @repository.index

    assert_same index, index.write
    assert_same index, index.write
    assert_empty git("status", "--porcelain=v1")
  end

  def test_preserves_resolve_undo_records
    git("checkout", "-qb", "side")
    File.binwrite(File.join(@directory, "tracked.txt"), "side\n")
    git("commit", "-qam", "Side")
    git("checkout", "-q", "main")
    File.binwrite(File.join(@directory, "tracked.txt"), "main\n")
    git("commit", "-qam", "Main")
    _output, _error, status = Open3.capture3("git", "-C", @directory, "merge", "side", binmode: true)
    refute status.success?
    git("checkout", "--ours", "tracked.txt")
    git("add", "tracked.txt")

    before = git("ls-files", "--resolve-undo")
    refute_empty before
    index = @repository.index
    assert_includes signatures(index), "REUC"
    index.write
    assert_equal before, git("ls-files", "--resolve-undo")
  end

  def test_rejects_unsafe_paths_and_honors_index_lock
    index = @repository.index
    oid = @repository.write_blob("bad")
    assert_raises(ArgumentError) { index.stage("../bad", oid, 0o100644) }
    assert_raises(ArgumentError) { index.stage(".GIT/config", oid, 0o100644) }
    assert_raises(ArgumentError) { index.stage("..\\config", oid, 0o100644) }
    index.extensions << "bad"
    assert_raises(ArgumentError) { index.write }
    refute File.exist?(index.path + ".lock")
    File.binwrite(index.path + ".lock", "held")
    assert_raises(IOError) { index.write }
    assert_equal "held", File.binread(index.path + ".lock")
  end

  private

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(" ")}: #{error}"
    output
  end

  def signatures(index) = index.extensions.map { |extension| extension.byteslice(0, 4) }

  def add_extension(signature, payload)
    path = File.join(@directory, ".git", "index")
    bytes = File.binread(path).byteslice(0...-20)
    bytes << signature << [payload.bytesize].pack("N") << payload
    File.binwrite(path, bytes + Digest::SHA1.digest(bytes))
  end
end
