# frozen_string_literal: true

require "digest/sha1"

module Thuban
  class Index
    Entry = Struct.new(:path, :oid, :mode, :size, :mtime, :mtime_nsec, :ctime, :ctime_nsec,
      :dev, :ino, :uid, :gid, :stage, :flags, :extended_flags, keyword_init: true)
    include Enumerable
    attr_reader :entries, :extensions, :version, :path

    def initialize(path)
      @path = path
      @entries = []
      @extensions = []
      @version = 2
      parse(File.binread(path)) if File.file?(path)
    end

    def each(&block) = entries.each(&block)
    def [](path) = entries.find { |entry| entry.path == path && entry.stage.zero? }

    def self.encode(entries, extensions: [], version: 2)
      raise ArgumentError, "unsupported Git index version #{version}" unless [2, 3, 4].include?(version)
      bytes = +"DIRC".b << [version, entries.length].pack("N2")
      previous = "".b
      entries.sort_by { |entry| [entry.path.b, entry.stage || 0] }.each do |entry|
        name = entry.path.b
        raise ArgumentError, "unsafe index path" if name.empty? || name.include?("\0") || name.start_with?("/") || name.split("/").any? { |part| ["", "..", ".git"].include?(part) }
        stage = entry.stage || 0
        raise ArgumentError, "invalid index stage" unless (0..3).cover?(stage)
        fields = %i[ctime ctime_nsec mtime mtime_nsec dev ino mode uid gid size].map { |field| entry.public_send(field).to_i & 0xffffffff }
        raise ArgumentError, "expected a full SHA-1 object id" unless /\A[0-9a-f]{40}\z/.match?(entry.oid.to_s)
        extended = entry.extended_flags.to_i
        has_extended = (entry.flags.to_i & 0x4000).positive? || !extended.zero?
        raise ArgumentError, "extended flags require index version 3 or 4" if has_extended && version == 2
        flags = (entry.flags.to_i & 0x8000) | [name.bytesize, 0xfff].min | (stage << 12)
        flags |= 0x4000 if has_extended
        record = fields.pack("N10") + [entry.oid].pack("H*") + [flags].pack("n")
        record << [extended].pack("n") if has_extended
        if version == 4
          common = 0
          limit = [previous.bytesize, name.bytesize].min
          common += 1 while common < limit && previous.getbyte(common) == name.getbyte(common)
          record << encode_varint(previous.bytesize - common) << name.byteslice(common..) << "\0"
        else
          record << name << "\0"
          record << "\0" * ((8 - record.bytesize % 8) % 8)
        end
        bytes << record
        previous = name
      end
      extensions.each do |extension|
        raise ArgumentError, "invalid index extension" unless extension.is_a?(String) && extension.bytesize >= 8
        size = extension.byteslice(4, 4).unpack1("N")
        raise ArgumentError, "invalid index extension" unless extension.bytesize == size + 8 && extension.byteslice(0, 1).match?(/[A-Z]/)
        bytes << extension.b
      end
      bytes << Digest::SHA1.digest(bytes)
    end

    def self.encode_varint(value)
      bytes = [value & 0x7f]
      while (value >>= 7).positive?
        value -= 1
        bytes << (0x80 | (value & 0x7f))
      end
      bytes.reverse.pack("C*")
    end
    private_class_method :encode_varint

    private

    def parse(bytes)
      raise CorruptObject, "invalid Git index" unless bytes.bytesize >= 32 && bytes.start_with?("DIRC")
      raise CorruptObject, "Git index checksum mismatch" unless Digest::SHA1.digest(bytes[0...-20]) == bytes[-20, 20]
      @version, count = bytes[4, 8].unpack("N2")
      raise CorruptObject, "unsupported Git index version #{version}" unless [2, 3, 4].include?(version)
      offset = 12
      previous = "".b
      count.times do
        start = offset
        raise CorruptObject, "truncated Git index entry" if offset + 62 > bytes.bytesize - 20
        fields = bytes[offset, 40].unpack("N10")
        oid = bytes[offset + 40, 20].unpack1("H*")
        flags = bytes[offset + 60, 2].unpack1("n")
        offset += 62
        extended = 0
        if (flags & 0x4000).positive?
          raise CorruptObject, "invalid index extended flags" if version == 2 || offset + 2 > bytes.bytesize - 20
          extended = bytes[offset, 2].unpack1("n")
          offset += 2
        end
        if version == 4
          byte = bytes.getbyte(offset)
          raise CorruptObject, "truncated index path prefix" unless byte
          offset += 1
          strip = byte & 0x7f
          while (byte & 0x80).positive?
            byte = bytes.getbyte(offset)
            raise CorruptObject, "invalid index path prefix" unless byte && strip <= previous.bytesize
            offset += 1
            strip = ((strip + 1) << 7) | (byte & 0x7f)
          end
          raise CorruptObject, "index path prefix outside previous path" if strip > previous.bytesize
        end
        ending = bytes.index("\0", offset)
        raise CorruptObject, "unterminated index path" unless ending && ending < bytes.bytesize - 20
        name = bytes[offset...ending]
        name = previous.byteslice(0, previous.bytesize - strip) + name if version == 4
        raise CorruptObject, "unsafe index path" if name.empty? || name.start_with?("/") || name.split("/").any? { |part| part == ".." || part == ".git" }
        previous = name
        offset = ending + 1
        offset += (8 - (offset - start) % 8) % 8 unless version == 4
        values = %i[ctime ctime_nsec mtime mtime_nsec dev ino mode uid gid size].zip(fields).to_h
        entries << Entry.new(**values, path: name.force_encoding(Encoding::UTF_8), oid: oid,
          flags: flags, extended_flags: extended, stage: (flags >> 12) & 3)
      end
      while offset < bytes.bytesize - 20
        start = offset
        raise CorruptObject, "truncated index extension" if offset + 8 > bytes.bytesize - 20
        signature = bytes[offset, 4]
        size = bytes[offset + 4, 4].unpack1("N")
        # Lowercase extensions change index interpretation (e.g. split index).
        raise CorruptObject, "unsupported mandatory index extension #{signature}" if signature[0].match?(/[a-z]/)
        offset += 8 + size
        raise CorruptObject, "truncated index extension payload" if offset > bytes.bytesize - 20
        extensions << bytes.byteslice(start, 8 + size).dup.freeze
      end
    end
  end
end
