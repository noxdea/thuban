# frozen_string_literal: true

module Thuban
  class Repository
    def merge_base(a, b)
      left = require_commit(a).oid
      right = require_commit(b).oid
      ancestors = {}
      walk_commits(left) { |oid| ancestors[oid] = true }
      walk_commits(right) { |oid| return oid if ancestors[oid] }
      nil
    end

    def reset(oid, mode: :mixed)
      raise ArgumentError, "invalid reset mode" unless %i[soft mixed hard].include?(mode)

      target = require_commit(oid)
      target_tree = tree(target.oid)
      replace_index(target_tree) if mode == :mixed
      replace_repository_state(target_tree, target_tree) if mode == :hard
      update_ref("HEAD", target.oid, old_oid: head, message: "reset: moving to #{oid}")
    end

    def cherry_pick(oid)
      source = require_commit(oid)
      raise ArgumentError, "cannot cherry-pick a merge commit" if source.parents.length > 1

      base = source.parents.empty? ? {} : tree(source.parents.first)
      apply_commit_change(source, base, tree(source.oid), author: signature_from(source.author), message: source.message,
        action: "cherry-pick")
    end

    def revert(oid)
      source = require_commit(oid)
      raise ArgumentError, "cannot revert a merge commit" if source.parents.length > 1

      base = source.parents.empty? ? {} : tree(source.parents.first)
      subject = source.message.lines.first.to_s.chomp
      message = "Revert \"#{subject}\"\n\nThis reverts commit #{source.oid}.\n"
      apply_commit_change(source, tree(source.oid), base, author: operation_signature, message: message, action: "revert")
    end

    private

    def require_commit(reference)
      commit(reference) || raise(ArgumentError, "unknown commit: #{reference}")
    end

    def walk_commits(start)
      queue = [start]
      seen = {}
      until queue.empty?
        oid = queue.shift
        next if seen[oid]

        seen[oid] = true
        yield oid
        queue.concat(require_commit(oid).parents)
      end
    end

    def apply_commit_change(source, base, incoming, author:, message:, action:)
      ensure_clean_tracked_state!
      current_oid = head
      raise ArgumentError, "cannot apply a commit on an unborn branch" unless current_oid

      current = tree(current_oid)
      result = current.dup
      conflicts = []
      (base.keys | incoming.keys).each do |path|
        original = base[path]
        ours = current[path]
        theirs = incoming[path]
        if same_tree_entry?(ours, original)
          theirs ? result[path] = theirs : result.delete(path)
        elsif !same_tree_entry?(ours, theirs) && !same_tree_entry?(original, theirs)
          conflicts << path
        end
      end
      raise ArgumentError, "#{action} conflicts: #{conflicts.sort.join(', ')}" unless conflicts.empty?
      raise ArgumentError, "#{action} is empty" if same_tree?(current, result)

      replace_repository_state(result, result)
      tree_oid = write_tree_from_index
      commit_oid = write_commit(tree: tree_oid, parents: [current_oid], author: author,
        committer: operation_signature, message: message)
      update_ref("HEAD", commit_oid, old_oid: current_oid, message: "#{action}: #{source.message.lines.first.to_s.strip}")
    end

    def same_tree?(left, right)
      left.keys.sort == right.keys.sort && left.all? { |path, entry| same_tree_entry?(entry, right[path]) }
    end

    def same_tree_entry?(left, right)
      return left.nil? && right.nil? unless left && right

      left.oid == right.oid && left.mode == right.mode
    end

    def ensure_clean_tracked_state!
      raise ArgumentError, "worktree/index must be clean" if status.any? { |entry| entry.index != "?" }
    end

    def replace_repository_state(worktree_tree, index_tree, remove_paths: [])
      raise ArgumentError, "bare repository has no worktree" unless root
      current = index.entries.to_h { |entry| [entry.path, entry] }
      tracked = head ? tree(head).merge(current) : current
      raise ArgumentError, "submodule updates require separate worktree handling" if
        (tracked.values + worktree_tree.values + index_tree.values).any? { |entry| entry.mode == 0o160000 }

      removed = (tracked.keys - worktree_tree.keys) | remove_paths
      check_worktree_collisions(worktree_tree, tracked, removed)
      contents = worktree_tree.to_h { |path, entry| [path, odb.read(entry.oid).last] }

      removed.sort_by { |path| -path.count("/") }.each do |path|
        absolute = worktree_path(path)
        File.unlink(absolute) if File.file?(absolute) || File.symlink?(absolute)
      end
      prune_empty_directories(removed)
      worktree_tree.sort.each do |path, entry|
        absolute = worktree_path(path)
        Dir.rmdir(absolute) if File.directory?(absolute) && !File.symlink?(absolute)
        FileUtils.mkdir_p(File.dirname(absolute))
        File.unlink(absolute) if File.file?(absolute) || File.symlink?(absolute)
        if entry.mode == 0o120000
          File.symlink(contents.fetch(path), absolute)
        else
          atomic_write(absolute, contents.fetch(path), entry.mode & 0o777)
        end
      end
      replace_index(index_tree)
    end

    def check_worktree_collisions(target, current, removed)
      target.each_key do |path|
        absolute = worktree_path(path, replacing: removed)
        unless current.key?(path)
          if File.directory?(absolute) && !File.symlink?(absolute)
            Find.find(absolute) do |entry|
              next if File.directory?(entry) && !File.symlink?(entry)
              relative = entry.delete_prefix(root + File::SEPARATOR)
              raise ArgumentError, "untracked worktree collision: #{path}" unless removed.include?(relative)
            end
          elsif (File.exist?(absolute) || File.symlink?(absolute)) && !removed.include?(path)
            raise ArgumentError, "untracked worktree collision: #{path}"
          end
        end
        parent = File.dirname(absolute)
        until parent == root
          relative = parent.delete_prefix(root + File::SEPARATOR)
          if (File.file?(parent) || File.symlink?(parent)) && !removed.include?(relative)
            raise ArgumentError, "untracked worktree collision: #{relative}"
          end
          parent = File.dirname(parent)
        end
      end
    end

    def replace_index(target)
      current = index
      current.entries.replace(index_entries(target))
      current.extensions.reject! { |extension| Index::ENTRY_DEPENDENT_EXTENSIONS.include?(extension.byteslice(0, 4)) }
      current.write
    end

    def index_entries(target)
      target.sort.map do |path, entry|
        stat = matching_worktree_stat(path, entry)
        Index::Entry.new(path: path, oid: entry.oid, mode: entry.mode, size: stat&.size.to_i,
          mtime: stat&.mtime.to_i, mtime_nsec: stat&.mtime&.nsec.to_i,
          ctime: stat&.ctime.to_i, ctime_nsec: stat&.ctime&.nsec.to_i,
          dev: stat&.dev.to_i, ino: stat&.ino.to_i, uid: stat&.uid.to_i, gid: stat&.gid.to_i,
          stage: 0, flags: 0, extended_flags: 0)
      end
    end

    def matching_worktree_stat(path, entry)
      absolute = worktree_path(path)
      stat = File.lstat(absolute)
      mode = stat.symlink? ? 0o120000 : stat.file? ? 0o100000 | ((stat.mode & 0o100).positive? ? 0o755 : 0o644) : 0
      return unless mode == entry.mode

      content = stat.symlink? ? File.readlink(absolute).b : File.binread(absolute)
      stat if ObjectDatabase.hash("blob", content) == entry.oid
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def signature_from(value)
      match = value.to_s.match(/\A(.+) <([^<>]+)> (-?\d+) ([+-]\d{4})\z/)
      raise CorruptObject, "invalid commit signature" unless match

      Signature.new(name: match[1], email: match[2], time: Integer(match[3]), offset: match[4])
    end

    def operation_signature
      RefStore.new(self).send(:reflog_signature)
    end
  end
end
