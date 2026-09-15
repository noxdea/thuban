# frozen_string_literal: true

require "uri"

module Thuban
  module Remote
    class LocalConnection < SSHConnection
      def initialize(url, credentials: nil, timeout: 30)
        raise AuthenticationError, "credentials cannot be used with local remotes" unless credentials.nil?

        @path = parse_local_url(url)
        @timeout = Float(timeout)
        raise ArgumentError, "timeout must be between 0 and 300 seconds" unless @timeout.positive? && @timeout <= 300

        @process_lock = Mutex.new
        @process = nil
        @closed = false
      rescue AuthenticationError
        raise
      rescue ArgumentError, TypeError => error
        raise error if error.message.start_with?("timeout")

        raise TransportError, "invalid local remote"
      end

      private

      def command(service) = [service, @path]

      def parse_local_url(url)
        raise TypeError unless url.is_a?(String) && !url.empty? && url.bytesize <= 8192 && !url.match?(/[\0\r\n]/)

        if url.match?(/\Afile:\/\//i)
          uri = URI.parse(url)
          raise ArgumentError unless uri.scheme.casecmp?("file") && [nil, "", "localhost"].include?(uri.host) && !uri.query && !uri.fragment

          path = URI::RFC2396_PARSER.unescape(uri.path)
          path = path.delete_prefix("/") if Gem.win_platform? && path.match?(/\A\/[A-Za-z]:\//)
        else
          raise ArgumentError if url.include?("://")

          path = url
        end
        raise ArgumentError if path.empty? || path.match?(/[\0\r\n]/)
        File.expand_path(path)
      end

      def process_environment
        super.merge("GIT_DIR" => nil, "GIT_WORK_TREE" => nil, "GIT_OBJECT_DIRECTORY" => nil,
          "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil, "GIT_CONFIG_COUNT" => nil,
          "GIT_CONFIG_GLOBAL" => nil, "GIT_CONFIG_SYSTEM" => nil)
      end
    end
  end
end
