# frozen_string_literal: true

module Thuban
  class RefStore
    ZERO_OID = "0" * 40

    def initialize(repository)
      @repository = repository
    end

    def update(name, new_oid, old_oid: :any, message: nil)
      validate_ref(name)
      validate_oid(new_oid)
      raise ArgumentError, "Git object not found: #{new_oid}" unless repository.odb.exist?(new_oid)

      target = dereference(name)
      identity = repository.send(:format_signature, reflog_signature)
      action = message.to_s.gsub(/[\x00-\x1f]/, " ")
      [target, name].uniq.each { |reference| prepare_storage_path(log_path(reference)) }
      paths = [ref_path(target)]
      paths << ref_path(name) if target != name
      with_locks(paths) do |locks|
        raise RefLockError, "symbolic reference changed: #{name}" unless dereference(name) == target
        current = repository.resolve(target)
        verify_old_oid(name, current, old_oid)
        file = locks.fetch(ref_path(target))
        file.write("#{new_oid}\n")
        sync(file)
        File.rename(file.path, ref_path(target))
        append_reflog(target, current, new_oid, identity, action)
        append_reflog(name, current, new_oid, identity, action) if target != name
      end
      new_oid
    end

    def delete(name, old_oid: :any)
      validate_ref(name, head: false)
      paths = [ref_path(name)]
      packed_path = File.join(repository.common_dir, "packed-refs")
      paths << packed_path if File.file?(packed_path)
      prepare_storage_path(log_path(name))
      deleted = nil
      with_locks(paths) do |locks|
        current = repository.resolve(name)
        verify_old_oid(name, current, old_oid)
        raise RefLockError, "reference does not exist: #{name}" unless current
        deleted = current
        rewrite_packed_refs(locks[packed_path], packed_path, name) if locks[packed_path]
        File.unlink(ref_path(name)) if File.file?(ref_path(name)) || File.symlink?(ref_path(name))
        File.unlink(log_path(name)) if File.file?(log_path(name))
      end
      deleted
    end

    def symbolic(name, target)
      validate_ref(name)
      validate_ref(target, head: false)
      path = ref_path(name)
      with_locks([path]) do |locks|
        file = locks.fetch(path)
        file.write("ref: #{target}\n")
        sync(file)
        File.rename(file.path, path)
      end
      target
    end

    def reflog(name)
      name = "refs/heads/#{name}" unless name == "HEAD" || name.start_with?("refs/")
      validate_ref(name)
      path = log_path(name)
      return [] unless File.file?(path)
      validate_storage_path(path)
      File.readlines(path, chomp: true, encoding: Encoding::BINARY)
    end

    private

    attr_reader :repository

    def validate_ref(name, head: true)
      return if head && name == "HEAD"
      invalid = !name.is_a?(String) || !name.start_with?("refs/") || name.end_with?("/", ".") ||
        name.include?("..") || name.include?("@{") || name.match?(/[\x00-\x20~^:?*\[\\]/) ||
        name.split("/").any? { |part| part.empty? || part.start_with?(".") || part.downcase.end_with?(".lock") }
      raise ArgumentError, "invalid Git reference" if invalid
    end

    def validate_oid(oid)
      raise ArgumentError, "expected a full SHA-1 object id" unless /\A[0-9a-f]{40}\z/.match?(oid.to_s)
    end

    def dereference(name)
      seen = []
      loop do
        raise CorruptObject, "cyclic symbolic reference" if seen.include?(name) || seen.length > 32
        seen << name
        path = ref_path(name)
        raise ArgumentError, "unsafe Git metadata path" if File.symlink?(path)
        return name unless File.file?(path)
        value = File.read(path).strip
        return name unless value.start_with?("ref: ")
        name = value.delete_prefix("ref: ")
        validate_ref(name, head: false)
      end
    end

    def ref_path(name) = File.join(name == "HEAD" ? repository.git_dir : repository.common_dir, name)
    def log_path(name) = File.join(name == "HEAD" ? repository.git_dir : repository.common_dir, "logs", name)

    def with_locks(paths)
      locks = {}
      paths.uniq.sort.each do |path|
        prepare_storage_path(path)
        file = File.open(path + ".lock", File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
        locks[path] = file
      end
      yield locks
    rescue Errno::EEXIST => error
      raise RefLockError, "reference is locked: #{error.message}"
    ensure
      locks&.each_value do |file|
        file.close unless file.closed?
        File.unlink(file.path) if File.exist?(file.path)
      end
    end

    def verify_old_oid(name, current, expected)
      return if expected == :any || current == expected
      raise RefLockError, "reference changed: #{name}"
    end

    def sync(file)
      file.flush
      file.fsync
      file.close
    end

    def append_reflog(name, old_oid, new_oid, identity, action)
      path = log_path(name)
      prepare_storage_path(path)
      File.open(path, File::WRONLY | File::CREAT | File::APPEND | File::BINARY, 0o644) do |file|
        file.write("#{old_oid || ZERO_OID} #{new_oid} #{identity}\t#{action}\n")
        file.flush
        file.fsync
      end
    end

    def reflog_signature
      Signature.new(name: ENV["GIT_COMMITTER_NAME"] || config_value("name") || ENV["USER"] || "unknown",
        email: ENV["GIT_COMMITTER_EMAIL"] || config_value("email") || "unknown@localhost", time: Time.now)
    end

    def validate_storage_path(path)
      raise ArgumentError, "unsafe Git metadata path" if File.symlink?(path)
      parent = File.realpath(File.dirname(path))
      roots = [repository.git_dir, repository.common_dir].map { |root| File.realpath(root) }.uniq
      return if roots.any? { |root| parent == root || parent.start_with?(root + File::SEPARATOR) }

      raise ArgumentError, "unsafe Git metadata path"
    end

    def prepare_storage_path(path)
      FileUtils.mkdir_p(File.dirname(path))
      validate_storage_path(path)
    end

    def config_value(key)
      section = nil
      File.foreach(File.join(repository.common_dir, "config"), encoding: "UTF-8") do |line|
        stripped = line.strip
        if (section_match = stripped.match(/\A\[\s*([^\s\]"]+)/))
          section = section_match[1].downcase
        elsif section == "user" && (value_match = stripped.match(/\A#{key}\s*=\s*(.*)\z/i))
          return value_match[1].strip.delete_prefix("\"").delete_suffix("\"")
        end
      end
      nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def rewrite_packed_refs(file, path, name)
      lines = File.readlines(path, mode: "rb")
      kept = []
      removing = false
      lines.each do |line|
        if line.start_with?("^")
          kept << line unless removing
          removing = false
        else
          removing = line.split(" ", 2)[1]&.strip == name
          kept << line unless removing
        end
      end
      return unless kept.length != lines.length

      file.write(kept.join)
      sync(file)
      File.rename(file.path, path)
    end
  end

  class Repository
    def update_ref(name, new_oid, old_oid: :any, message: nil) = RefStore.new(self).update(name, new_oid, old_oid: old_oid, message: message)
    def delete_ref(name, old_oid: :any) = RefStore.new(self).delete(name, old_oid: old_oid)

    def create_branch(name, oid)
      raise ArgumentError, "invalid branch name" if name.to_s.start_with?("-")
      validate_object_type(oid, "commit")
      update_ref("refs/heads/#{name}", oid, old_oid: nil, message: "branch: Created")
      name
    end

    def delete_branch(name)
      raise ArgumentError, "cannot delete the current branch" if branch == name
      delete_ref("refs/heads/#{name}")
      name
    end

    def symbolic_ref(name, target) = RefStore.new(self).symbolic(name, target)
    def reflog(name) = RefStore.new(self).reflog(name)
  end
end
