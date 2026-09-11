# frozen_string_literal: true

module Thuban
  Commit = Struct.new(:oid, :tree, :parents, :author, :committer, :message, keyword_init: true)
end
