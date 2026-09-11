# frozen_string_literal: true

require_relative "pack"

module Thuban
  class ObjectDatabase
    attr_reader :directory

    def initialize(directory)
      @directory = File.expand_path(directory)
      @packs = nil
    end

    def self.hash(type, data) = Digest::SHA1.hexdigest("#{type} #{data.bytesize}\0".b + data.b)

    def read(oid, seen = [])
      raise ArgumentError, "expected a full SHA-1 object id" unless /\A[0-9a-f]{40}\z/.match?(oid.to_s)
      raise CorruptObject, "cyclic object reference" if seen.include?(oid) || seen.length > 128
      loose = File.join(directory, oid[0, 2], oid[2..])
      object = if File.file?(loose)
        inflated = Zlib::Inflate.inflate(File.binread(loose))
        header, data = inflated.split("\0", 2)
        type, size = header.split(" ", 2)
        raise CorruptObject, "invalid loose object header" unless %w[commit tree blob tag].include?(type) && size&.match?(/\A\d+\z/) && data && data.bytesize == size.to_i
        [type, data]
      else
        pack = packs.find { |entry| entry.include?(oid) }
        unless pack
          @packs = nil # New packs may appear during background GC.
          pack = packs.find { |entry| entry.include?(oid) }
        end
        raise KeyError, "Git object not found: #{oid}" unless pack
        pack.read(oid) { |base| read(base, seen + [oid]) }
      end
      raise CorruptObject, "object SHA-1 mismatch: #{oid}" unless self.class.hash(*object) == oid
      object
    rescue Zlib::Error => error
      raise CorruptObject, error.message
    end

    def packs = @packs ||= Dir[File.join(directory, "pack", "*.idx")].sort.map { |path| Pack.new(path) }
  end
end
