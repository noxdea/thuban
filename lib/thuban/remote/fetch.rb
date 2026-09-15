# frozen_string_literal: true

module Thuban
  module Remote
    class Connection
      MAX_FETCH_RESPONSE_SIZE = Pack::MAX_PACK_SIZE
      MAX_NEGOTIATION_OIDS = 10_000

      def fetch(repository, wants:, haves: [], depth: nil, filter: nil)
        ensure_open
        raise TypeError, "expected Thuban::Repository" unless repository.is_a?(Repository)
        depth = Protocol.validate_depth(depth)
        filter = Protocol.validate_filter(filter)

        wants = oid_list(wants, "wants", empty: false)
        haves = oid_list(haves, "haves", empty: true)
        raise ArgumentError, "have object not found" unless haves.all? { |oid| repository.odb.exist?(oid) }

        refs unless @protocol_version
        shallow = read_shallow(repository)
        validate_fetch_capabilities(depth, filter, shallow)
        body = if @protocol_version == 2
          v2_fetch_request(wants, haves, shallow, depth, filter, progress: block_given?)
        else
          v0_fetch_request(wants, haves, shallow, depth, filter, progress: block_given?)
        end
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
            changes = extract_fetch_response(response, pack, allow_shallow: depth || !shallow.empty?) do |event|
              yield event if block_given?
            end
            pack.flush
            pack.rewind
            ensure_open
            received = Pack.read_stream(pack, repository.odb) do |current, total|
              ensure_open
              yield Progress.new(phase: :pack, current: current, total: total, bytes: pack.size) if block_given?
            end
            ensure_open
            raise TransportError, "fetch did not provide requested objects" unless wants.all? { |oid| repository.odb.exist?(oid) }
            update_shallow(repository, shallow, changes)

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

      def validate_fetch_capabilities(depth, filter, shallow)
        if @protocol_version == 2
          capability = @capabilities.find { |line| line.split("=", 2).first == "fetch" }
          raise TransportError, "server does not support fetch" unless capability

          features = capability.split("=", 2).last.to_s.split
        else
          features = @capabilities
        end
        raise TransportError, "server does not support shallow fetch" if (depth || !shallow.empty?) && !features.include?("shallow")
        raise TransportError, "server does not support partial fetch" if filter && !features.include?("filter")
      end

      def v2_fetch_request(wants, haves, shallow, depth, filter, progress:)
        lines = ["ofs-delta"]
        lines << "no-progress" unless progress
        lines.concat(shallow.map { |oid| "shallow #{oid}" })
        lines << "deepen #{depth}" if depth
        lines << "filter #{filter}" if filter
        lines.concat(wants.map { |oid| "want #{oid}" })
        lines.concat(haves.map { |oid| "have #{oid}" })
        lines << "done"
        Protocol.packet("command=fetch\n") + Protocol.delimiter +
          lines.map { |line| Protocol.packet("#{line}\n") }.join + Protocol.flush
      end

      def v0_fetch_request(wants, haves, shallow, depth, filter, progress:)
        requested = [(!progress && "no-progress"), "side-band-64k", "ofs-delta", (filter && "filter")].compact
        capabilities = requested.select { |capability| @capabilities.include?(capability) }
        lines = wants.each_with_index.map do |oid, index|
          suffix = index.zero? && !capabilities.empty? ? " #{capabilities.join(' ')}" : ""
          Protocol.packet("want #{oid}#{suffix}\n")
        end
        lines.concat(shallow.map { |oid| Protocol.packet("shallow #{oid}\n") })
        lines << Protocol.packet("deepen #{depth}\n") if depth
        lines << Protocol.packet("filter #{filter}\n") if filter
        lines.join + Protocol.flush + haves.map { |oid| Protocol.packet("have #{oid}\n") }.join +
          Protocol.packet("done\n")
      end

      def extract_fetch_response(input, output, allow_shallow: true)
        reader = Protocol::Reader.new(input, max_bytes: MAX_FETCH_RESPONSE_SIZE)
        packfile = @protocol_version.zero?
        received = false
        raw = false
        terminated = false
        section = nil
        section_index = -1
        shallow = []
        unshallow = []
        loop do
          ensure_open
          if packfile && raw_pack?(input)
            copy_raw_pack(input, output) { |event| yield event if block_given? }
            received = true
            raw = true
            break
          end
          packet = reader.read
          break if packet.nil?
          if packet == Protocol::RESPONSE_END
            terminated = true
            break
          end
          if packet == Protocol::FLUSH
            if received || @protocol_version == 2
              terminated = true
              break
            end
            next
          end
          if packet == Protocol::DELIMITER
            raise TransportError, "invalid fetch response delimiter" unless @protocol_version == 2 && section && section != "packfile"

            section = nil
            next
          end
          raise TransportError, "invalid fetch response" unless packet.is_a?(String)
          raise TransportError, safe_message(packet.delete_prefix("ERR ")) if packet.start_with?("ERR ")

          if @protocol_version == 2 && %w[acknowledgments shallow-info packfile].include?(packet.chomp)
            next_section = packet.chomp
            next_index = %w[acknowledgments shallow-info packfile].index(next_section)
            raise TransportError, "invalid fetch response section" unless section.nil? && next_index > section_index

            section = next_section
            section_index = next_index
            packfile = section == "packfile"
          elsif packet.start_with?("shallow ", "unshallow ")
            valid_section = @protocol_version.zero? || section == "shallow-info"
            raise TransportError, "unexpected shallow response" unless allow_shallow && valid_section

            state, oid = packet.chomp.split(" ", 2)
            oid = Protocol.validate_oid(oid)
            (state == "shallow" ? shallow : unshallow) << oid
          elsif acknowledgment?(packet)
            raise TransportError, "unexpected acknowledgment" unless @protocol_version.zero? || section == "acknowledgments"
          elsif packfile
            received = append_sideband(packet, output) { |event| yield event if block_given? } || received
          else
            raise TransportError, "unexpected fetch response section"
          end
        end
        raise TransportError, "fetch response did not contain a pack" unless received
        raise TransportError, "truncated fetch response" unless raw || terminated
        raise TransportError, "fetch response continued after its terminator" if !raw && reader.read
        raise TransportError, "contradictory shallow response" unless (shallow & unshallow).empty?

        {shallow: shallow.uniq, unshallow: unshallow.uniq}
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
          yield Progress.new(phase: :pack, current: nil, total: nil, bytes: output.pos) if block_given? && !data.empty?
          !data.empty?
        when 2
          yield Progress.new(phase: :remote, current: nil, total: nil, bytes: data.bytesize) if block_given?
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
          ensure_open
          output.write(chunk)
          yield Progress.new(phase: :pack, current: nil, total: nil, bytes: output.pos) if block_given?
        end
      end

      def read_shallow(repository)
        path = File.join(repository.common_dir, "shallow")
        return [] unless File.exist?(path) || File.symlink?(path)
        raise CorruptObject, "unsafe shallow file" unless File.file?(path) && !File.symlink?(path)

        lines = File.readlines(path, chomp: true, encoding: Encoding::BINARY)
        raise CorruptObject, "too many shallow boundaries" if lines.length > MAX_NEGOTIATION_OIDS
        lines.map { |line| Protocol.validate_oid(line) }.uniq
      rescue TransportError => error
        raise CorruptObject, "invalid shallow boundary", cause: error
      end

      def update_shallow(repository, original, changes)
        additions = changes.fetch(:shallow)
        removals = changes.fetch(:unshallow)
        return if additions.empty? && removals.empty?
        raise TransportError, "server unshallowed an unknown boundary" unless (removals - original - additions).empty?

        boundaries = ((original + additions).uniq - removals).sort
        boundaries.each do |oid|
          raise TransportError, "shallow boundary object is missing" unless repository.odb.exist?(oid)
          type, = repository.odb.read(oid)
          raise TransportError, "shallow boundary is not a commit" unless type == "commit"
        end
        path = File.join(repository.common_dir, "shallow")
        raise CorruptObject, "unsafe shallow file" if File.symlink?(path) || File.symlink?(path + ".lock")
        lock = File.open(path + ".lock", File::WRONLY | File::CREAT | File::EXCL | File::BINARY, 0o644)
        raise RefLockError, "shallow boundaries changed during fetch" unless read_shallow(repository) == original

        if boundaries.empty?
          lock.close
          File.unlink(path) if File.file?(path)
        else
          lock.write(boundaries.map { |oid| "#{oid}\n" }.join)
          lock.flush
          lock.fsync
          lock.close
          File.rename(lock.path, path)
        end
      rescue Errno::EEXIST
        raise RefLockError, "shallow file is locked"
      ensure
        lock&.close unless lock&.closed?
        File.unlink(lock.path) if lock && File.exist?(lock.path)
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
