# frozen_string_literal: true

module Thuban
  class Repository
    def write_tree_from_index
      current = index
      raise ArgumentError, "cannot write a tree with unresolved conflicts" unless current.conflicts.empty?

      root = {}
      current.entries.each do |entry|
        node = root
        parts = entry.path.split("/")
        parts[0...-1].each do |part|
          raise ArgumentError, "index contains a file/directory collision" if node.key?(part) && !node[part].is_a?(Hash)
          node = node[part] ||= {}
        end
        raise ArgumentError, "index contains duplicate or colliding paths" if node.key?(parts.last)
        node[parts.last] = entry
      end
      write_index_tree(root)
    end

    def commit!(message:, author:, amend: false)
      previous = head
      current = previous && commit(previous)
      raise ArgumentError, "cannot amend an unborn branch" if amend && !current

      parents = amend ? current.parents : previous ? [previous] : []
      oid = write_commit(tree: write_tree_from_index, parents: parents, author: author, message: message)
      subject = message.lines.first.to_s.strip
      action = if amend
        "commit (amend): #{subject}"
      elsif previous
        "commit: #{subject}"
      else
        "commit (initial): #{subject}"
      end
      update_ref("HEAD", oid, old_oid: previous, message: action)
      oid
    end

    private

    def write_index_tree(node)
      entries = node.map do |name, value|
        if value.is_a?(Hash)
          TreeEntry.new(path: name, oid: write_index_tree(value), mode: 0o040000)
        else
          TreeEntry.new(path: name, oid: value.oid, mode: value.mode)
        end
      end
      write_tree(entries)
    end
  end
end
