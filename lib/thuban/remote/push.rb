# frozen_string_literal: true

require "stringio"

module Thuban
  module Remote
    class Connection
      MAX_PUSH_UPDATES = 1024
      MAX_PUSH_RESPONSE_SIZE = 8 * 1024 * 1024
      ZERO_OID = "0" * 40

      def push(repository, updates, atomic: false)
        ensure_open
        raise TypeError, "expected Thuban::Repository" unless repository.is_a?(Repository)
        raise ArgumentError, "atomic must be true or false" unless [true, false].include?(atomic)

        updates = normalize_push_updates(repository, updates)
        advertised = receive_refs
        updates.each do |update|
          current = advertised.find { |ref| ref.name == update[:ref] }&.oid || ZERO_OID
          expected = update[:old] || current
          raise TransportError, "remote reference changed: #{update[:ref]}" unless current == expected

          update[:old] = expected
        end
        capabilities = push_capabilities(atomic, updates)
        objects = push_objects(repository, updates.map { |update| update[:new] }, advertised)
        output = StringIO.new(Protocol.commands(updates, capabilities))
        output.seek(0, IO::SEEK_END)
        Pack.write(output, objects) do |current, total|
          ensure_open
          yield Progress.new(phase: :pack, current: current, total: total, bytes: output.pos) if block_given?
        end if updates.any? { |update| update[:new] != ZERO_OID }

        response = request(:post, "/git-receive-pack", body: output.string,
          headers: {"Content-Type" => "application/x-git-receive-pack-request",
                    "Accept" => "application/x-git-receive-pack-result"},
          content_type: "application/x-git-receive-pack-result", limit: MAX_PUSH_RESPONSE_SIZE)
        parse_push_response(response, updates, capabilities) do |progress|
          yield progress if block_given?
        end
        updates.map { |update| Ref.new(name: update[:ref], oid: update[:new] == ZERO_OID ? nil : update[:new]) }
      ensure
        @receive_refs = nil
      end

      private

      def receive_refs
        return @receive_refs if @receive_refs

        fetch_capabilities = @capabilities
        begin
          body = request(:get, "/info/refs", query: "service=git-receive-pack",
            headers: {"Accept" => "application/x-git-receive-pack-advertisement"},
            content_type: "application/x-git-receive-pack-advertisement", limit: MAX_ADVERTISEMENT_SIZE)
          reader = Protocol::Reader.new(StringIO.new(body), max_bytes: MAX_ADVERTISEMENT_SIZE)
          first = reader.read
          if first == "# service=git-receive-pack\n"
            raise TransportError, "invalid receive-pack advertisement" unless reader.read == Protocol::FLUSH
            first = reader.read
          end
          refs = read_v0_refs(reader, first)
          @receive_capabilities = @capabilities
          @receive_refs = refs
        ensure
          @capabilities = fetch_capabilities
        end
      end

      def normalize_push_updates(repository, updates)
        raise TypeError, "updates must be enumerable" unless updates.respond_to?(:each)

        result = []
        updates.each do |entry|
          raise ArgumentError, "updates must be [ref, old_oid, new_oid]" unless entry.is_a?(Array) && entry.length == 3
          raise ArgumentError, "too many push updates" if result.length >= MAX_PUSH_UPDATES

          ref, old_oid, new_oid = entry
          ref = Protocol.validate_ref(ref)
          raise TransportError, "HEAD cannot be updated directly" if ref == "HEAD"
          old_oid = Protocol.validate_oid(old_oid) unless old_oid.nil?
          new_oid = Protocol.validate_oid(new_oid)
          raise ArgumentError, "object to push was not found: #{new_oid}" if new_oid != ZERO_OID && !repository.odb.exist?(new_oid)
          raise ArgumentError, "duplicate push destination: #{ref}" if result.any? { |update| update[:ref] == ref }

          result << {ref: ref, old: old_oid, new: new_oid}
        end
        raise ArgumentError, "at least one push update is required" if result.empty?

        result
      end

      def push_capabilities(atomic, updates)
        advertised = @receive_capabilities
        status = %w[report-status-v2 report-status].find { |capability| advertised.include?(capability) }
        raise TransportError, "server does not report push status" unless status
        raise TransportError, "server does not support reference deletion" if updates.any? { |update| update[:new] == ZERO_OID } && !advertised.include?("delete-refs")
        raise TransportError, "server does not support atomic push" if atomic && !advertised.include?("atomic")

        [status, ("side-band-64k" if advertised.include?("side-band-64k")), ("atomic" if atomic)].compact
      end

      def push_objects(repository, new_oids, advertised)
        excluded = advertised.flat_map { |ref| [ref.oid, ref.peeled] }.compact.to_h { |oid| [oid, true] }
        seen = {}
        objects = []
        pending = new_oids.reject { |oid| oid == ZERO_OID }
        until pending.empty?
          ensure_open
          oid = pending.pop
          next if seen[oid] || excluded[oid]

          seen[oid] = true
          type, data = repository.odb.read(oid)
          objects << [type, data]
          pending.concat(referenced_oids(type, data))
        end
        objects
      end

      def referenced_oids(type, data)
        case type
        when "commit"
          data.split("\n\n", 2).first.lines.filter_map do |line|
            oid = line[/\A(?:tree|parent) ([0-9a-f]{40})\n?\z/, 1]
            oid && Protocol.validate_oid(oid)
          end
        when "tag"
          oid = data[/\Aobject ([0-9a-f]{40})\n/, 1]
          oid ? [Protocol.validate_oid(oid)] : []
        when "tree"
          tree_oids(data)
        else
          []
        end
      end

      def tree_oids(data)
        result = []
        offset = 0
        while offset < data.bytesize
          ending = data.index("\0", offset)
          raise CorruptObject, "invalid tree object" unless ending && ending + 21 <= data.bytesize

          result << data.byteslice(ending + 1, 20).unpack1("H*")
          offset = ending + 21
        end
        result
      end

      def parse_push_response(body, updates, capabilities)
        packets = read_push_packets(StringIO.new(body), capabilities.include?("side-band-64k")) do |text|
          yield Progress.new(phase: :remote, current: nil, total: nil, bytes: text.bytesize)
        end
        unpack = packets.shift
        raise TransportError, "push response omitted unpack status" unless unpack&.start_with?("unpack ")
        raise TransportError, "remote unpack failed: #{safe_message(unpack.delete_prefix("unpack "))}" unless unpack == "unpack ok\n"

        statuses = {}
        report_v2 = capabilities.include?("report-status-v2")
        current_ref = nil
        options = {}
        packets.each do |packet|
          state, ref, reason = packet.chomp.split(" ", 3)
          if state == "option"
            raise TransportError, "invalid push option" unless report_v2 && current_ref && ref && !options[ref]

            validate_push_option(ref, reason)
            options[ref] = true
            next
          end
          valid = state == "ok" ? ref && reason.nil? : state == "ng" && ref && reason && !reason.empty?
          raise TransportError, "invalid push status" unless valid

          ref = Protocol.validate_ref(ref)
          raise TransportError, "duplicate push status" if statuses.key?(ref)

          statuses[ref] = [state, reason]
          current_ref = state == "ok" ? ref : nil
          options = {}
        end
        expected_refs = updates.map { |update| update[:ref] }
        raise TransportError, "push status included an unknown reference" unless (statuses.keys - expected_refs).empty?

        updates.each_with_index do |update, index|
          state, reason = statuses.fetch(update[:ref]) { raise TransportError, "push status missing for #{update[:ref]}" }
          raise TransportError, "push rejected for #{update[:ref]}: #{safe_message(reason.to_s)}" unless state == "ok"
          yield Progress.new(phase: :push, current: index + 1, total: updates.length, bytes: nil)
        end
      end

      def validate_push_option(name, value)
        case name
        when "refname" then Protocol.validate_ref(value)
        when "old-oid", "new-oid" then Protocol.validate_oid(value)
        when "forced-update" then raise TransportError, "invalid push option" unless value.nil?
        else raise TransportError, "invalid push option"
        end
      end

      def read_push_packets(input, sideband)
        reader = Protocol::Reader.new(input, max_bytes: MAX_PUSH_RESPONSE_SIZE)
        status = +"".b
        result = []
        loop do
          packet = reader.read
          raise TransportError, "truncated push response" if packet.nil?
          break if packet == Protocol::FLUSH
          raise TransportError, "invalid push response" unless packet.is_a?(String)

          unless sideband
            result << packet
            next
          end
          band = packet.getbyte(0)
          data = packet.byteslice(1..).to_s
          case band
          when 1 then status << data
          when 2 then yield safe_message(data)
          when 3 then raise TransportError, "remote error: #{safe_message(data)}"
          else raise TransportError, "invalid sideband channel"
          end
        end
        return result unless sideband

        nested = Protocol::Reader.new(StringIO.new(status), max_bytes: MAX_PUSH_RESPONSE_SIZE)
        loop do
          packet = nested.read
          raise TransportError, "truncated push status" if packet.nil?
          break if packet == Protocol::FLUSH
          raise TransportError, "invalid push status" unless packet.is_a?(String)
          result << packet
        end
        raise TransportError, "invalid push status" if nested.read

        result
      end
    end

    module Protocol
      def self.commands(updates, capabilities)
        updates.each_with_index.map do |update, index|
          suffix = index.zero? && !capabilities.empty? ? "\0#{capabilities.join(" ")}" : ""
          packet("#{update.fetch(:old)} #{update.fetch(:new)} #{update.fetch(:ref)}#{suffix}\n")
        end.join + flush
      end
    end
  end
end
