# frozen_string_literal: true

require "digest/sha1"

module Thuban
  class Index
    Entry = Struct.new(:path, :oid, :mode, :size, :mtime, :mtime_nsec, :ctime, :ctime_nsec,
      :dev, :ino, :uid, :gid, :stage, :flags, :extended_flags, keyword_init: true)
    include Enumerable
    attr_reader :entries, :version, :path

    def initialize(path)
      @path = path
      @entries = []
      @version = 2
      parse(File.binread(path)) if File.file?(path)
    end

    def each(&block) = entries.each(&block)
    def [](path) = entries.find { |entry| entry.path == path && entry.stage.zero? }

    def self.encode(entries)
      bytes = +"DIRC".b << [2, entries.length].pack("N2")
      entries.sort_by { |entry| [entry.path.b, entry.stage || 0] }.each do |entry|
        name = entry.path.b
        fields = %i[ctime ctime_nsec mtime mtime_nsec dev ino mode uid gid size].map { |field| entry.public_send(field).to_i & 0xffffffff }
        record = fields.pack("N10") + [entry.oid].pack("H*") + [[name.bytesize, 0xfff].min | ((entry.stage || 0) << 12)].pack("n") + name + "\0"
        record << "\0" * ((8 - record.bytesize % 8) % 8)
        bytes << record
      end
      bytes + Digest::SHA1.digest(bytes)
    end

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
        raise CorruptObject, "truncated index extension" if offset + 8 > bytes.bytesize - 20
        signature = bytes[offset, 4]
        size = bytes[offset + 4, 4].unpack1("N")
        # Lowercase extensions change index interpretation (e.g. split index).
        raise CorruptObject, "unsupported mandatory index extension #{signature}" if signature[0].match?(/[a-z]/)
        offset += 8 + size
        raise CorruptObject, "truncated index extension payload" if offset > bytes.bytesize - 20
      end
    end
  end
end
