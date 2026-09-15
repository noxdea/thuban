# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class PackReaderTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-pack-read-")
    @objects = File.join(@directory, "objects")
    FileUtils.mkdir_p(@objects)
    @odb = Thuban::ObjectDatabase.new(@objects)
  end

  def teardown = FileUtils.remove_entry(@directory)

  def test_expands_a_pack_written_by_thuban
    entries = [["blob", "one\n"], ["blob", "two\n"]]
    stream = StringIO.new(+"".b)
    Thuban::Pack.write(stream, entries)
    stream.rewind
    progress = []

    oids = Thuban::Pack.read_stream(stream, @odb) { |current, total| progress << [current, total] }
    assert_equal entries.map { |type, data| Thuban::ObjectDatabase.hash(type, data) }, oids
    assert_equal [[1, 2], [2, 2]], progress
    entries.zip(oids).each { |object, oid| assert_equal object, @odb.read(oid) }
  end

  def test_expands_git_delta_packs_into_readable_objects
    source = File.join(@directory, "source")
    git_in(source, "init", "-q", "-b", "main")
    git_in(source, "config", "user.name", "Fixture")
    git_in(source, "config", "user.email", "fixture@example.invalid")
    12.times do |number|
      lines = Array.new(400) { |line| "#{line}: stable text #{line == number ? number : 0}\n" }.join
      File.binwrite(File.join(source, "large.txt"), lines)
      git_in(source, "add", ".")
      git_in(source, "commit", "-qm", "Revision #{number}")
    end
    pack = git_in(source, "pack-objects", "--stdout", "--revs", "--all", "--window=50", "--depth=50")
    pack_path = File.join(@directory, "source.pack")
    File.binwrite(pack_path, pack)
    git_in(source, "index-pack", pack_path)
    verified = git_in(source, "verify-pack", "-v", pack_path.sub(/\.pack\z/, ".idx"))
    assert verified.lines.any? { |line| line.split.length >= 7 }, "fixture did not contain a delta"

    expected = git_in(source, "rev-list", "--objects", "--all").lines.map { |line| line.split.first }
    received = Thuban::Pack.read_stream(StringIO.new(pack), @odb)
    assert_equal expected.sort, received.sort
    expected.each do |oid|
      type = git_in(source, "cat-file", "-t", oid).strip
      assert_equal [type, git_in(source, "cat-file", type, oid)], @odb.read(oid)
    end
  end

  def test_rejects_checksums_truncation_counts_and_stream_limits
    stream = StringIO.new(+"".b)
    Thuban::Pack.write(stream, [["blob", "valid"]])
    corrupt = stream.string.dup
    corrupt.setbyte(-1, corrupt.getbyte(-1) ^ 1)
    assert_raises(Thuban::CorruptObject) { Thuban::Pack.read_stream(StringIO.new(corrupt), @odb) }
    assert_raises(Thuban::CorruptObject) { Thuban::Pack.read_stream(StringIO.new("PACK"), @odb) }

    header = "PACK" + [2, Thuban::Pack::MAX_PACK_OBJECTS + 1].pack("N2")
    excessive = header + Digest::SHA1.digest(header)
    error = assert_raises(Thuban::CorruptObject) { Thuban::Pack.read_stream(StringIO.new(excessive), @odb) }
    assert_match(/count exceeds limit/, error.message)

    assert_raises(Thuban::CorruptObject) do
      Thuban::Pack.send(:copy_stream, StringIO.new("12345"), StringIO.new(+"".b), 4)
    end
    record = {offset: 12, type: "blob", data: "12345"}
    assert_raises(Thuban::CorruptObject) { Thuban::Pack.send(:resolve_record, record, {}, @odb, 4) }
    stalled = Object.new
    stalled.define_singleton_method(:read) { |_length| "" }
    assert_raises(Thuban::CorruptObject) { Thuban::Pack.read_stream(stalled, @odb) }
  end

  def test_resolves_reverse_reference_delta_chains_once_per_record
    contents = Array.new(33) { |index| format("%04d", index) }
    records = (1...contents.length).reverse_each.map do |index|
      delta = [contents[index - 1].bytesize, contents[index].bytesize, contents[index].bytesize].pack("C*") + contents[index]
      Thuban::Pack.send(:encode_object_header, 7, delta.bytesize) +
        [Thuban::ObjectDatabase.hash("blob", contents[index - 1])].pack("H*") + Zlib::Deflate.deflate(delta)
    end
    records << Thuban::Pack.send(:encode_object_header, 3, contents.first.bytesize) + Zlib::Deflate.deflate(contents.first)
    body = "PACK".b + [2, records.length].pack("N2") + records.join
    pack = body + Digest::SHA1.digest(body)
    calls = 0
    trace = TracePoint.new(:call) do |event|
      calls += 1 if event.defined_class == Thuban::Pack.singleton_class && event.method_id == :resolve_record
    end

    received = trace.enable { Thuban::Pack.read_stream(StringIO.new(pack), @odb) }
    assert_equal contents.map { |content| Thuban::ObjectDatabase.hash("blob", content) }.sort, received.sort
    assert_operator calls, :<=, contents.length * 2
  end

  private

  def git_in(directory, *arguments)
    FileUtils.mkdir_p(directory) unless File.exist?(directory)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end
end
