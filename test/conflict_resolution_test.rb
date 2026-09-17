# frozen_string_literal: true

require_relative "test_helper"

class ConflictResolutionTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-conflicts-")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Author")
    git("config", "user.email", "fixture@example.invalid")
    git("config", "core.autocrlf", "false")
    write("alpha.txt", "alpha base\n")
    write("beta.txt", "beta base\n")
    git("add", ".")
    git("commit", "-qm", "Initial")
    @repository = Thuban::Repository.new(@directory)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_captures_conflicts_and_resolves_sides_without_touching_other_paths
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    install_conflict("beta.txt", ours: "beta ours\n", theirs: "beta theirs\n")

    conflicts = @repository.conflicts
    assert_equal %w[alpha.txt beta.txt], conflicts.map(&:path)
    alpha = conflicts.first
    assert alpha.frozen?
    assert alpha.ours.frozen?
    assert alpha.worktree.frozen?
    assert_equal "alpha base\n", @repository.object(alpha.base.oid).last

    assert_equal "alpha.txt", @repository.resolve_conflict(alpha, choice: :ours)
    assert_equal "alpha ours\n", @repository.worktree_content("alpha.txt")
    assert_equal "alpha ours\n", @repository.staged_blob("alpha.txt")
    assert_equal ["beta.txt"], @repository.conflicts.map(&:path)
    assert_empty git("ls-files", "-u", "--", "alpha.txt")
    refute_empty git("ls-files", "-u", "--", "beta.txt")
    assert_status_matches_git

    beta = @repository.conflicts.first
    @repository.resolve_conflict(beta, choice: :theirs)
    assert_equal "beta theirs\n", @repository.worktree_content("beta.txt")
    assert_empty @repository.conflicts
    assert_empty git("ls-files", "-u")
    assert_status_matches_git
  end

  def test_both_uses_a_three_way_text_resolution
    install_conflict("alpha.txt", base: "first\nbase\nlast\n", ours: "first\nours\nlast\n",
      theirs: "first\ntheirs\nlast\n")

    @repository.resolve_conflict(@repository.conflicts.first, choice: :both)

    assert_equal "first\nours\ntheirs\nlast\n", @repository.worktree_content("alpha.txt")
    assert_equal @repository.worktree_content("alpha.txt"), @repository.staged_blob("alpha.txt")
    assert_status_matches_git
  end

  def test_manual_accepts_binary_content_and_requires_an_unambiguous_mode
    install_conflict("alpha.txt", ours: "ours\0", theirs: "theirs\0")
    content = "resolved\0bytes".b

    @repository.resolve_conflict(@repository.conflicts.first, choice: :manual, content: content)

    assert_equal content, @repository.worktree_content("alpha.txt")
    assert_equal content, @repository.staged_blob("alpha.txt")
    assert_status_matches_git

    install_conflict("beta.txt", ours: "ours\n", theirs: "theirs\n", ours_mode: 0o100644, theirs_mode: 0o100755)
    conflict = @repository.conflicts.find { |entry| entry.path == "beta.txt" }
    before = repository_state("beta.txt")
    error = assert_raises(ArgumentError) { @repository.resolve_conflict(conflict, choice: :manual, content: "resolved\n") }
    assert_match(/mode is ambiguous/, error.message)
    assert_equal before, repository_state("beta.txt")

    @repository.resolve_conflict(conflict, choice: :manual, content: "resolved\n", mode: 0o100644)
    assert_equal "100644", git("ls-files", "--stage", "--", "beta.txt").split.first
  end

  def test_deleted_side_removes_the_worktree_and_only_that_conflict
    install_conflict("alpha.txt", ours: nil, theirs: "kept by theirs\n")
    install_conflict("beta.txt", ours: "beta ours\n", theirs: "beta theirs\n")

    @repository.resolve_conflict(@repository.conflicts.find { |entry| entry.path == "alpha.txt" }, choice: :ours)

    refute File.exist?(path("alpha.txt"))
    assert_empty git("ls-files", "-u", "--", "alpha.txt")
    assert_empty git("ls-files", "--stage", "--", "alpha.txt")
    assert_equal ["beta.txt"], @repository.conflicts.map(&:path)
    assert_status_matches_git
  end

  def test_symlink_side_is_installed_without_following_it
    skip "symlinks unavailable" unless symlinks_available?
    install_conflict("alpha.txt", ours: "ours-target", theirs: "theirs-target", ours_mode: 0o120000, theirs_mode: 0o120000,
      worktree: [:symlink, "marker-target"])

    @repository.resolve_conflict(@repository.conflicts.first, choice: :theirs)

    assert File.symlink?(path("alpha.txt"))
    assert_equal "theirs-target", File.readlink(path("alpha.txt"))
    assert_equal "120000", git("ls-files", "--stage", "--", "alpha.txt").split.first
    assert_status_matches_git
  end

  def test_rejects_unsupported_combination_binary_submodule_and_path_inputs_without_changes
    install_conflict("alpha.txt", ours: "ours\0", theirs: "theirs\0")
    conflict = @repository.conflicts.first
    before = repository_state("alpha.txt")
    assert_raises(ArgumentError) { @repository.resolve_conflict(conflict, choice: :both) }
    assert_raises(ArgumentError) { @repository.resolve_conflict(conflict, choice: :unknown) }
    assert_raises(ArgumentError) { @repository.resolve_conflict(conflict, choice: :manual) }
    assert_equal before, repository_state("alpha.txt")

    unsafe = conflict.dup
    unsafe.path = "../outside.txt"
    assert_raises(ArgumentError) { @repository.resolve_conflict(unsafe, choice: :ours) }
    refute File.exist?(File.join(@directory, "..", "outside.txt"))
    assert_equal before, repository_state("alpha.txt")

    install_conflict("beta.txt", base: nil, ours: @repository.head, theirs: @repository.head,
      ours_mode: 0o160000, theirs_mode: 0o160000, object_ids: true)
    submodule = @repository.conflicts.find { |entry| entry.path == "beta.txt" }
    assert_raises(ArgumentError) { @repository.resolve_conflict(submodule, choice: :ours) }
    refute_empty git("ls-files", "-u", "--", "beta.txt")
  end

  def test_rejects_a_directory_at_the_conflict_path_without_deleting_its_contents
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    File.unlink(path("alpha.txt"))
    FileUtils.mkdir_p(path("alpha.txt"))
    write("alpha.txt/untracked.txt", "keep\n")
    conflict = @repository.conflicts.first
    index = File.binread(path(".git/index"))

    assert_equal :directory, conflict.worktree.kind
    assert_raises(ArgumentError) { @repository.resolve_conflict(conflict, choice: :ours) }
    assert_equal "keep\n", File.binread(path("alpha.txt/untracked.txt"))
    assert_equal index, File.binread(path(".git/index"))
  end

  def test_rejects_stale_head_index_and_worktree_snapshots_before_writing
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    snapshot = @repository.conflicts.first
    write("alpha.txt", "edited after snapshot\n")
    index = File.binread(path(".git/index"))
    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(snapshot, choice: :ours) }
    assert_equal "edited after snapshot\n", File.binread(path("alpha.txt"))
    assert_equal index, File.binread(path(".git/index"))

    write("alpha.txt", conflict_marker("alpha ours\n", "alpha theirs\n"))
    snapshot = @repository.conflicts.first
    install_conflict("beta.txt", ours: "changed index ours\n", theirs: "changed index theirs\n")
    index = File.binread(path(".git/index"))
    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(snapshot, choice: :ours) }
    assert_equal index, File.binread(path(".git/index"))
    assert_equal conflict_marker("alpha ours\n", "alpha theirs\n"), File.binread(path("alpha.txt"))

    snapshot = @repository.conflicts.find { |entry| entry.path == "alpha.txt" }
    tree = git("rev-parse", "HEAD^{tree}").strip
    changed_head = git_with_input("commit-tree", tree, "-p", @repository.head, input: "Changed head\n").strip
    git("update-ref", "HEAD", changed_head)
    index = File.binread(path(".git/index"))
    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(snapshot, choice: :ours) }
    assert_equal index, File.binread(path(".git/index"))
    assert_equal conflict_marker("alpha ours\n", "alpha theirs\n"), File.binread(path("alpha.txt"))
  end

  def test_rejects_forged_conflict_entries
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    conflict = @repository.conflicts.first
    before = repository_state("alpha.txt")

    forged = conflict.dup
    forged.ours = conflict.theirs
    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(forged, choice: :ours) }
    assert_equal before, repository_state("alpha.txt")

    forged = conflict.dup
    forged.ours = nil
    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(forged, choice: :ours) }
    assert_equal before, repository_state("alpha.txt")
  end

  def test_rejects_stale_or_unsafe_manual_resolution_before_writing_a_blob
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    conflict = @repository.conflicts.first
    write("alpha.txt", "edited after snapshot\n")
    before = loose_objects

    assert_raises(Thuban::RefLockError) do
      @repository.resolve_conflict(conflict, choice: :manual, content: "must not become a loose object\n")
    end
    assert_equal before, loose_objects

    forged = conflict.dup
    forged.path = "../outside.txt"
    assert_raises(ArgumentError) do
      @repository.resolve_conflict(forged, choice: :manual, content: "must not escape\n")
    end
    assert_equal before, loose_objects
  end

  def test_rejects_worktree_changes_during_transaction_preparation
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    snapshot = @repository.conflicts.first
    index = File.binread(path(".git/index"))
    original = @repository.method(:worktree_backup)
    changed = false
    target = path("alpha.txt")
    @repository.define_singleton_method(:worktree_backup) do |pathname|
      backup = original.call(pathname)
      unless changed
        changed = true
        File.binwrite(target, "concurrent edit\n")
      end
      backup
    end

    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(snapshot, choice: :ours) }
    assert_equal "concurrent edit\n", File.binread(target)
    assert_equal index, File.binread(path(".git/index"))
  end

  def test_rechecks_the_worktree_at_the_write_boundary
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    snapshot = @repository.conflicts.first
    index = File.binread(path(".git/index"))
    original = @repository.method(:write_worktree_tree)
    target = path("alpha.txt")
    @repository.define_singleton_method(:write_worktree_tree) do |*arguments, &guard|
      File.binwrite(target, "last moment edit\n")
      original.call(*arguments, &guard)
    end

    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(snapshot, choice: :ours) }
    assert_equal "last moment edit\n", File.binread(target)
    assert_equal index, File.binread(path(".git/index"))
  end

  def test_holds_the_head_ref_lock_while_resolving
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    snapshot = @repository.conflicts.first
    tree = git("rev-parse", "HEAD^{tree}").strip
    next_head = git_with_input("commit-tree", tree, "-p", @repository.head, input: "Concurrent head\n").strip
    original = @repository.method(:conflict_resolution)
    started = Queue.new
    release = Queue.new
    @repository.define_singleton_method(:conflict_resolution) do |*arguments|
      started << true
      release.pop
      original.call(*arguments)
    end
    job = Thread.new { @repository.resolve_conflict(snapshot, choice: :ours) }
    started.pop

    _output, error, status = Open3.capture3("git", "-C", @directory, "update-ref", "HEAD", next_head, binmode: true)
    refute status.success?
    assert_match(/lock/, error)
    assert_equal snapshot.head, @repository.head
    release << true
    assert_equal "alpha.txt", job.value
    assert_equal "alpha ours\n", @repository.worktree_content("alpha.txt")
  ensure
    release << true if release && release.empty?
    job&.join
  end

  def test_lock_cas_and_failed_index_publish_leave_the_repository_unchanged
    install_conflict("alpha.txt", ours: "alpha ours\n", theirs: "alpha theirs\n")
    snapshot = @repository.conflicts.first
    before = repository_state("alpha.txt")
    lock = path(".git/index.lock")
    File.binwrite(lock, "held")
    assert_raises(IOError) { @repository.resolve_conflict(snapshot, choice: :ours) }
    assert_equal before, repository_state("alpha.txt")
    assert_equal "held", File.binread(lock)
    File.unlink(lock)

    stale = @repository.index
    stale.define_singleton_method(:source_unchanged?) { false }
    @repository.define_singleton_method(:index) { stale }
    assert_raises(Thuban::RefLockError) { @repository.resolve_conflict(snapshot, choice: :ours) }
    assert_equal before, repository_state("alpha.txt")
    @repository.singleton_class.send(:remove_method, :index)

    rename = File.method(:rename)
    failing = lambda do |source, target|
      raise Errno::EACCES, target if source == lock && target == path(".git/index")

      rename.call(source, target)
    end
    File.stub(:rename, failing) do
      assert_raises(Errno::EACCES) { @repository.resolve_conflict(snapshot, choice: :ours) }
    end
    assert_equal before, repository_state("alpha.txt")
    refute File.exist?(lock)
  end

  private

  def install_conflict(pathname, base: :head, ours:, theirs:, ours_mode: 0o100644, theirs_mode: 0o100644,
    base_mode: 0o100644, worktree: nil, object_ids: false)
    head_base = base == :head
    base = @repository.tree[pathname]&.oid if head_base
    values = {1 => [base_mode, base], 2 => [ours_mode, ours], 3 => [theirs_mode, theirs]}
    lines = values.filter_map do |stage, (mode, value)|
      next unless value

      oid = object_ids || (stage == 1 && head_base) ? value : @repository.write_blob(value)
      "#{mode.to_s(8)} #{oid} #{stage}\t#{pathname}\n"
    end
    git("update-index", "--force-remove", "--", pathname)
    git_with_input("update-index", "--index-info", input: lines.join)
    if worktree&.first == :symlink
      File.unlink(path(pathname)) if File.exist?(path(pathname)) || File.symlink?(path(pathname))
      File.symlink(worktree.last, path(pathname))
    else
      ours_content = object_ids ? "ours gitlink\n" : ours.to_s
      theirs_content = object_ids ? "theirs gitlink\n" : theirs.to_s
      write(pathname, worktree || conflict_marker(ours_content, theirs_content))
    end
  end

  def conflict_marker(ours, theirs)
    "<<<<<<< ours\n#{ours}=======\n#{theirs}>>>>>>> theirs\n"
  end

  def repository_state(pathname)
    [File.binread(path(".git/index")), @repository.worktree_content(pathname)]
  end

  def loose_objects = Dir[path(".git/objects/[0-9a-f][0-9a-f]/*")].sort

  def assert_status_matches_git
    expected = git("status", "--porcelain=v1").lines.to_h { |line| [line.byteslice(3..).strip, line.byteslice(0, 2)] }
    actual = @repository.status.to_h { |entry| [entry.path, entry.code] }
    assert_equal expected, actual
  end

  def symlinks_available?
    probe = path("symlink-probe")
    File.symlink("target", probe)
    File.unlink(probe)
    true
  rescue NotImplementedError, SystemCallError
    false
  end

  def write(pathname, content)
    FileUtils.mkdir_p(File.dirname(path(pathname)))
    File.binwrite(path(pathname), content)
  end

  def path(pathname) = File.join(@directory, pathname)

  def git(*arguments) = git_with_input(*arguments, input: nil)

  def git_with_input(*arguments, input:)
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, stdin_data: input, binmode: true)
    assert status.success?, "git #{arguments.join(" ")}: #{error}"
    output
  end
end
