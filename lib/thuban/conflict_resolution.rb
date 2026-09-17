# frozen_string_literal: true

module Thuban
  ConflictWorktree = Struct.new(:kind, :content, :mode, keyword_init: true)
  Conflict = Struct.new(:path, :base, :ours, :theirs, :head, :worktree, :index_checksum, keyword_init: true)

  class Repository
    CONFLICT_CHOICES = %i[ours theirs both manual].freeze
    CONFLICT_FILE_MODES = [0o100644, 0o100755, 0o120000].freeze

    def conflicts
      current_index = index
      checksum = current_index.send(:source_checksum)
      current_head = head
      current_index.conflicts.group_by(&:path).sort.map do |path, entries|
        current_index.send(:validate_path, path)
        all_entries = current_index.entries.select { |entry| entry.path == path }
        stages = all_entries.to_h { |entry| [entry.stage, entry] }
        raise CorruptObject, "invalid conflict entries for #{path}" unless
          stages.length == all_entries.length && !stages.key?(0) && stages.keys.all? { |stage| (1..3).cover?(stage) }

        Conflict.new(path: path.dup.freeze, base: conflict_entry(stages[1]), ours: conflict_entry(stages[2]),
          theirs: conflict_entry(stages[3]), head: current_head&.dup&.freeze,
          worktree: conflict_worktree(path), index_checksum: checksum.dup.freeze).freeze
      end
    end

    def resolve_conflict(conflict, choice:, content: nil, mode: nil)
      raise ArgumentError, "expected a Thuban::Conflict" unless conflict.is_a?(Conflict)
      raise ArgumentError, "invalid conflict choice" unless CONFLICT_CHOICES.include?(choice)
      raise ArgumentError, "unsafe conflict worktree type" unless %i[missing file symlink].include?(conflict.worktree.kind)

      current_index = index
      current_index.send(:validate_path, conflict.path)
      entries = current_index.entries.dup
      worktree = {}
      removed = []
      validate = ->(locked_index, backups) { validate_conflict_snapshot!(conflict, locked_index, backups.fetch(conflict.path)) }

      RefStore.new(self).send(:with_lock, "HEAD", old_oid: conflict.head) do
        replace_repository_state(worktree, entries, remove_paths: removed, affected_paths: [conflict.path],
          current_index: current_index, validate: validate) do
          selected = conflict_resolution(conflict, choice, content, mode)
          entries.reject! { |entry| entry.path == conflict.path }
          if selected
            entry, data = selected
            entries << entry
            worktree[conflict.path] = TreeEntry.new(path: conflict.path, oid: entry.oid, mode: entry.mode)
            type, stored = odb.read(entry.oid)
            raise CorruptObject, "conflict entry is not a blob" unless type == "blob" && stored == data
          else
            removed << conflict.path
          end
        end
      end
      conflict.path
    end

    private

    def conflict_entry(entry)
      return unless entry

      copy = entry.dup
      copy.path = copy.path.dup.freeze
      copy.oid = copy.oid.dup.freeze
      copy.freeze
    end

    def conflict_worktree(path)
      absolute = worktree_path(path)
      stat = File.lstat(absolute)
      if stat.symlink?
        ConflictWorktree.new(kind: :symlink, content: File.readlink(absolute).b.freeze, mode: 0o120000).freeze
      elsif stat.file?
        mode = 0o100000 | ((stat.mode & 0o100).positive? ? 0o755 : 0o644)
        ConflictWorktree.new(kind: :file, content: File.binread(absolute).freeze, mode: mode).freeze
      elsif stat.directory?
        ConflictWorktree.new(kind: :directory, content: nil, mode: 0o040000).freeze
      else
        ConflictWorktree.new(kind: :other, content: nil, mode: stat.mode & 0o170000).freeze
      end
    rescue Errno::ENOENT, Errno::ENOTDIR
      ConflictWorktree.new(kind: :missing, content: nil, mode: nil).freeze
    end

    def conflict_resolution(conflict, choice, content, mode)
      case choice
      when :ours, :theirs
        raise ArgumentError, "content and mode are only accepted for both or manual resolution" if content || mode
        entry = conflict.public_send(choice)
        entry && conflict_selected_entry(conflict.path, entry, read_conflict_blob(entry))
      when :both
        raise ArgumentError, "content is only accepted for manual resolution" if content
        conflict_both_resolution(conflict, mode)
      when :manual
        raise ArgumentError, "manual resolution requires String content" unless content.is_a?(String)
        selected_mode = conflict_resolution_mode(conflict, mode)
        conflict_selected_entry(conflict.path, nil, content.b, mode: selected_mode)
      end
    end

    def conflict_both_resolution(conflict, mode)
      raise ArgumentError, "both resolution requires ours and theirs" unless conflict.ours && conflict.theirs
      sides = [conflict.base, conflict.ours, conflict.theirs].compact
      raise ArgumentError, "both resolution only supports regular files" unless
        sides.all? { |entry| [0o100644, 0o100755].include?(entry.mode) }

      base = conflict.base ? read_conflict_blob(conflict.base) : "".b
      ours = read_conflict_blob(conflict.ours)
      theirs = read_conflict_blob(conflict.theirs)
      raise ArgumentError, "both resolution does not support binary files" if [base, ours, theirs].any? { |value| value.include?("\0") }

      result = Porrima::Merge.three_way(base: base, ours: ours, theirs: theirs)
      data = Porrima::Merge.to_resolved_text(Porrima::Merge.resolve_all(result, :ours_then_theirs))
      conflict_selected_entry(conflict.path, nil, data, mode: conflict_resolution_mode(conflict, mode, regular: true))
    end

    def conflict_resolution_mode(conflict, mode, regular: false)
      allowed = regular ? CONFLICT_FILE_MODES.first(2) : CONFLICT_FILE_MODES
      if mode
        raise ArgumentError, "invalid conflict resolution mode" unless allowed.include?(mode)
        return mode
      end

      modes = [conflict.ours, conflict.theirs].compact.map(&:mode).uniq
      raise ArgumentError, "conflict resolution mode is ambiguous" unless modes.length == 1 && allowed.include?(modes.first)

      modes.first
    end

    def conflict_selected_entry(path, source, content, mode: source&.mode)
      raise ArgumentError, "submodule conflicts require separate worktree handling" unless CONFLICT_FILE_MODES.include?(mode)

      oid = source&.oid || write_blob(content)
      [Index::Entry.new(path: path, oid: oid, mode: mode, size: 0, mtime: 0, mtime_nsec: 0,
        ctime: 0, ctime_nsec: 0, dev: 0, ino: 0, uid: 0, gid: 0, stage: 0, flags: 0, extended_flags: 0), content]
    end

    def read_conflict_blob(entry)
      raise ArgumentError, "submodule conflicts require separate worktree handling" if entry.mode == 0o160000
      type, content = odb.read(entry.oid)
      raise CorruptObject, "conflict entry is not a blob" unless type == "blob"

      content
    end

    def validate_conflict_snapshot!(conflict, current_index, worktree_backup)
      expected = [conflict.base, conflict.ours, conflict.theirs].compact.map do |entry|
        [entry.path, entry.stage, entry.mode, entry.oid]
      end.sort_by { |entry| entry[1] }
      actual = current_index.entries.select { |entry| entry.path == conflict.path }.map do |entry|
        [entry.path, entry.stage, entry.mode, entry.oid]
      end.sort_by { |entry| entry[1] }
      stale = conflict.head != head || conflict.index_checksum != current_index.send(:source_checksum) ||
        expected != actual || actual.empty? || actual.any? { |entry| entry[1].zero? } ||
        conflict.worktree != conflict_worktree_backup(worktree_backup) ||
        conflict.worktree != conflict_worktree(conflict.path)
      raise RefLockError, "Git conflict changed since it was read" if stale
    end

    def conflict_worktree_backup(backup)
      case backup&.first
      when :symlink
        ConflictWorktree.new(kind: :symlink, content: backup[1].freeze, mode: 0o120000).freeze
      when :file
        mode = 0o100000 | ((backup[2] & 0o100).positive? ? 0o755 : 0o644)
        ConflictWorktree.new(kind: :file, content: backup[1].freeze, mode: mode).freeze
      else
        ConflictWorktree.new(kind: :missing, content: nil, mode: nil).freeze
      end
    end
  end
end
