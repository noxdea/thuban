# frozen_string_literal: true

module Thuban
  class Error < StandardError; end
  class TransportError < Error; end
  class AuthenticationError < TransportError; end

  Ref = Struct.new(:name, :oid, :symref_target, :peeled, keyword_init: true)
  Progress = Struct.new(:phase, :current, :total, :bytes, keyword_init: true)

  module Remote
    autoload :Credentials, File.expand_path("remote/credentials", __dir__)
    autoload :Protocol, File.expand_path("remote/protocol", __dir__)
    autoload :Connection, File.expand_path("remote/http", __dir__)
    autoload :SSHConnection, File.expand_path("remote/ssh", __dir__)
    autoload :LocalConnection, File.expand_path("remote/local", __dir__)

    def self.open(url, credentials: nil, ssh: nil, timeout: 30)
      local_drive = url.is_a?(String) && url.match?(/\A[A-Za-z]:[\\\/]/)
      local_path = local_drive || (url.is_a?(String) && url.start_with?("/", "./", "../", "~"))
      if url.is_a?(String) && (url.match?(/\Assh:\/\//i) || (!local_path && !url.include?("://") && url.include?(":")))
        return SSHConnection.new(url, credentials: credentials, ssh: ssh, timeout: timeout)
      end
      raise ArgumentError, "ssh configuration requires an SSH remote" if ssh

      if url.is_a?(String) && !url.match?(/\Ahttps?:\/\//i)
        return LocalConnection.new(url, credentials: credentials, timeout: timeout)
      end

      Connection.new(url, credentials: credentials, timeout: timeout)
    end
  end
end
