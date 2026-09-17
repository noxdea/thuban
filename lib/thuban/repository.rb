# frozen_string_literal: true

module Thuban
  class Repository
    attr_reader :root, :git_dir, :common_dir, :odb

    def initialize(path)
      directory = File.expand_path(path)
      directory = File.dirname(directory) unless File.directory?(directory)
      loop do
        location = File.join(directory, ".git")
        if File.directory?(location)
          @root, @git_dir = directory, location
          break
        elsif File.file?(location)
          value = File.read(location).strip
          raise ArgumentError, "invalid gitdir file" unless value.start_with?("gitdir: ")
          @root, @git_dir = directory, File.expand_path(value.delete_prefix("gitdir: "), directory)
          break
        elsif File.file?(File.join(directory, "HEAD")) && File.directory?(File.join(directory, "objects"))
          @root, @git_dir = nil, directory
          break
        end
        parent = File.dirname(directory)
        raise ArgumentError, "not a Git repository: #{path}" if parent == directory
        directory = parent
      end
      common = File.join(git_dir, "commondir")
      @common_dir = File.file?(common) ? File.expand_path(File.read(common).strip, git_dir) : git_dir
      config = File.join(common_dir, "config")
      raise ArgumentError, "SHA-256 repositories are not supported" if File.file?(config) && File.read(config).match?(/objectformat\s*=\s*sha256/i)
      @odb = ObjectDatabase.new(File.join(common_dir, "objects"))
    end

    def object(oid) = odb.read(resolve(oid) || oid)
    def index = Index.new(File.join(git_dir, "index"))
    def head = resolve("HEAD")

    def signature(role: :author)
      current_signature(role, fallback: false)
    end

    def branch
      text = File.read(File.join(git_dir, "HEAD")).strip
      text.start_with?("ref: refs/heads/") ? text.delete_prefix("ref: refs/heads/") : nil
    end

    def refs
      result = {}
      packed = File.join(common_dir, "packed-refs")
      if File.file?(packed)
        File.foreach(packed) do |line|
          next if line.start_with?("#", "^")
          oid, name = line.strip.split(" ", 2)
          result[name] = oid if name && /\A[0-9a-f]{40}\z/.match?(oid)
        end
      end
      Dir[File.join(common_dir, "refs", "**", "*")].sort.each do |path|
        next unless File.file?(path)
        name = path.delete_prefix(common_dir + "/")
        result[name] = resolve(name)
      end
      result
    end

    def branches = refs.keys.grep(%r{\Arefs/heads/}).map { |ref| ref.delete_prefix("refs/heads/") }.sort

    def resolve(name, seen = [])
      return name if /\A[0-9a-f]{40}\z/.match?(name.to_s)
      raise ArgumentError, "invalid Git reference" unless name.is_a?(String) && !name.empty? && !name.start_with?("/") && !name.split("/").any? { |piece| piece == ".." || piece.empty? } && !name.match?(/[\x00-\x20\\]/)
      raise CorruptObject, "cyclic symbolic reference" if seen.include?(name) || seen.length > 32
      candidates = name == "HEAD" || name.start_with?("refs/") ? [name] : ["refs/heads/#{name}", "refs/tags/#{name}", "refs/remotes/#{name}"]
      candidates.each do |candidate|
        directory = candidate == "HEAD" ? git_dir : common_dir
        path = File.join(directory, candidate)
        if File.file?(path)
          value = File.read(path).strip
          return resolve(value.delete_prefix("ref: "), seen + [name]) if value.start_with?("ref: ")
          raise CorruptObject, "invalid reference #{candidate}" unless value.match?(/\A[0-9a-f]{40}\z/)
          return value
        end
        packed = File.join(common_dir, "packed-refs")
        next unless File.file?(packed)
        File.foreach(packed) do |line|
          oid, reference = line.strip.split(" ", 2)
          return oid if reference == candidate && oid.match?(/\A[0-9a-f]{40}\z/)
        end
      end
      nil
    end

    def commit(reference = "HEAD")
      oid = resolve(reference)
      return nil unless oid
      seen = []
      loop do
        type, data = odb.read(oid)
        if type == "tag"
          raise CorruptObject, "cyclic annotated tag" if seen.include?(oid)
          seen << oid
          oid = data.lines.find { |line| line.start_with?("object ") }&.split&.last
          next
        end
        raise ArgumentError, "reference is not a commit" unless type == "commit"
        headers, message = data.split("\n\n", 2)
        values = headers.lines.reject { |line| line.start_with?(" ") }.map { |line| line.chomp.split(" ", 2) }
        return Commit.new(oid: oid, tree: values.assoc("tree")&.last,
          parents: values.select { |key, _| key == "parent" }.map(&:last),
          author: values.assoc("author")&.last, committer: values.assoc("committer")&.last,
          message: message.to_s.force_encoding(Encoding::UTF_8))
      end
    end

    def tree(reference = "HEAD")
      revision = commit(reference)
      revision ? read_tree(revision.tree) : {}
    end

    def blob(path, reference: "HEAD")
      entry = tree(reference)[path]
      entry && entry.mode != 0o160000 ? odb.read(entry.oid).last : nil
    end

    def staged_blob(path)
      entry = index[path]
      entry ? odb.read(entry.oid).last : nil
    end

    def status = Status.new(self).call
    def blame(path, reference: "HEAD", differ: Porrima) = Blame.new(self).call(path, reference: reference, differ: differ)

    def worktree_content(path)
      absolute = worktree_path(path)
      return File.readlink(absolute).b if File.symlink?(absolute)
      File.file?(absolute) ? File.binread(absolute) : nil
    end

    def write(path, content)
      absolute = worktree_path(path)
      raise ArgumentError, "cannot write through a symlink" if File.symlink?(absolute)
      atomic_write(absolute, content, File.stat(absolute).mode & 0o777)
      content
    end

    def worktree_path(path, replacing: [])
      raise ArgumentError, "bare repository has no worktree" unless root
      raise ArgumentError, "unsafe worktree path" if path.empty? || path.start_with?("/") || path.split("/").any? { |part| ["..", ".git", ""].include?(part) }
      absolute = File.expand_path(path, root)
      raise ArgumentError, "path outside worktree" unless absolute.start_with?(root + "/")
      parent = File.dirname(absolute)
      while parent != root
        raise ArgumentError, "worktree parent is a symlink" if File.symlink?(parent) && !replacing.include?(parent.delete_prefix(root + "/"))
        parent = File.dirname(parent)
      end
      absolute
    end

    # Checkout is deliberately limited to a clean index and tracked worktree.
    # Untracked files are retained and any collision aborts before the first write.
    def checkout(name)
      raise ArgumentError, "unknown branch: #{name}" unless branches.include?(name)
      raise ArgumentError, "worktree/index must be clean" if status.any? { |entry| entry.index != "?" }
      target = tree("refs/heads/#{name}")
      current = index.entries.to_h { |entry| [entry.path, entry] }
      raise ArgumentError, "submodule checkout requires separate worktree handling" if (target.values + current.values).any? { |entry| entry.mode == 0o160000 }
      removed = current.keys - target.keys
      target.each_key do |path|
        absolute = worktree_path(path, replacing: removed)
        unless current.key?(path)
          if File.directory?(absolute) && !File.symlink?(absolute)
            Find.find(absolute) do |entry|
              next if File.directory?(entry) && !File.symlink?(entry)
              raise ArgumentError, "untracked checkout collision: #{path}" unless removed.include?(entry.delete_prefix(root + "/"))
            end
          elsif File.exist?(absolute) || File.symlink?(absolute)
            raise ArgumentError, "untracked checkout collision: #{path}"
          end
        end
        parent = File.dirname(absolute)
        until parent == root
          if (File.file?(parent) || File.symlink?(parent)) && !removed.include?(parent.delete_prefix(root + "/"))
            raise ArgumentError, "untracked checkout collision: #{parent}"
          end
          parent = File.dirname(parent)
        end
      end
      contents = target.to_h { |path, entry| [path, odb.read(entry.oid).last] }
      backups = current.to_h { |path, entry| [path, [worktree_content(path), entry.mode]] }
      backups.each do |path, (data, _)|
        raise ArgumentError, "worktree changed before checkout: #{path}" unless data && ObjectDatabase.hash("blob", data) == current[path].oid
      end
      index_path = File.join(git_dir, "index")
      head_path = File.join(git_dir, "HEAD")
      old_index = File.binread(index_path) if File.exist?(index_path)
      old_head = File.binread(head_path)
      locks = []
      changed = false
      begin
        [index_path, head_path].each { |path| locks << File.open(path + ".lock", File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644) }
        changed = true
        removed.sort_by { |path| -path.count("/") }.each { |path| File.unlink(worktree_path(path)) }
        prune_empty_directories(removed)
        target.each do |path, entry|
          absolute = worktree_path(path)
          Dir.rmdir(absolute) if File.directory?(absolute) && !File.symlink?(absolute)
          FileUtils.mkdir_p(File.dirname(absolute))
          File.unlink(absolute) if File.symlink?(absolute)
          if entry.mode == 0o120000
            File.unlink(absolute) if File.exist?(absolute)
            File.symlink(contents[path], absolute)
          else
            atomic_write(absolute, contents[path], entry.mode & 0o777)
          end
        end
        entries = target.map do |path, entry|
          stat = File.lstat(worktree_path(path))
          Index::Entry.new(path: path, oid: entry.oid, mode: entry.mode, size: stat.size,
            mtime: stat.mtime.to_i, mtime_nsec: stat.mtime.nsec, ctime: stat.ctime.to_i, ctime_nsec: stat.ctime.nsec,
            dev: stat.dev, ino: stat.ino, uid: stat.uid, gid: stat.gid, stage: 0)
        end
        locks[0].write(Index.encode(entries))
        locks[1].write("ref: refs/heads/#{name}\n")
        locks.each { |file| file.flush; file.fsync; file.close }
        File.rename(index_path + ".lock", index_path)
        File.rename(head_path + ".lock", head_path)
      rescue StandardError
        if changed
          (target.keys - current.keys).each do |path|
            absolute = worktree_path(path)
            File.unlink(absolute) if File.file?(absolute) || File.symlink?(absolute)
          end
          prune_empty_directories(target.keys - current.keys)
          backups.each do |path, (data, mode)|
            absolute = worktree_path(path)
            Dir.rmdir(absolute) if File.directory?(absolute) && !File.symlink?(absolute)
            FileUtils.mkdir_p(File.dirname(absolute))
            File.unlink(absolute) if File.symlink?(absolute)
            if mode == 0o120000
              File.unlink(absolute) if File.exist?(absolute)
              File.symlink(data, absolute)
            else
              atomic_write(absolute, data, mode & 0o777)
            end
          end
          old_index ? atomic_write(index_path, old_index, 0o644) : File.unlink(index_path) if old_index || File.exist?(index_path)
          atomic_write(head_path, old_head, 0o644)
        end
        raise
      ensure
        locks.each do |file|
          file.close unless file.closed?
          File.unlink(file.path) if File.exist?(file.path)
        end
      end
      name
    end

    private

    def current_signature(role, fallback:)
      prefix = case role
      when :author then "GIT_AUTHOR"
      when :committer then "GIT_COMMITTER"
      else raise ArgumentError, "role must be :author or :committer"
      end
      name = ENV["#{prefix}_NAME"] || identity_config_value("name")
      email = ENV["#{prefix}_EMAIL"] || identity_config_value("email")
      if fallback
        name ||= ENV["USER"] || "unknown"
        email ||= "unknown@localhost"
      end
      missing = {name: name, email: email}.filter_map { |key, value| key if value.nil? || value.empty? }
      raise ArgumentError, "Git #{role} identity is missing #{missing.join(' and ')}" unless missing.empty?

      now = Time.now
      value = Signature.new(name: name, email: email, time: now, offset: now.utc_offset)
      format_signature(value)
      value
    end

    def identity_config_value(key)
      files = IgnoreMatcher.send(:git_config_files, root || common_dir)
      files << File.join(common_dir, "config") unless root
      files.uniq.filter_map { |path| IgnoreMatcher.send(:config_value, path, "user", key) }.last
    end

    def prune_empty_directories(paths)
      paths.sort_by { |path| -path.count("/") }.each do |path|
        parent = File.dirname(File.join(root, path))
        until parent == root
          begin
            Dir.rmdir(parent)
          rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ENOENT, Errno::ENOTDIR
            break
          end
          parent = File.dirname(parent)
        end
      end
    end

    def atomic_write(path, data, mode)
      Tempfile.create([".thuban-", ".tmp"], File.dirname(path)) do |file|
        file.binmode
        file.chmod(mode)
        file.write(data)
        file.flush
        file.fsync
        file.close
        File.rename(file.path, path)
      end
    end

    def read_tree(oid, prefix = "", stack = [])
      raise CorruptObject, "tree nesting exceeds limit" if stack.length > 256 || stack.include?(oid)
      type, data = odb.read(oid)
      raise CorruptObject, "expected tree object" unless type == "tree"
      result = {}
      offset = 0
      while offset < data.bytesize
        ending = data.index("\0", offset)
        raise CorruptObject, "truncated tree entry" unless ending && ending + 21 <= data.bytesize
        mode, name = data[offset...ending].split(" ", 2)
        raise CorruptObject, "unsafe tree entry" unless mode&.match?(/\A[0-7]+\z/) && name && !["", ".", "..", ".git"].include?(name) && !name.include?("/")
        path = (prefix + name).force_encoding(Encoding::UTF_8)
        object = data[ending + 1, 20].unpack1("H*")
        mode = mode.to_i(8)
        if mode == 0o40000
          result.merge!(read_tree(object, path + "/", stack + [oid]))
        else
          result[path] = TreeEntry.new(path: path, oid: object, mode: mode)
        end
        offset = ending + 21
      end
      result
    end
  end
end
