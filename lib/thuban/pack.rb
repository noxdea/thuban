# frozen_string_literal: true

require "zlib"
require "digest/sha1"
require_relative "corrupt_object"

module Thuban
  class Pack
    TYPES = {1 => "commit", 2 => "tree", 3 => "blob", 4 => "tag"}.freeze
    MAX_OBJECT_SIZE = 512 * 1024 * 1024
    attr_reader :path, :offsets

    def initialize(index_path)
      @path = index_path.sub(/\.idx\z/, ".pack")
      @offsets = read_index(File.binread(index_path))
      File.open(path, "rb") do |file|
        header = file.read(12)
        raise CorruptObject, "invalid pack header" unless header&.bytesize == 12 && header[0, 4] == "PACK" && [2, 3].include?(header[4, 4].unpack1("N"))
        raise CorruptObject, "pack/index object count mismatch" unless header[8, 4].unpack1("N") == offsets.length
        file.seek(-20, IO::SEEK_END)
        raise CorruptObject, "pack/index checksum mismatch" unless file.read(20) == @pack_checksum
      end
      @cache = {}
    end

    def include?(oid) = offsets.key?(oid)

    def read(oid, &resolve)
      offset = offsets[oid]
      raise KeyError, "object not in pack: #{oid}" unless offset
      read_at(offset, [], &resolve)
    end

    def self.apply_delta(base, delta)
      cursor = 0
      read_size = lambda do
        size = shift = 0
        loop do
          byte = delta.getbyte(cursor)
          raise CorruptObject, "truncated delta header" unless byte && shift <= 63
          cursor += 1
          size |= (byte & 0x7f) << shift
          break if (byte & 0x80).zero?
          shift += 7
        end
        size
      end
      source_size = read_size.call
      target_size = read_size.call
      raise CorruptObject, "delta base size mismatch" unless base.bytesize == source_size
      raise CorruptObject, "delta too large" if target_size > MAX_OBJECT_SIZE
      output = +"".b
      while cursor < delta.bytesize
        opcode = delta.getbyte(cursor)
        cursor += 1
        if (opcode & 0x80).positive?
          offset = length = 0
          7.times do |bit|
            next if (opcode & (1 << bit)).zero?
            byte = delta.getbyte(cursor)
            raise CorruptObject, "truncated delta copy" unless byte
            cursor += 1
            bit < 4 ? offset |= byte << (bit * 8) : length |= byte << ((bit - 4) * 8)
          end
          length = 0x10000 if length.zero?
          raise CorruptObject, "delta copy outside base" if offset + length > base.bytesize
          output << base.byteslice(offset, length)
        elsif opcode.positive?
          raise CorruptObject, "truncated delta insert" if cursor + opcode > delta.bytesize
          output << delta.byteslice(cursor, opcode)
          cursor += opcode
        else
          raise CorruptObject, "invalid delta opcode"
        end
        raise CorruptObject, "delta exceeds target size" if output.bytesize > target_size
      end
      raise CorruptObject, "delta target size mismatch" unless output.bytesize == target_size
      output
    end

    private

    def read_index(bytes)
      raise CorruptObject, "truncated pack index" if bytes.bytesize < 1064
      raise CorruptObject, "pack index checksum mismatch" unless Digest::SHA1.digest(bytes[0...-20]) == bytes[-20, 20]
      @pack_checksum = bytes[-40, 20]
      version = bytes.start_with?("\xfftOc".b) ? bytes[4, 4].unpack1("N") : 1
      raise CorruptObject, "unsupported pack index version #{version}" unless [1, 2].include?(version)
      start = version == 1 ? 0 : 8
      fanout = bytes[start, 1024].unpack("N*")
      raise CorruptObject, "invalid pack index fanout" unless fanout.each_cons(2).all? { |a, b| a <= b }
      count = fanout.last
      cursor = start + 1024
      minimum = cursor + count * (version == 1 ? 24 : 28) + 40
      raise CorruptObject, "truncated pack index entries" if minimum > bytes.bytesize
      if version == 1
        return count.times.to_h do |index|
          position = cursor + index * 24
          [bytes[position + 4, 20].unpack1("H*"), bytes[position, 4].unpack1("N")]
        end
      end
      names = cursor
      positions = cursor + count * 24
      large_positions = positions + count * 4
      count.times.to_h do |index|
        offset = bytes[positions + index * 4, 4].unpack1("N")
        if offset >= 0x80000000
          location = large_positions + (offset & 0x7fffffff) * 8
          raise CorruptObject, "truncated 64-bit pack offset" if location + 8 > bytes.bytesize - 40
          offset = bytes[location, 8].unpack1("Q>")
        end
        [bytes[names + index * 20, 20].unpack1("H*"), offset]
      end
    end

    def read_at(offset, stack, &resolve)
      return @cache[offset] if @cache.key?(offset)
      raise CorruptObject, "cyclic or excessive pack delta chain" if stack.include?(offset) || stack.length > 128
      stack = stack + [offset]
      type = data = base_offset = base_oid = nil
      File.open(path, "rb") do |file|
        raise CorruptObject, "object offset outside pack" unless offset >= 12 && offset < file.size - 20
        file.seek(offset)
        byte = file.getbyte
        type = (byte >> 4) & 7
        size = byte & 15
        shift = 4
        while (byte & 0x80).positive?
          byte = file.getbyte
          raise CorruptObject, "truncated pack object size" unless byte && shift <= 63
          size |= (byte & 0x7f) << shift
          shift += 7
        end
        raise CorruptObject, "pack object too large" if size > MAX_OBJECT_SIZE
        if type == 6
          byte = file.getbyte
          raise CorruptObject, "truncated delta offset" unless byte
          distance = byte & 0x7f
          count = 0
          while (byte & 0x80).positive?
            byte = file.getbyte
            count += 1
            raise CorruptObject, "invalid delta offset" unless byte && count <= 9
            distance = ((distance + 1) << 7) | (byte & 0x7f)
          end
          base_offset = offset - distance
          raise CorruptObject, "invalid delta base offset" unless base_offset >= 12 && base_offset < offset
        elsif type == 7
          raw = file.read(20)
          raise CorruptObject, "truncated delta reference" unless raw&.bytesize == 20
          base_oid = raw.unpack1("H*")
        elsif !TYPES.key?(type)
          raise CorruptObject, "invalid packed object type #{type}"
        end
        inflater = Zlib::Inflate.new
        begin
          data = +"".b
          until inflater.finished?
            chunk = file.read(16_384)
            raise CorruptObject, "truncated compressed object" unless chunk
            inflater.inflate(chunk) do |part|
              data << part
              raise CorruptObject, "packed object exceeds declared size" if data.bytesize > size
            end
          end
        rescue Zlib::Error => error
          raise CorruptObject, error.message
        ensure
          inflater.close
        end
        raise CorruptObject, "packed object size mismatch" unless data.bytesize == size
      end
      object = if base_offset || base_oid
        base_type, base = base_offset ? read_at(base_offset, stack, &resolve) : resolve.call(base_oid)
        [base_type, self.class.apply_delta(base, data)]
      else
        [TYPES.fetch(type), data]
      end
      # ponytail: bound object cache by count; byte budgeting if large blobs dominate.
      @cache.shift if @cache.length >= 128
      @cache[offset] = object.map(&:freeze).freeze
    end
  end
end
