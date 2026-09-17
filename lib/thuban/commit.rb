# frozen_string_literal: true

module Thuban
  Commit = Struct.new(:oid, :tree, :parents, :author, :committer, :message, keyword_init: true) do
    def signature(role: :author)
      raise ArgumentError, "role must be :author or :committer" unless %i[author committer].include?(role)

      match = public_send(role).to_s.match(/\A(.+) <([^<>]+)> (-?\d+) ([+-]\d{4})\z/)
      raise CorruptObject, "invalid commit signature" unless match

      Signature.new(name: match[1], email: match[2], time: Integer(match[3]), offset: match[4])
    end
  end
end
