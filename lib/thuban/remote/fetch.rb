# frozen_string_literal: true

module Thuban
  module Remote
    class Connection
      MAX_FETCH_RESPONSE_SIZE = Pack::MAX_PACK_SIZE
      MAX_NEGOTIATION_OIDS = 10_000

      def fetch(repository, wants:, haves: [], depth: nil, filter: nil)
        ensure_open
        raise TypeError, "expected Thuban::Repository" unless repository.is_a?(Repository)
        raise ArgumentError, "shallow fetch is not supported yet" unless depth.nil?
        raise ArgumentError, "partial fetch is not supported yet" unless filter.nil?

        wants = oid_list(wants, "wants", empty: false)
        haves = oid_list(haves, "haves", empty: true)
        raise ArgumentError, "have object not found" unless haves.all? { |oid| repository.odb.exist?(oid) }

        refs unless @protocol_version
        body = @protocol_version == 2 ? v2_fetch_request(wants, haves) : v0_fetch_request(wants, haves)
        Tempfile.create(["thuban-fetch-response-", ".bin"]) do |response|
          response.binmode
          request_to(response, :post, "/git-upload-pack", body: body,
            headers: {"Content-Type" => "application/x-git-upload-pack-request", "Accept" => "application/x-git-upload-pack-result",
                      "Git-Protocol" => "version=2"}, content_type: "application/x-git-upload-pack-result",
            limit: MAX_FETCH_RESPONSE_SIZE)
          response.flush
          response.rewind
          Tempfile.create(["thuban-fetch-pack-", ".pack"]) do |pack|
            pack.binmode
            extract_fetch_response(response, pack)
            pack.flush
            pack.rewind
            received = Pack.read_stream(pack, repository.odb)
            raise TransportError, "fetch did not provide requested objects" unless wants.all? { |oid| repository.odb.exist?(oid) }

            received
          end
        end
      end

      private

      def oid_list(value, name, empty:)
        raise TypeError, "#{name} must be enumerable" unless value.respond_to?(:each)

        result = []
        seen = {}
        count = 0
        value.each do |oid|
          count += 1
          raise ArgumentError, "too many #{name}" if count > MAX_NEGOTIATION_OIDS

          oid = Protocol.validate_oid(oid)
          result << oid unless seen[oid]
          seen[oid] = true
        end
        raise ArgumentError, "at least one want is required" if !empty && result.empty?

        result
      end

      def v2_fetch_request(wants, haves)
        supported = @capabilities.any? { |line| line.split("=", 2).first == "fetch" }
        raise TransportError, "server does not support fetch" unless supported

        lines = ["no-progress", "ofs-delta"]
        lines.concat(wants.map { |oid| "want #{oid}" })
        lines.concat(haves.map { |oid| "have #{oid}" })
        lines << "done"
        Protocol.packet("command=fetch\n") + Protocol.delimiter +
          lines.map { |line| Protocol.packet("#{line}\n") }.join + Protocol.flush
      end

      def v0_fetch_request(wants, haves)
        capabilities = %w[no-progress side-band-64k ofs-delta].select { |capability| @capabilities.include?(capability) }
        lines = wants.each_with_index.map do |oid, index|
          suffix = index.zero? && !capabilities.empty? ? " #{capabilities.join(' ')}" : ""
          Protocol.packet("want #{oid}#{suffix}\n")
        end
        lines.join + Protocol.flush + haves.map { |oid| Protocol.packet("have #{oid}\n") }.join +
          Protocol.packet("done\n")
      end

      def extract_fetch_response(input, output)
        reader = Protocol::Reader.new(input, max_bytes: MAX_FETCH_RESPONSE_SIZE)
        packfile = @protocol_version.zero?
        received = false
        loop do
          if packfile && raw_pack?(input)
            copy_raw_pack(input, output)
            return
          end
          packet = reader.read
          break if packet.nil? || [Protocol::FLUSH, Protocol::RESPONSE_END].include?(packet)
          next if packet == Protocol::DELIMITER
          raise TransportError, "invalid fetch response" unless packet.is_a?(String)
          raise TransportError, safe_message(packet.delete_prefix("ERR ")) if packet.start_with?("ERR ")

          if packet == "packfile\n"
            packfile = true
          elsif acknowledgment?(packet)
            next
          elsif packfile
            received = append_sideband(packet, output) || received
          else
            raise TransportError, "unexpected fetch response section"
          end
        end
        raise TransportError, "fetch response did not contain a pack" unless received
      end

      def acknowledgment?(packet)
        return true if ["acknowledgments\n", "NAK\n", "ready\n"].include?(packet)
        return false unless packet.start_with?("ACK ")

        oid, state = packet.chomp.delete_prefix("ACK ").split(" ", 2)
        Protocol.validate_oid(oid)
        raise TransportError, "invalid ACK status" if state && !%w[continue common ready].include?(state)

        true
      end

      def append_sideband(packet, output)
        band = packet.getbyte(0)
        data = packet.byteslice(1..).to_s
        case band
        when 1
          output.write(data)
          !data.empty?
        when 2
          false
        when 3
          raise TransportError, "remote error: #{safe_message(data)}"
        else
          raise TransportError, "invalid sideband channel"
        end
      end

      def raw_pack?(input)
        position = input.pos
        prefix = input.read(4)
        input.seek(position, IO::SEEK_SET)
        prefix == "PACK"
      end

      def copy_raw_pack(input, output)
        while (chunk = input.read(65_536))
          output.write(chunk)
        end
      end

      def request_to(output, method, suffix, query: nil, headers: {}, body: nil, content_type:, limit:)
        request_each(method, suffix, query: query, headers: headers, body: body, content_type: content_type, limit: limit) do |chunk|
          output.write(chunk)
        end
      end

      def safe_message(data) = data.force_encoding(Encoding::UTF_8).scrub.strip
    end
  end
end
