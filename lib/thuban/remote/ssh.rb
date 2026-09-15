# frozen_string_literal: true

require "open3"
require "shellwords"
require "timeout"
require "uri"

module Thuban
  module Remote
    class SSHConnection < Connection
      MAX_COMMAND_ARGUMENTS = 64
      MAX_COMMAND_ARGUMENT_SIZE = 4096
      USER_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/n
      HOST_PATTERN = /\A(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])\z/n
      PATH_PATTERN = /\A[0-9A-Za-z._~+\/:@=-]{1,4096}\z/n

      def initialize(url, credentials: nil, ssh: nil, timeout: 30)
        raise AuthenticationError, "HTTP credentials cannot be used with SSH remotes" unless credentials.nil?

        @user, @host, @port, @path = parse_ssh_url(url)
        @ssh_command = parse_ssh_command(ssh)
        @timeout = Float(timeout)
        raise ArgumentError, "timeout must be between 0 and 300 seconds" unless @timeout.positive? && @timeout <= 300

        @process_lock = Mutex.new
        @process = nil
        @closed = false
      rescue AuthenticationError
        raise
      rescue ArgumentError, TypeError
        raise ArgumentError, "timeout must be between 0 and 300 seconds" if defined?(@timeout)

        raise TransportError, "invalid SSH remote"
      end

      def refs
        ensure_open
        @refs = with_process("git-upload-pack") do |stdin, stdout|
          reader = Protocol::Reader.new(stdout, max_bytes: MAX_ADVERTISEMENT_SIZE)
          first = reader.read
          @protocol_version = 0
          result = read_v0_refs(reader, first)
          stdin.close
          result
        end
      end

      def close
        process = @process_lock.synchronize do
          @closed = true
          @process
        end
        cleanup(process)
        nil
      end

      private

      def receive_refs
        return @receive_refs if @receive_refs

        fetch_capabilities = @capabilities
        begin
          ensure_open
          with_process("git-receive-pack") do |stdin, stdout|
            reader = Protocol::Reader.new(stdout, max_bytes: MAX_ADVERTISEMENT_SIZE)
            first = reader.read
            result = read_v0_refs(reader, first)
            @receive_capabilities = @capabilities
            stdin.close
            @receive_refs = result
          end
        ensure
          @capabilities = fetch_capabilities
        end
      end

      def request_each(method, suffix, query: nil, headers: {}, body: nil, content_type:, limit:)
        services = {"/git-upload-pack" => "git-upload-pack", "/git-receive-pack" => "git-receive-pack"}
        service = services[suffix]
        raise TransportError, "invalid SSH request" unless method == :post && service && query.nil? && body

        received = 0
        with_process(service, check_status: true) do |stdin, stdout|
          discard_advertisement(stdout)
          stdin.write(body)
          stdin.close
          while (chunk = stdout.read(65_536))
            received += chunk.bytesize
            raise TransportError, "SSH response exceeds size limit" if received > limit

            yield chunk
          end
        end
        received
      end

      def discard_advertisement(stdout)
        reader = Protocol::Reader.new(stdout, max_bytes: MAX_ADVERTISEMENT_SIZE)
        loop do
          packet = reader.read
          return if packet == Protocol::FLUSH
          raise TransportError, "truncated SSH advertisement" unless packet.is_a?(String)
        end
      end

      def with_process(service, check_status: false)
        process = start_process(service)
        result = Timeout.timeout(@timeout) do
          value = yield(process[:stdin], process[:stdout])
          if check_status
            status = process[:waiter].value
            raise TransportError, "SSH transport failed" unless status.success?
          end
          value
        end
        result
      rescue Timeout::Error
        raise TransportError, "SSH transport timed out", cause: nil
      rescue TransportError
        raise
      rescue Errno::ENOENT
        raise TransportError, "SSH executable not found", cause: nil
      rescue IOError, SystemCallError
        raise TransportError, "SSH transport failed", cause: nil
      ensure
        @process_lock&.synchronize { @process = nil if @process.equal?(process) }
        cleanup(process)
      end

      def start_process(service)
        ensure_open
        grouped = !Gem.win_platform?
        options = grouped ? {pgroup: true} : {}
        stdin, stdout, stderr, waiter = Open3.popen3(process_environment, *command(service), **options)
        [stdin, stdout, stderr].each(&:binmode)
        process = {stdin: stdin, stdout: stdout, stderr: stderr, waiter: waiter, grouped: grouped}
        process[:errors] = Thread.new { while stderr.read(4096); end rescue nil }
        @process_lock.synchronize do
          if @closed
            cleanup(process)
            raise TransportError, "connection is closed"
          end
          @process = process
        end
        process
      end

      def command(service)
        destination = @user ? "#{@user}@#{@host}" : @host
        port = @port ? ["-p", @port.to_s] : []
        @ssh_command + ["-o", "BatchMode=yes", *port, "--", destination,
          "#{service} #{Shellwords.escape(@path)}"]
      end

      def process_environment
        {"GIT_PROTOCOL" => nil, "GIT_TERMINAL_PROMPT" => "0", "GIT_TRACE" => nil,
         "GIT_TRACE2" => nil, "GIT_TRACE_PACKET" => nil}
      end

      def safe_message(_data) = "remote reported an error"

      def cleanup(process)
        return unless process

        [process[:stdin], process[:stdout], process[:stderr]].each { |io| io.close unless io.closed? }
        terminate(process[:waiter], process[:grouped]) if process[:waiter].alive? && !process[:waiter].join(0.2)
        process[:errors]&.join
      rescue IOError, Errno::ECHILD
        nil
      end

      def terminate(waiter, grouped)
        unless grouped
          Process.kill("KILL", waiter.pid)
          waiter.join
          return
        end

        target = -waiter.pid
        Process.kill("TERM", target)
        return if waiter.join(0.2)

        Process.kill("KILL", target)
        waiter.join
      rescue Errno::EPERM
        begin
          Process.kill("TERM", waiter.pid)
          Process.kill("KILL", waiter.pid) unless waiter.join(0.2)
          waiter.join
        rescue SystemCallError
          nil
        end
      rescue SystemCallError
        nil
      end

      def parse_ssh_url(url)
        raise TypeError unless url.is_a?(String) && url.bytesize <= 8192

        target = url.match?(/\Assh:\/\//i) ? parse_uri(url) : parse_scp(url)
        user, host, port, path = target
        raise ArgumentError unless (!user || USER_PATTERN.match?(user)) && HOST_PATTERN.match?(host) &&
          (!port || (1..65_535).cover?(port)) && PATH_PATTERN.match?(path) && !path.start_with?("-")

        target
      end

      def parse_uri(url)
        uri = URI.parse(url)
        raise AuthenticationError, "passwords in SSH remote URLs are not supported" if uri.password
        raise ArgumentError unless uri.scheme == "ssh" && uri.host && !uri.host.empty? &&
          uri.path && !uri.path.empty? && !uri.query && !uri.fragment

        [decode(uri.user), uri.host, uri.port, decode(uri.path)]
      end

      def parse_scp(url)
        match = /\A(?:(?<user>[A-Za-z0-9][A-Za-z0-9._-]{0,63})@)?(?<host>\[[0-9A-Fa-f:.]+\]|[^:]+):(?<path>.+)\z/n.match(url)
        raise ArgumentError unless match

        [match[:user], match[:host], nil, match[:path]]
      end

      def decode(value)
        value && URI::RFC2396_PARSER.unescape(value)
      end

      def parse_ssh_command(value)
        value = ENV["GIT_SSH_COMMAND"] if value.nil? && !ENV["GIT_SSH_COMMAND"].to_s.empty?
        arguments = case value
        when nil then ["ssh"]
        when String then Shellwords.split(value)
        when Array then value.dup
        else raise TypeError
        end
        valid = arguments.length.between?(1, MAX_COMMAND_ARGUMENTS) && arguments.all? do |argument|
          argument.is_a?(String) && !argument.empty? && argument.bytesize <= MAX_COMMAND_ARGUMENT_SIZE &&
            !argument.match?(/[\0\r\n]/)
        end
        raise ArgumentError unless valid

        arguments.map! { |argument| argument.dup.freeze }
        arguments.freeze
      end
    end
  end
end
