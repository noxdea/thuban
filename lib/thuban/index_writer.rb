# frozen_string_literal: true

module Thuban
  class Index
    WRITABLE_MODES = [0o100644, 0o100755, 0o120000, 0o160000].freeze
    ENTRY_DEPENDENT_EXTENSIONS = %w[TREE EOIE IEOT].freeze

    def write
      lock_path = path + ".lock"
      FileUtils.mkdir_p(File.dirname(path))
      file = File.open(lock_path, File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
      owns_lock = true
      file.write(self.class.encode(entries, extensions: extensions, version: version))
      file.flush
      file.fsync
      file.close
      File.rename(lock_path, path)
      owns_lock = false
      self
    rescue Errno::EEXIST
      raise IOError, "Git index is locked: #{lock_path}"
    ensure
      file&.close unless file&.closed?
      File.unlink(lock_path) if owns_lock && File.exist?(lock_path)
    end

    def stage(path, oid, mode, stat: nil)
      validate_entry(path, oid, mode)
      entry = Entry.new(path: path, oid: oid, mode: mode, stage: 0, flags: 0, extended_flags: 0,
        **stat_fields(stat))
      entries.reject! { |current| current.path == path }
      entries << entry
      entries.sort_by! { |current| [current.path.b, current.stage] }
      invalidate_entry_extensions
      entry
    end

    def unstage(path)
      validate_path(path)
      removed = entries.select { |entry| entry.path == path && entry.stage.zero? }
      entries.reject! { |entry| entry.path == path && entry.stage.zero? }
      invalidate_entry_extensions unless removed.empty?
      removed
    end

    def remove(path)
      validate_path(path)
      removed = entries.select { |entry| entry.path == path }
      entries.reject! { |entry| entry.path == path }
      invalidate_entry_extensions unless removed.empty?
      removed
    end

    def conflicts = entries.select { |entry| !entry.stage.zero? }

    def resolve(path, oid, mode)
      validate_path(path)
      raise ArgumentError, "path has no index conflict: #{path}" unless entries.any? { |entry| entry.path == path && !entry.stage.zero? }

      stage(path, oid, mode)
    end

    private

    def validate_entry(path, oid, mode)
      validate_path(path)
      raise ArgumentError, "expected a full SHA-1 object id" unless /\A[0-9a-f]{40}\z/.match?(oid.to_s)
      raise ArgumentError, "invalid index mode" unless WRITABLE_MODES.include?(mode)
    end

    def validate_path(path)
      safe = path.is_a?(String) && !path.empty? && !path.include?("\0") && !path.include?("\\") && !path.start_with?("/") &&
        !path.split("/").any? { |part| ["", ".", ".."].include?(part) || part.casecmp?(".git") }
      raise ArgumentError, "unsafe index path" unless safe
    end

    def stat_fields(stat)
      return {size: 0, mtime: 0, mtime_nsec: 0, ctime: 0, ctime_nsec: 0, dev: 0, ino: 0, uid: 0, gid: 0} unless stat

      mtime = stat_value(stat, :mtime)
      ctime = stat_value(stat, :ctime)
      {size: stat_value(stat, :size).to_i, mtime: mtime.to_i, mtime_nsec: mtime.respond_to?(:nsec) ? mtime.nsec : 0,
       ctime: ctime.to_i, ctime_nsec: ctime.respond_to?(:nsec) ? ctime.nsec : 0, dev: stat_value(stat, :dev).to_i,
       ino: stat_value(stat, :ino).to_i, uid: stat_value(stat, :uid).to_i, gid: stat_value(stat, :gid).to_i}
    end

    def stat_value(stat, name)
      stat.respond_to?(name) ? stat.public_send(name) : stat.fetch(name, 0)
    end

    def invalidate_entry_extensions
      extensions.reject! { |extension| ENTRY_DEPENDENT_EXTENSIONS.include?(extension.byteslice(0, 4)) }
    end
  end
end
