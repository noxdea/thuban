# frozen_string_literal: true

require "net/http"
require "stringio"
require "uri"

module Thuban
  module Remote
    class Connection
      MAX_ADVERTISEMENT_SIZE = 8 * 1024 * 1024

      def initialize(url, credentials: nil, timeout: 30)
        @uri = parse_url(url)
        Credentials.validate(credentials)
        @credentials = credentials
        @timeout = Float(timeout)
        raise ArgumentError, "timeout must be between 0 and 300 seconds" unless @timeout.positive? && @timeout <= 300
        @authorization_lock = Mutex.new
        @request_lock = Mutex.new
        @active_http = nil
        @closed = false
      rescue ArgumentError, TypeError => error
        raise error if error.message.start_with?("timeout")

        raise TransportError, "invalid remote URL"
      end

      def refs
        ensure_open
        body = request(:get, "/info/refs", query: "service=git-upload-pack",
          headers: {"Accept" => "application/x-git-upload-pack-advertisement", "Git-Protocol" => "version=2"},
          content_type: "application/x-git-upload-pack-advertisement", limit: MAX_ADVERTISEMENT_SIZE)
        reader = Protocol::Reader.new(StringIO.new(body), max_bytes: MAX_ADVERTISEMENT_SIZE)
        first = reader.read
        if first == "# service=git-upload-pack\n"
          raise TransportError, "invalid upload-pack advertisement" unless reader.read == Protocol::FLUSH
          first = reader.read
        end
        @refs = if first == "version 2\n"
          @protocol_version = 2
          read_v2_refs(reader)
        else
          @protocol_version = 0
          read_v0_refs(reader, first)
        end
      end

      def close
        http = @request_lock.synchronize do
          @closed = true
          @active_http
        end
        socket = http&.instance_variable_get(:@socket)
        socket.io.shutdown(Socket::SHUT_RDWR) if socket && !socket.closed?
        socket.close if socket && !socket.closed?
        http.finish if http&.started?
        nil
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      end

      private

      def parse_url(url)
        raise TypeError unless url.is_a?(String)

        uri = URI.parse(url)
        raise AuthenticationError, "credentials in remote URLs are not supported" if uri.userinfo

        valid = %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty? &&
          !uri.fragment && !uri.query
        raise ArgumentError unless valid

        uri
      end

      def read_v2_refs(reader)
        capabilities = []
        loop do
          packet = reader.read
          break if packet == Protocol::FLUSH
          raise TransportError, "truncated capability advertisement" unless packet.is_a?(String)

          capabilities << packet.chomp
        end
        reject_non_sha1(capabilities)
        raise TransportError, "server does not support ls-refs" unless capabilities.any? { |line| line.split("=", 2).first == "ls-refs" }

        @capabilities = capabilities
        body = Protocol.packet("command=ls-refs\n") + Protocol.delimiter +
          %w[peel symrefs ref-prefix\ HEAD ref-prefix\ refs/].map { |line| Protocol.packet("#{line}\n") }.join + Protocol.flush
        response = request(:post, "/git-upload-pack", body: body,
          headers: {"Content-Type" => "application/x-git-upload-pack-request", "Accept" => "application/x-git-upload-pack-result",
                    "Git-Protocol" => "version=2"}, content_type: "application/x-git-upload-pack-result", limit: MAX_ADVERTISEMENT_SIZE)
        parse_v2_ref_lines(Protocol::Reader.new(StringIO.new(response), max_bytes: MAX_ADVERTISEMENT_SIZE))
      end

      def parse_v2_ref_lines(reader)
        result = []
        loop do
          packet = reader.read
          break if [Protocol::FLUSH, Protocol::RESPONSE_END].include?(packet)
          raise TransportError, "truncated ls-refs response" unless packet.is_a?(String)
          raise TransportError, safe_message(packet.delete_prefix("ERR ")) if packet.start_with?("ERR ")
          fields = packet.chomp.split(" ")
          oid = fields.shift
          name = Protocol.validate_ref(fields.shift)
          attributes = fields.to_h { |field| field.split(":", 2) }
          result << Ref.new(name: name, oid: oid == "unborn" ? nil : Protocol.validate_oid(oid),
            symref_target: attributes["symref-target"] && Protocol.validate_ref(attributes["symref-target"]),
            peeled: attributes["peeled"] && Protocol.validate_oid(attributes["peeled"]))
        end
        result
      end

      def read_v0_refs(reader, first)
        raise TransportError, "empty upload-pack advertisement" unless first.is_a?(String)

        lines = [first]
        loop do
          packet = reader.read
          break if packet == Protocol::FLUSH
          raise TransportError, "truncated ref advertisement" unless packet.is_a?(String)

          lines << packet
        end
        payload, capabilities = lines.first.split("\0", 2)
        lines[0] = payload
        @capabilities = capabilities.to_s.chomp.split(" ")
        reject_non_sha1(@capabilities)
        symrefs = @capabilities.grep(/\Asymref=/).to_h do |capability|
          name, target = capability.delete_prefix("symref=").split(":", 2)
          [Protocol.validate_ref(name), Protocol.validate_ref(target)]
        end
        result = []
        peeled = {}
        lines.each do |line|
          raise TransportError, safe_message(line.delete_prefix("ERR ")) if line.start_with?("ERR ")

          oid, name = line.chomp.split(" ", 2)
          next if oid == "0" * 40 && name == "capabilities^{}"
          next unless name == "HEAD" || name&.start_with?("refs/")

          if name.end_with?("^{}")
            peeled[name.delete_suffix("^{}")] = Protocol.validate_oid(oid)
          else
            name = Protocol.validate_ref(name)
            result << Ref.new(name: name, oid: Protocol.validate_oid(oid), symref_target: symrefs[name])
          end
        end
        result.each { |ref| ref.peeled = peeled[ref.name] }
        result
      end

      def reject_non_sha1(capabilities)
        format = capabilities.find { |line| line.start_with?("object-format=") }
        raise TransportError, "remote object format is not SHA-1" if format && format != "object-format=sha1"
      end

      def request(method, suffix, query: nil, headers: {}, body: nil, content_type:, limit:)
        result = +"".b
        request_each(method, suffix, query: query, headers: headers, body: body, content_type: content_type, limit: limit) do |chunk|
          result << chunk
        end
        result
      end

      def request_each(method, suffix, query: nil, headers: {}, body: nil, content_type:, limit:)
        endpoint = @uri.dup
        endpoint.path = @uri.path.sub(%r{/\z}, "") + suffix
        endpoint.query = query
        http = Net::HTTP.new(endpoint.host, endpoint.port, nil)
        http.max_retries = 0
        http.use_ssl = endpoint.scheme == "https"
        http.open_timeout = http.read_timeout = @timeout
        http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
        @request_lock.synchronize do
          raise TransportError, "connection is closed" if @closed
          @active_http = http
        end
        request_headers = headers.merge("Accept-Encoding" => "identity")
        auth = authorization
        request_headers["Authorization"] = auth if auth
        request = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(endpoint.request_uri, request_headers)
        request.body = body if body
        received = 0
        @request_lock.synchronize { raise TransportError, "connection is closed" if @closed }
        http.start do
          http.request(request) do |response|
            validate_response(response, content_type)
            declared = response["content-length"]
            raise TransportError, "HTTP response exceeds size limit" if declared&.match?(/\A\d+\z/) && declared.to_i > limit
            response.read_body do |chunk|
              received += chunk.bytesize
              raise TransportError, "HTTP response exceeds size limit" if received > limit

              yield chunk
            end
          end
        end
        received
      rescue TransportError, AuthenticationError
        raise
      rescue Timeout::Error, IOError, SocketError, SystemCallError => error
        raise TransportError, "HTTP transport failed: #{error.class}"
      ensure
        @request_lock&.synchronize { @active_http = nil if @active_http.equal?(http) }
      end

      def validate_response(response, content_type)
        code = response.code.to_i
        raise AuthenticationError, "remote authentication required" if [401, 403].include?(code)
        raise TransportError, "HTTP redirects are not supported" if (300...400).cover?(code)
        raise TransportError, "HTTP request failed (#{code})" unless code == 200
        actual = response["content-type"].to_s.split(";", 2).first.downcase
        raise TransportError, "unexpected HTTP content type" unless actual == content_type
      end

      def authorization
        return @authorization if defined?(@authorization)

        @authorization_lock.synchronize do
          @authorization = @credentials&.send(:authorization, @uri, timeout: @timeout) unless defined?(@authorization)
        end
        @authorization
      end

      def ensure_open
        raise TransportError, "connection is closed" if @closed
      end
    end
  end
end
