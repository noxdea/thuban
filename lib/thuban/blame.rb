# frozen_string_literal: true

module Thuban
  class Blame
    Line = Struct.new(:line, :text, :commit, :author, :original_line, :path, keyword_init: true)

    def initialize(repository)
      @repository = repository
    end

    def call(path, reference: "HEAD", differ: Porrima)
      revision = @repository.commit(reference)
      return [] unless revision
      current = @repository.blob(path, reference: revision.oid)
      return [] unless current
      result = Array.new(current.lines.length)
      pending = [[revision, path, current, result.each_index.to_h { |index| [index, index] }]]
      until pending.empty?
        commit, current_path, contents, unresolved = pending.pop
        commit.parents.each do |parent_oid|
          break if unresolved.empty?
          parent = @repository.commit(parent_oid)
          parent_tree = @repository.tree(parent_oid)
          parent_path = current_path
          unless parent_tree.key?(current_path)
            current_oid = @repository.tree(commit.oid)[current_path]&.oid
            parent_path = parent_tree.values.find { |entry| entry.oid == current_oid }&.path
          end
          next unless parent_path
          previous = @repository.blob(parent_path, reference: parent_oid)
          next unless previous
          inherited = {}
          differ.edits(previous, contents).each do |edit|
            next unless edit.kind == :equal && unresolved.key?(edit.new_line - 1)
            inherited[edit.old_line - 1] = unresolved.delete(edit.new_line - 1)
          end
          pending << [parent, parent_path, previous, inherited] unless inherited.empty?
        end
        lines = contents.lines
        unresolved.each do |original, target|
          result[target] = Line.new(line: target + 1, text: lines[original].force_encoding(Encoding::UTF_8),
            commit: commit.oid, author: commit.author, original_line: original + 1, path: current_path)
        end
      end
      result
    end
  end
end
