# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class PackWriterTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-pack-write-")
    git("init", "-q", "--bare")
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_writes_a_pack_that_git_can_index_verify_and_use
    objects, commit_oid = fixture_objects
    progress = []
    temporary = File.join(@directory, "objects", "pack", "incoming.pack")
    checksum = File.open(temporary, "wb") do |file|
      Thuban::Pack.write(file, objects) { |current, total| progress << [current, total] }
    end

    assert_equal objects.length.times.map { |index| [index + 1, objects.length] }, progress
    assert_equal checksum, git("index-pack", "--strict", temporary).strip
    index = temporary.sub(/\.pack\z/, ".idx")
    verify, error, status = Open3.capture3("git", "verify-pack", "-v", index, binmode: true)
    assert status.success?, error
    objects.each do |type, data|
      oid = Thuban::ObjectDatabase.hash(type, data)
      assert_match(/^#{oid} #{type} /, verify)
      assert_equal data, git("cat-file", type, oid)
    end
    FileUtils.mkdir_p(File.join(@directory, "refs", "heads"))
    File.binwrite(File.join(@directory, "refs", "heads", "main"), "#{commit_oid}\n")
    File.binwrite(File.join(@directory, "HEAD"), "ref: refs/heads/main\n")
    assert_git_fsck
  end

  def test_returns_the_trailing_checksum_and_supports_partial_writes
    output = PartialWriter.new
    checksum = Thuban::Pack.write(output, [["blob", "content\n"]])

    assert_equal checksum, output.bytes[-20, 20].unpack1("H*")
    assert_equal Digest::SHA1.hexdigest(output.bytes[0...-20]), checksum
  end

  def test_validates_every_object_before_writing
    output = StringIO.new("".b)
    assert_raises(ArgumentError) { Thuban::Pack.write(output, [["blob", "ok"], ["invalid", "bad"]]) }
    assert_empty output.string
    assert_raises(TypeError) { Thuban::Pack.write(output, nil) }
    assert_raises(TypeError) { Thuban::Pack.write(Object.new, []) }
  end

  private

  class PartialWriter
    attr_reader :bytes

    def initialize = @bytes = +"".b

    def write(data)
      length = [data.bytesize, 3].min
      bytes << data.byteslice(0, length)
      length
    end
  end

  def fixture_objects
    blob = "packed contents\n".b
    blob_oid = Thuban::ObjectDatabase.hash("blob", blob)
    tree = "100644 file.txt\0".b + [blob_oid].pack("H*")
    tree_oid = Thuban::ObjectDatabase.hash("tree", tree)
    commit = "tree #{tree_oid}\nauthor Fixture <fixture@example.invalid> 1700000000 +0000\n" \
      "committer Fixture <fixture@example.invalid> 1700000000 +0000\n\nPacked commit\n"
    commit_oid = Thuban::ObjectDatabase.hash("commit", commit)
    tag = "object #{commit_oid}\ntype commit\ntag packed\ntagger Fixture <fixture@example.invalid> 1700000000 +0000\n\nPacked tag\n"
    [[["blob", blob], ["tree", tree], ["commit", commit], ["tag", tag]], commit_oid]
  end

  def git(*arguments)
    output, error, status = Open3.capture3("git", "-C", @directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end

  def assert_git_fsck
    output, status = Open3.capture2e("git", "-C", @directory, "fsck", "--strict")
    assert status.success?, output
  end
end
