# frozen_string_literal: true

module Thuban
  class Error < StandardError; end
  class TransportError < Error; end
  class AuthenticationError < TransportError; end

  Ref = Struct.new(:name, :oid, :symref_target, :peeled, keyword_init: true)

  module Remote
    def self.open(url, credentials: nil, ssh: nil, timeout: 30)
      raise TransportError, "SSH transport is not supported yet" if ssh

      Connection.new(url, credentials: credentials, timeout: timeout)
    end
  end
end
