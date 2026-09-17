# frozen_string_literal: true

module Thuban
  class Status
    Entry = Struct.new(:path, :index, :worktree, keyword_init: true) do
      def code = index + worktree
    end

    def initialize(repository)
      @repository = repository
    end

    def call
      repository = @repository
      index = repository.index
      head = repository.tree
      filemode = repository.filemode?
      tracked = index.entries.group_by(&:path)
      result = []
      (head.keys | tracked.keys).sort.each do |path|
        entries = tracked[path]
        if entries&.any? { |entry| entry.stage != 0 }
          stages = entries.map(&:stage)
          code = {[1] => "DD", [2] => "AU", [3] => "UA", [1, 2] => "UD", [1, 3] => "DU", [2, 3] => "AA", [1, 2, 3] => "UU"}.fetch(stages.sort, "UU")
          result << Entry.new(path: path, index: code[0], worktree: code[1])
          next
        end
        staged = entries&.first
        original = head[path]
        x = if !original then "A"
        elsif !staged then "D"
        elsif (original.mode & 0o170000) != (staged.mode & 0o170000) then "T"
        elsif original.mode != staged.mode || original.oid != staged.oid then "M"
        else " " end
        y = staged ? worktree_status(staged, index.path, filemode) : " "
        result << Entry.new(path: path, index: x, worktree: y) unless x == " " && y == " "
      end
      submodules = index.entries.select { |entry| entry.mode == 0o160000 }.map { |entry| entry.path + "/" }
      WorktreeFiles.new(repository.root, repository.common_dir).each do |path|
        next if submodules.any? { |prefix| path.start_with?(prefix) }
        result << Entry.new(path: path, index: "?", worktree: "?") unless tracked.key?(path)
      end
      result.sort_by(&:path)
    end

    private

    def worktree_status(entry, index_path, filemode)
      absolute = @repository.worktree_path(entry.path)
      stat = File.lstat(absolute)
      if entry.mode == 0o160000
        return "T" unless stat.directory?
        begin
          return Repository.new(absolute).head == entry.oid ? " " : "M"
        rescue ArgumentError
          return "M"
        end
      end
      mode = stat.symlink? ? 0o120000 : stat.file? ? 0o100000 | ((stat.mode & 0o100).positive? ? 0o755 : 0o644) : 0
      return "T" if (mode & 0o170000) != (entry.mode & 0o170000)
      return "M" if filemode && mode != entry.mode
      return " " if (entry.extended_flags.to_i & 0x4000).positive? # skip-worktree
      index_time = File.mtime(index_path)
      if stat.size == entry.size && stat.mtime.to_i == entry.mtime && stat.mtime.nsec == entry.mtime_nsec &&
          stat.ctime.to_i == entry.ctime && stat.ctime.nsec == entry.ctime_nsec && stat.mtime.to_i < index_time.to_i
        return " "
      end
      content = stat.symlink? ? File.readlink(absolute).b : File.binread(absolute)
      ObjectDatabase.hash("blob", content) == entry.oid ? " " : "M"
    rescue Errno::ENOENT, Errno::ENOTDIR
      (entry.extended_flags.to_i & 0x4000).positive? ? " " : "D"
    end
  end
end
