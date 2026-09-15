# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/http_fixture"
require "stringio"

class RemoteProtocolTest < Minitest::Test
  Protocol = Thuban::Remote::Protocol
  OID = "1" * 40
  PEELED = "2" * 40

  def teardown
    @server&.close
  end

  def test_pkt_line_round_trip_and_control_packets
    source = StringIO.new(Protocol.packet("hello\n") + Protocol.delimiter + Protocol.flush)
    reader = Protocol::Reader.new(source, max_bytes: 64)
    assert_equal "hello\n", reader.read
    assert_equal Protocol::DELIMITER, reader.read
    assert_equal Protocol::FLUSH, reader.read
    assert_nil reader.read
    assert_equal "0004", Protocol.packet("")
  end

  def test_pkt_line_rejects_truncation_bad_lengths_and_limits
    ["0008abc", "0003", "zzzz"].each do |bytes|
      assert_raises(Thuban::TransportError) { Protocol::Reader.new(StringIO.new(bytes), max_bytes: 64).read }
    end
    packet = Protocol.packet("12345")
    assert_raises(Thuban::TransportError) { Protocol::Reader.new(StringIO.new(packet), max_bytes: 8).read }
    assert_raises(Thuban::TransportError) { Protocol.packet("x" * (Protocol::MAX_PACKET_SIZE - 3)) }
    %w[abc 00000000000000000000000000000000000000000].each do |oid|
      assert_raises(Thuban::TransportError) { Protocol.validate_oid(oid) }
    end
    assert_equal "a" * 40, Protocol.validate_oid("A" * 40)
  end

  def test_discovers_protocol_v2_symrefs_and_peeled_tags
    advertisement = service_advertisement("version 2\n", "ls-refs=unborn\n", "object-format=sha1\n")
    listed = packets("#{OID} HEAD symref-target:refs/heads/main\n", "#{OID} refs/heads/main\n",
      "#{OID} refs/tags/v1 peeled:#{PEELED}\n") + Protocol.flush
    @server = HTTPFixture.new do |request|
      if request[:path].include?("info/refs")
        assert_equal "version=2", request[:headers]["git-protocol"]
        [200, "application/x-git-upload-pack-advertisement", advertisement]
      else
        assert_includes request[:body], Protocol.packet("command=ls-refs\n")
        assert_includes request[:body], Protocol.packet("symrefs\n")
        [200, "application/x-git-upload-pack-result", listed]
      end
    end

    connection = Thuban::Remote.open(@server.url)
    refs = connection.refs
    assert_equal ["HEAD", "refs/heads/main", "refs/tags/v1"], refs.map(&:name)
    assert_equal "refs/heads/main", refs.first.symref_target
    assert_equal PEELED, refs.last.peeled
    assert_equal OID, refs.last.oid
  ensure
    connection&.close
  end

  def test_falls_back_to_protocol_v0_and_folds_peeled_refs
    first = "#{OID} HEAD\0multi_ack side-band-64k symref=HEAD:refs/heads/main object-format=sha1\n"
    advertisement = service_advertisement(first, "#{OID} refs/heads/main\n", "#{OID} refs/tags/v1\n",
      "#{PEELED} refs/tags/v1^{}\n")
    @server = HTTPFixture.new { [200, "application/x-git-upload-pack-advertisement", advertisement] }

    refs = Thuban::Remote.open(@server.url).refs
    assert_equal "refs/heads/main", refs.first.symref_target
    assert_equal PEELED, refs.last.peeled
  end

  def test_rejects_credentials_redirects_non_sha1_and_use_after_close
    assert_raises(Thuban::AuthenticationError) { Thuban::Remote.open("http://user:secret@example.invalid/repo.git") }
    assert_raises(Thuban::AuthenticationError) { Thuban::Remote.open("http://example.invalid/repo.git", credentials: Object.new) }
    assert_raises(ArgumentError) { Thuban::Remote.open("http://example.invalid/repo.git", timeout: 0) }

    @server = HTTPFixture.new { [302, "text/plain", "redirect"] }
    assert_raises(Thuban::TransportError) { Thuban::Remote.open(@server.url).refs }
    @server.close
    @server = HTTPFixture.new do
      body = service_advertisement("version 2\n", "ls-refs\n", "object-format=sha256\n")
      [200, "application/x-git-upload-pack-advertisement", body]
    end
    assert_raises(Thuban::TransportError) { Thuban::Remote.open(@server.url).refs }

    connection = Thuban::Remote.open(@server.url)
    connection.close
    assert_raises(Thuban::TransportError) { connection.refs }
  end

  def test_surfaces_protocol_errors_without_returning_server_refs
    body = service_advertisement("ERR repository unavailable\n")
    @server = HTTPFixture.new { [200, "application/x-git-upload-pack-advertisement", body] }

    error = assert_raises(Thuban::TransportError) { Thuban::Remote.open(@server.url).refs }
    assert_equal "repository unavailable", error.message
  end

  def test_enforces_http_timeout_authentication_and_declared_size
    @server = HTTPFixture.new do
      sleep 0.1
      [200, "application/x-git-upload-pack-advertisement", ""]
    end
    assert_raises(Thuban::TransportError) { Thuban::Remote.open(@server.url, timeout: 0.01).refs }
    @server.close

    @server = HTTPFixture.new { [401, "text/plain", "secret details"] }
    error = assert_raises(Thuban::AuthenticationError) { Thuban::Remote.open(@server.url).refs }
    refute_includes error.message, "secret"
    @server.close

    too_large = (Thuban::Remote::Connection::MAX_ADVERTISEMENT_SIZE + 1).to_s
    @server = HTTPFixture.new { [200, "application/x-git-upload-pack-advertisement", "", {"Content-Length" => too_large}] }
    assert_raises(Thuban::TransportError) { Thuban::Remote.open(@server.url).refs }
  end

  private

  def packets(*lines) = lines.map { |line| Protocol.packet(line) }.join
  def service_advertisement(*lines) = Protocol.packet("# service=git-upload-pack\n") + Protocol.flush + packets(*lines) + Protocol.flush

end
