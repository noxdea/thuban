# frozen_string_literal: true

module Thuban
  class Pack
    MAX_PACK_SIZE = 1024 * 1024 * 1024
    MAX_PACK_OBJECTS = 1_000_000
    MAX_DEFERRED_DELTA_BYTES = 128 * 1024 * 1024
    MAX_EXPANDED_PACK_SIZE = 4 * 1024 * 1024 * 1024

    def self.read_stream(io, odb)
      raise TypeError, "pack input must respond to read" unless io.respond_to?(:read)
      raise TypeError, "expected Thuban::ObjectDatabase" unless odb.is_a?(ObjectDatabase)

      Tempfile.create(["thuban-pack-", ".pack"]) do |file|
        file.binmode
        copy_stream(io, file, MAX_PACK_SIZE)
        file.flush
        unpack_file(file, odb) { |current, total| yield current, total if block_given? }
      end
    end

    def self.copy_stream(input, output, limit)
      total = 0
      loop do
        chunk = input.read(65_536)
        break if chunk.nil?
        raise CorruptObject, "pack input stopped before EOF" unless chunk.is_a?(String) && !chunk.empty?

        total += chunk.bytesize
        raise CorruptObject, "pack exceeds size limit" if total > limit

        output.write(chunk)
      end
      total
    end
    private_class_method :copy_stream

    def self.unpack_file(file, odb)
      size = file.size
      raise CorruptObject, "truncated pack" if size < 32
      pack_end = size - 20
      verify_pack_checksum(file, pack_end)
      file.rewind
      header = file.read(12)
      valid = header.start_with?("PACK") && [2, 3].include?(header[4, 4].unpack1("N"))
      raise CorruptObject, "invalid pack header" unless valid

      count = header[8, 4].unpack1("N")
      raise CorruptObject, "pack object count exceeds limit" if count > MAX_PACK_OBJECTS
      resolved = {}
      deferred = []
      deferred_bytes = 0
      expanded_bytes = 0
      oids = []
      count.times do
        record = read_record(file, pack_end)
        object = resolve_record(record, resolved, odb, MAX_EXPANDED_PACK_SIZE - expanded_bytes)
        if object
          oid, object_size = object
          resolved[record[:offset]] = oid
          oids << oid
          expanded_bytes += object_size
          yield oids.length, count if block_given?
        else
          deferred << record
          deferred_bytes += record[:data].bytesize
          raise CorruptObject, "deferred deltas exceed memory limit" if deferred_bytes > MAX_DEFERRED_DELTA_BYTES
        end
      end
      raise CorruptObject, "pack object count mismatch" unless file.pos == pack_end

      waiting_by_offset = Hash.new { |hash, key| hash[key] = [] }
      waiting_by_oid = Hash.new { |hash, key| hash[key] = [] }
      deferred.each do |record|
        target = record[:base_oid] ? waiting_by_oid[record[:base_oid]] : waiting_by_offset[record[:base_offset]]
        target << record
      end
      deferred.clear
      queue = []
      resolved.each do |offset, oid|
        queue.concat(waiting_by_offset.delete(offset) || [])
        queue.concat(waiting_by_oid.delete(oid) || [])
      end
      waiting_by_oid.keys.each do |oid|
        queue.concat(waiting_by_oid.delete(oid)) if odb.exist?(oid)
      end
      cursor = 0
      while cursor < queue.length
        record = queue[cursor]
        cursor += 1
        object = resolve_record(record, resolved, odb, MAX_EXPANDED_PACK_SIZE - expanded_bytes)
        raise CorruptObject, "unresolved delta base" unless object

        oid, object_size = object
        resolved[record[:offset]] = oid
        oids << oid
        expanded_bytes += object_size
        yield oids.length, count if block_given?
        queue.concat(waiting_by_offset.delete(record[:offset]) || [])
        queue.concat(waiting_by_oid.delete(oid) || [])
      end
      raise CorruptObject, "unresolved delta base" unless waiting_by_offset.empty? && waiting_by_oid.empty?

      oids
    end
    private_class_method :unpack_file

    def self.verify_pack_checksum(file, pack_end)
      digest = Digest::SHA1.new
      file.rewind
      remaining = pack_end
      while remaining.positive?
        chunk = file.read([remaining, 65_536].min)
        raise CorruptObject, "truncated pack" unless chunk&.bytesize&.positive?

        digest.update(chunk)
        remaining -= chunk.bytesize
      end
      expected = file.read(20)
      raise CorruptObject, "pack checksum mismatch" unless expected&.bytesize == 20 && digest.digest == expected
    end
    private_class_method :verify_pack_checksum

    def self.read_record(file, pack_end)
      offset = file.pos
      byte = file.getbyte
      raise CorruptObject, "truncated pack object" unless byte

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

      record = {offset: offset, type: TYPES[type]}
      if type == 6
        record[:base_offset] = offset - read_delta_distance(file)
        raise CorruptObject, "invalid delta base offset" unless record[:base_offset] >= 12 && record[:base_offset] < offset
      elsif type == 7
        base = file.read(20)
        raise CorruptObject, "truncated delta reference" unless base&.bytesize == 20

        record[:base_oid] = base.unpack1("H*")
      elsif !record[:type]
        raise CorruptObject, "invalid packed object type #{type}"
      end
      record[:data] = inflate_record(file, size, pack_end)
      record
    end
    private_class_method :read_record

    def self.read_delta_distance(file)
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
      distance
    end
    private_class_method :read_delta_distance

    def self.inflate_record(file, size, pack_end)
      inflater = Zlib::Inflate.new
      data = +"".b
      start = file.pos
      until inflater.finished?
        remaining = pack_end - file.pos
        raise CorruptObject, "truncated compressed object" unless remaining.positive?

        chunk = file.read([remaining, 16_384].min)
        inflater.inflate(chunk) do |part|
          data << part
          raise CorruptObject, "packed object exceeds declared size" if data.bytesize > size
        end
      end
      file.seek(start + inflater.total_in, IO::SEEK_SET)
      raise CorruptObject, "packed object size mismatch" unless data.bytesize == size

      data
    rescue Zlib::Error => error
      raise CorruptObject, error.message
    ensure
      inflater&.close
    end
    private_class_method :inflate_record

    def self.resolve_record(record, resolved, odb, remaining)
      type = record[:type]
      data = record[:data]
      unless type
        base_oid = record[:base_oid] || resolved[record[:base_offset]]
        return unless base_oid && odb.exist?(base_oid)

        type, base = odb.read(base_oid)
        data = apply_delta(base, data)
      end
      raise CorruptObject, "expanded pack exceeds size limit" if data.bytesize > remaining

      [odb.write(type, data), data.bytesize]
    end
    private_class_method :resolve_record
  end
end
