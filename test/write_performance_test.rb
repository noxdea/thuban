# frozen_string_literal: true

require_relative "test_helper"

class WritePerformanceTest < Minitest::Test
  def test_builds_a_five_thousand_entry_tree_without_a_full_scan_per_entry
    directory = Dir.mktmpdir("thuban-write-bench-")
    git_dir = File.join(directory, ".git")
    FileUtils.mkdir_p(File.join(git_dir, "objects"))
    File.binwrite(File.join(git_dir, "HEAD"), "ref: refs/heads/main\n")
    repository = Thuban::Repository.new(directory)
    blob = repository.write_blob("x")
    entries = 5_000.times.map do |number|
      Thuban::Index::Entry.new(path: format("files/%05d.txt", number), oid: blob, mode: 0o100644,
        size: 1, mtime: 0, mtime_nsec: 0, ctime: 0, ctime_nsec: 0, dev: 0, ino: 0, uid: 0, gid: 0, stage: 0)
    end
    File.binwrite(File.join(git_dir, "index"), Thuban::Index.encode(entries))

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    repository.write_tree_from_index
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 10
  ensure
    FileUtils.remove_entry(directory) if directory && File.exist?(directory)
  end
end
