# frozen_string_literal: true

require "open3"

module Thuban
  module Remote
    module Credentials
      MAX_HELPER_OUTPUT = 1024 * 1024

      class Provider
        def inspect = "#<#{self.class.name} [REDACTED]>"
      end
      class Basic < Provider
        def initialize(username, password)
          @username = username
          @password = password
        end

        def authorization(_url, timeout:)
          "Basic #{["#{@username}:#{@password}"].pack("m0")}"
        end
      end
      class Bearer < Provider
        def initialize(token) = @token = token
        def authorization(_url, timeout:) = "Bearer #{@token}"
      end
      class Callback < Provider
        def initialize(callback) = @callback = callback

        def authorization(url, timeout:)
          credential = @callback.call(url.to_s.freeze)
          return if credential.nil?
          raise AuthenticationError, "credential callback returned an invalid value", cause: nil unless credential.is_a?(Provider)
          raise AuthenticationError, "credential callback cannot return itself", cause: nil if credential.equal?(self)

          credential.authorization(url, timeout: timeout)
        rescue AuthenticationError
          raise
        rescue StandardError
          raise AuthenticationError, "credential callback failed", cause: nil
        end
      end

      class Helper < Provider
        def initialize(name) = @name = name

        def authorization(url, timeout:)
          fields = parse(run(input_for(url), timeout))
          if fields["username"] && fields.key?("password")
            return Credentials.static(username: fields["username"], password: fields["password"]).authorization(url, timeout: timeout)
          end
          if fields["authtype"]&.casecmp?("Bearer") && fields["credential"]
            return Credentials.bearer(token: fields["credential"]).authorization(url, timeout: timeout)
          end

          raise AuthenticationError, "credential helper returned no usable credentials", cause: nil
        rescue ArgumentError
          raise AuthenticationError, "credential helper returned invalid credentials", cause: nil
        end

        private

        def command
          return ["git", "credential", "fill"] unless @name

          ["git", "-c", "credential.helper=", "-c", "credential.helper=#{@name}", "credential", "fill"]
        end

        def input_for(url)
          host = url.hostname
          host = "[#{host}]" if host.include?(":")
          host = "#{host}:#{url.port}" unless url.port == url.default_port
          "capability[]=authtype\nprotocol=#{url.scheme}\nhost=#{host}\npath=#{url.path.delete_prefix("/")}\n\n"
        end

        def run(input, timeout)
          grouped = !Gem.win_platform?
          options = grouped ? {pgroup: true} : {}
          stdin, stdout, stderr, waiter = Open3.popen3(helper_environment, *command, **options)
          errors = Thread.new { while stderr.read(4096); end rescue nil }
          output_error = nil
          output = Thread.new do
            read_bounded(stdout)
          rescue AuthenticationError => error
            output_error = error
            nil
          rescue StandardError
            output_error = AuthenticationError.new("credential helper failed")
            nil
          end
          stdin.write(input)
          stdin.close
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          while waiter.alive? || output.alive?
            raise output_error if output_error

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise AuthenticationError, "credential helper timed out", cause: nil unless remaining.positive?

            (waiter.alive? ? waiter : output).join([remaining, 0.01].min)
          end
          raise output_error if output_error
          raise AuthenticationError, "credential helper failed", cause: nil unless waiter.value.success?

          output.value
        rescue AuthenticationError
          raise
        rescue StandardError
          raise AuthenticationError, "credential helper failed", cause: nil
        ensure
          terminate(waiter, grouped) if waiter&.alive?
          [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
          output&.join
          errors&.join
        end

        def read_bounded(io)
          result = +"".b
          while (chunk = io.read(4096))
            result << chunk
            raise AuthenticationError, "credential helper output exceeds size limit", cause: nil if result.bytesize > MAX_HELPER_OUTPUT
          end
          result
        end

        def terminate(waiter, grouped)
          target = grouped ? -waiter.pid : waiter.pid
          Process.kill("TERM", target)
          return if waiter.join(0.2)

          Process.kill("KILL", target)
          waiter.join
        rescue Errno::ESRCH, Errno::ECHILD
          nil
        end

        def helper_environment
          {"GIT_TERMINAL_PROMPT" => "0", "GCM_INTERACTIVE" => "Never",
           "GIT_TRACE" => nil, "GIT_TRACE2" => nil, "GIT_TRACE_CURL" => nil}
        end

        def parse(output)
          fields = {}
          output.b.each_line(chomp: true) do |line|
            line = line.delete_suffix("\r")
            break if line.empty?

            key, value = line.split("=", 2)
            raise AuthenticationError, "credential helper returned invalid output", cause: nil unless value && /\A[a-zA-Z0-9_-]+(?:\[\])?\z/n.match?(key)

            if key.end_with?("[]")
              (fields[key] ||= []) << value
              next
            end
            raise AuthenticationError, "credential helper returned duplicate fields", cause: nil if fields.key?(key)

            fields[key] = value
          end
          fields
        end
      end

      def self.static(username:, password:)
        validate_basic(username, password)
        Basic.new(username.dup.freeze, password.dup.freeze)
      end

      def self.bearer(token:)
        raise ArgumentError, "bearer token must be a non-empty String without whitespace" unless token.is_a?(String) && /\A[^\x00-\x20\x7f]+\z/n.match?(token)

        Bearer.new(token.dup.freeze)
      end

      def self.callback(&block)
        raise ArgumentError, "credential callback is required" unless block

        Callback.new(block)
      end

      def self.helper(name = nil)
        valid = name.nil? || (name.is_a?(String) && !name.empty? && name.bytesize <= 4096 && !name.match?(/[\r\n\0]/))
        raise ArgumentError, "credential helper name is invalid" unless valid

        Helper.new(name&.dup&.freeze)
      end

      def self.validate(value)
        return if value.nil? || value.is_a?(Provider)

        raise AuthenticationError, "credentials must be created with Thuban::Remote::Credentials"
      end

      def self.validate_basic(username, password)
        valid_username = username.is_a?(String) && !username.empty? && !username.match?(/[:\r\n\0]/)
        valid_password = password.is_a?(String) && !password.match?(/[\r\n\0]/)
        raise ArgumentError, "basic credentials are invalid" unless valid_username && valid_password
      end

      private_constant :Provider, :Basic, :Bearer, :Callback, :Helper
      private_class_method :validate_basic
    end
  end
end
