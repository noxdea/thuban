# frozen_string_literal: true

module Thuban
  class Repository
    def stash_push(message: nil, include_untracked: false)
      current_head = head
      raise ArgumentError, "cannot stash on an unborn branch" unless current_head
      current_index = index
      raise ArgumentError, "cannot stash unresolved conflicts" unless current_index.conflicts.empty?

      changes = status
      untracked = changes.select { |entry| entry.index == "?" }.map(&:path)
      return nil unless changes.any? { |entry| entry.index != "?" } || (include_untracked && !untracked.empty?)

      identity = operation_signature
      description = "#{current_head[0, 7]} #{require_commit(current_head).message.lines.first.to_s.strip}"
      location = branch || "(no branch)"
      stash_message = message ? "On #{location}: #{message}" : "WIP on #{location}: #{description}"
      index_tree = write_tree_from_entries(current_index.entries)
      index_commit = write_commit(tree: index_tree, parents: [current_head], author: identity,
        message: "index on #{location}: #{description}")
      parents = [current_head, index_commit]
      if include_untracked && !untracked.empty?
        untracked_tree = write_tree_from_entries(worktree_entries(untracked))
        parents << write_commit(tree: untracked_tree, author: identity,
          message: "untracked files on #{location}: #{description}")
      end
      worktree_tree = write_tree_from_entries(worktree_entries((tree(current_head).keys | current_index.entries.map(&:path))))
      oid = write_commit(tree: worktree_tree, parents: parents, author: identity, message: stash_message)
      update_ref("refs/stash", oid, old_oid: resolve("refs/stash"), message: stash_message)
      replace_repository_state(tree(current_head), tree(current_head), remove_paths: include_untracked ? untracked : [])
      oid
    end

    def stash_list
      stash_records.reverse.map { |record| require_commit(record_oid(record)) }
    end

    def stash_pop(index = 0)
      raise ArgumentError, "stash index must be a non-negative Integer" unless index.is_a?(Integer) && index >= 0
      ensure_clean_tracked_state!
      records = stash_records
      position = records.length - index - 1
      raise ArgumentError, "stash not found: #{index}" if position.negative?

      oid = record_oid(records.fetch(position))
      stored = require_commit(oid)
      raise CorruptObject, "invalid stash commit" unless stored.parents.length >= 2

      worktree_tree = tree(stored.oid)
      worktree_tree = worktree_tree.merge(tree(stored.parents[2])) if stored.parents[2]
      index_tree = tree(stored.parents[1])
      replace_repository_state(worktree_tree, index_tree)
      drop_stash(records, position, oid)
      oid
    end

    private

    def worktree_entries(paths)
      paths.sort.filter_map do |path|
        absolute = worktree_path(path)
        stat = File.lstat(absolute)
        next unless stat.file? || stat.symlink?

        contents = stat.symlink? ? File.readlink(absolute).b : File.binread(absolute)
        mode = stat.symlink? ? 0o120000 : (stat.mode & 0o100).positive? ? 0o100755 : 0o100644
        Index::Entry.new(path: path, oid: write_blob(contents), mode: mode, size: stat.size,
          mtime: stat.mtime.to_i, mtime_nsec: stat.mtime.nsec, ctime: stat.ctime.to_i, ctime_nsec: stat.ctime.nsec,
          dev: stat.dev, ino: stat.ino, uid: stat.uid, gid: stat.gid, stage: 0, flags: 0, extended_flags: 0)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
    end

    def stash_records
      path = File.join(common_dir, "logs", "refs", "stash")
      File.file?(path) ? File.readlines(path, chomp: true, encoding: Encoding::BINARY) : []
    end

    def record_oid(record)
      oid = record.split(" ", 3)[1]
      raise CorruptObject, "invalid stash reflog" unless oid&.match?(/\A[0-9a-f]{40}\z/)

      oid
    end

    def drop_stash(records, position, oid)
      kept = records.dup
      kept.delete_at(position)
      if kept.empty?
        delete_ref("refs/stash", old_oid: oid)
        return
      end

      ref_path = File.join(common_dir, "refs", "stash")
      log_path = File.join(common_dir, "logs", "refs", "stash")
      locks = {}
      [ref_path, log_path].sort.each do |path|
        FileUtils.mkdir_p(File.dirname(path))
        locks[path] = File.open(path + ".lock", File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
      end
      locks.fetch(ref_path).write("#{record_oid(kept.last)}\n")
      locks.fetch(log_path).write(kept.join("\n") + "\n")
      locks.each_value { |file| file.flush; file.fsync; file.close }
      [log_path, ref_path].each do |path|
        File.rename(locks.fetch(path).path, path)
        locks.delete(path)
      end
    rescue Errno::EEXIST => error
      raise RefLockError, "stash is locked: #{error.message}"
    ensure
      locks&.each_value do |file|
        file.close unless file.closed?
        File.unlink(file.path) if File.exist?(file.path)
      end
    end
  end
end
