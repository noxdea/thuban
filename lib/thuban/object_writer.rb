# frozen_string_literal: true

module Thuban
  class ObjectDatabase
    TYPES = %w[blob tree commit tag].freeze

    def exist?(oid)
      validate_oid(oid)
      loose = File.join(directory, oid[0, 2], oid[2..])
      raise ArgumentError, "unsafe loose object path" if File.symlink?(loose)
      if File.file?(loose)
        validate_object_directory(File.dirname(loose))
        return true
      end
      return true if packs.any? { |pack| pack.include?(oid) }

      @packs = nil
      packs.any? { |pack| pack.include?(oid) }
    end

    def write(type, data) = write_loose(type, data)

    def write_loose(type, data)
      raise ArgumentError, "invalid Git object type" unless TYPES.include?(type)
      raise TypeError, "object data must be a String" unless data.is_a?(String)

      raw = "#{type} #{data.bytesize}\0".b + data.b
      oid = Digest::SHA1.hexdigest(raw)
      return oid if exist?(oid)

      target = File.join(directory, oid[0, 2], oid[2..])
      object_directory = File.dirname(target)
      raise ArgumentError, "unsafe loose object directory" if File.symlink?(object_directory)
      FileUtils.mkdir_p(object_directory)
      validate_object_directory(object_directory)
      Tempfile.create([".thuban-object-", ".tmp"], File.dirname(target)) do |file|
        file.binmode
        file.chmod(0o444)
        file.write(Zlib::Deflate.deflate(raw))
        file.flush
        file.fsync
        file.close
        File.rename(file.path, target) unless File.exist?(target)
      end
      oid
    end

    private

    def validate_oid(oid)
      raise ArgumentError, "expected a full SHA-1 object id" unless /\A[0-9a-f]{40}\z/.match?(oid.to_s)
    end

    def validate_object_directory(path)
      root = File.realpath(directory)
      raise ArgumentError, "unsafe loose object directory" if File.symlink?(path) || !File.realpath(path).start_with?(root + File::SEPARATOR)
    end
  end

  class Repository
    TREE_MODES = [0o040000, 0o100644, 0o100755, 0o120000, 0o160000].freeze

    def write_blob(content) = odb.write("blob", content)

    def write_tree(entries)
      seen = {}
      records = entries.map do |entry|
        name = entry.path
        raise ArgumentError, "unsafe tree entry" unless name.is_a?(String) && !name.empty? && !name.include?("/") && !name.include?("\0") && ![".", ".."].include?(name) && !name.casecmp?(".git")
        raise ArgumentError, "duplicate tree entry: #{name}" if seen[name.b]
        raise ArgumentError, "invalid tree mode" unless TREE_MODES.include?(entry.mode)
        raise ArgumentError, "expected a full SHA-1 object id" unless /\A[0-9a-f]{40}\z/.match?(entry.oid.to_s)

        expected = entry.mode == 0o040000 ? "tree" : entry.mode == 0o160000 ? "commit" : "blob"
        type, = odb.read(entry.oid)
        raise ArgumentError, "tree entry mode does not match object" unless type == expected

        seen[name.b] = true
        [name.b + (entry.mode == 0o040000 ? "/" : ""), "#{entry.mode.to_s(8)} #{name}\0".b + [entry.oid].pack("H*")]
      end
      odb.write("tree", records.sort_by(&:first).map(&:last).join)
    end

    def write_commit(tree:, parents: [], author:, committer: nil, message:)
      validate_object_type(tree, "tree")
      parents.each { |oid| validate_object_type(oid, "commit") }
      raise ArgumentError, "duplicate commit parent" unless parents.uniq.length == parents.length
      raise TypeError, "message must be a String" unless message.is_a?(String)
      raise ArgumentError, "commit message contains NUL" if message.include?("\0")

      author_line = format_signature(author)
      committer_line = format_signature(committer || author)
      body = +"tree #{tree}\n"
      parents.each { |oid| body << "parent #{oid}\n" }
      body << "author #{author_line}\ncommitter #{committer_line}\n\n#{message}"
      body << "\n" unless body.end_with?("\n")
      odb.write("commit", body)
    end

    private

    def validate_object_type(oid, expected)
      raise ArgumentError, "expected a full SHA-1 object id" unless /\A[0-9a-f]{40}\z/.match?(oid.to_s)
      type, = odb.read(oid)
      raise ArgumentError, "expected #{expected} object" unless type == expected
    end

    def format_signature(signature)
      raise TypeError, "expected Thuban::Signature" unless signature.is_a?(Signature)
      raise TypeError, "signature name and email must be Strings" unless signature.name.is_a?(String) && signature.email.is_a?(String)
      name, email = signature.name, signature.email
      raise ArgumentError, "invalid signature name" if name.empty? || name.match?(/[\r\n<>]/)
      raise ArgumentError, "invalid signature email" if email.empty? || email.match?(/[\r\n<>]/)

      time = signature.time || Time.now
      timestamp = begin
        time.respond_to?(:to_time) ? time.to_time.to_i : Integer(time)
      rescue ArgumentError, TypeError
        raise ArgumentError, "invalid signature time"
      end
      offset = signature.offset
      offset = time.utc_offset if offset.nil? && time.respond_to?(:utc_offset)
      offset ||= 0
      zone = if offset.is_a?(Integer)
        raise ArgumentError, "invalid signature offset" if offset.abs > 86_340
        sign = offset.negative? ? "-" : "+"
        minutes = offset.abs / 60
        format("%s%02d%02d", sign, minutes / 60, minutes % 60)
      else
        offset.to_s
      end
      raise ArgumentError, "invalid signature offset" unless /\A[+-](?:[01]\d|2[0-3])[0-5]\d\z/.match?(zone)

      "#{name} <#{email}> #{timestamp} #{zone}"
    end
  end
end
