# frozen_string_literal: true

module Thuban
  class Error < StandardError; end
  class TransportError < Error; end
  class AuthenticationError < TransportError; end

  Ref = Struct.new(:name, :oid, :symref_target, :peeled, keyword_init: true)

  module Remote
    def self.open(url, credentials: nil, ssh: nil, timeout: 30)
      if url.is_a?(String) && (url.match?(/\Assh:\/\//i) || (!url.include?("://") && url.include?(":")))
        return SSHConnection.new(url, credentials: credentials, ssh: ssh, timeout: timeout)
      end
      raise ArgumentError, "ssh configuration requires an SSH remote" if ssh

      Connection.new(url, credentials: credentials, timeout: timeout)
    end
  end
end
