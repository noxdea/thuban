# frozen_string_literal: true

module Thuban
  class Pack
    TYPE_CODES = TYPES.invert.freeze

    def self.write(io, objects)
      raise TypeError, "pack output must respond to write" unless io.respond_to?(:write)

      raise TypeError, "objects must be enumerable" unless objects.respond_to?(:each)

      entries = objects.to_a
      raise ArgumentError, "too many pack objects" if entries.length > 0xffffffff
      entries.each do |entry|
        valid = entry.is_a?(Array) && entry.length == 2 && TYPE_CODES.key?(entry[0]) && entry[1].is_a?(String)
        raise ArgumentError, "objects must be [type, data] pairs" unless valid
        raise ArgumentError, "pack object too large" if entry[1].bytesize > MAX_OBJECT_SIZE
      end

      digest = Digest::SHA1.new
      sink = lambda do |bytes|
        write_all(io, bytes)
        digest.update(bytes)
      end
      sink.call("PACK".b + [2, entries.length].pack("N2"))
      entries.each_with_index do |(type, data), index|
        sink.call(encode_object_header(TYPE_CODES.fetch(type), data.bytesize))
        deflater = Zlib::Deflate.new
        begin
          offset = 0
          while offset < data.bytesize
            chunk = data.byteslice(offset, 65_536)
            compressed = deflater.deflate(chunk)
            sink.call(compressed) unless compressed.empty?
            offset += chunk.bytesize
          end
          compressed = deflater.finish
          sink.call(compressed) unless compressed.empty?
        ensure
          deflater.close
        end
        yield index + 1, entries.length if block_given?
      end
      checksum = digest.digest
      write_all(io, checksum)
      checksum.unpack1("H*")
    end

    def self.encode_object_header(type, size)
      first = (type << 4) | (size & 0x0f)
      size >>= 4
      bytes = []
      while size.positive?
        bytes << (first | 0x80)
        first = size & 0x7f
        size >>= 7
      end
      bytes << first
      bytes.pack("C*")
    end
    private_class_method :encode_object_header

    def self.write_all(io, bytes)
      offset = 0
      while offset < bytes.bytesize
        written = io.write(bytes.byteslice(offset..))
        raise IOError, "pack output stopped accepting bytes" unless written.is_a?(Integer) && written.positive?

        offset += written
      end
    end
    private_class_method :write_all
  end
end
