# frozen_string_literal: true

module Thuban
  module Remote
    module Protocol
      MAX_PACKET_SIZE = 65_520
      FLUSH = :flush
      DELIMITER = :delimiter
      RESPONSE_END = :response_end

      def self.packet(data)
        raise TypeError, "packet data must be a String" unless data.is_a?(String)
        raise TransportError, "packet exceeds Git protocol limit" if data.bytesize > MAX_PACKET_SIZE - 4

        format("%04x", data.bytesize + 4) + data.b
      end

      def self.flush = "0000".b
      def self.delimiter = "0001".b

      def self.validate_oid(oid)
        raise TransportError, "server advertised a non-SHA-1 object ID" unless /\A[0-9a-fA-F]{40}\z/.match?(oid.to_s)

        oid.downcase
      end

      def self.validate_ref(name)
        valid = name == "HEAD" || (name.is_a?(String) && name.start_with?("refs/") &&
          !name.end_with?("/", ".") && !name.include?("..") && !name.include?("@{") &&
          !name.match?(/[\x00-\x20\x7f~^:?*\[\\]/) &&
          name.split("/").none? { |part| part.empty? || part.start_with?(".") || part.downcase.end_with?(".lock") })
        raise TransportError, "server advertised an invalid reference" unless valid

        name
      end

      class Reader
        def initialize(io, max_bytes:)
          @io = io
          @max_bytes = max_bytes
          @bytes = 0
        end

        def read
          header = read_exact(4, eof: true)
          return if header.nil?
          raise TransportError, "invalid packet length" unless /\A[0-9a-fA-F]{4}\z/.match?(header)

          length = header.to_i(16)
          return FLUSH if length.zero?
          return DELIMITER if length == 1
          return RESPONSE_END if length == 2
          raise TransportError, "invalid packet length" unless (4..MAX_PACKET_SIZE).cover?(length)

          @bytes += length
          raise TransportError, "protocol response exceeds size limit" if @bytes > @max_bytes

          read_exact(length - 4)
        end

        private

        def read_exact(length, eof: false)
          result = +"".b
          while result.bytesize < length
            chunk = @io.read(length - result.bytesize)
            return if eof && result.empty? && chunk.nil?
            raise TransportError, "truncated packet" if chunk.nil? || chunk.empty?

            result << chunk
          end
          result
        end
      end
    end
  end
end
