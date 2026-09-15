# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/http_fixture"
require "stringio"

class RemoteFetchTest < Minitest::Test
  Protocol = Thuban::Remote::Protocol

  def setup
    @directory = Dir.mktmpdir("thuban-fetch-")
    @source = File.join(@directory, "source")
    @remote = File.join(@directory, "remote.git")
    @local = File.join(@directory, "local")
    git_in(@source, "init", "-q", "-b", "main")
    git_in(@source, "config", "user.name", "Fixture")
    git_in(@source, "config", "user.email", "fixture@example.invalid")
    write_source("file.txt", "first\n")
    git_in(@source, "add", ".")
    git_in(@source, "commit", "-qm", "First")
    @first = git_in(@source, "rev-parse", "HEAD").strip
    git_in(@source, "tag", "-a", "v1", "-m", "Version one")
    git_in(@directory, "clone", "-q", "--bare", @source, @remote)
    git_in(@local, "init", "-q", "-b", "main")
    @repository = Thuban::Repository.new(@local)
    @server = GitHTTPFixture.new(@directory)
  end

  def teardown
    @server&.close
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
  end

  def test_fetches_from_git_http_backend_and_reads_received_objects
    connection = Thuban::Remote.open(@server.url)
    refs = connection.refs
    head = refs.find { |ref| ref.name == "HEAD" }
    tag = refs.find { |ref| ref.name == "refs/tags/v1" }
    assert_equal "refs/heads/main", head.symref_target
    assert_equal @first, head.oid
    assert_equal @first, tag.peeled

    received = connection.fetch(@repository, wants: [@first])
    assert_includes received, @first
    assert_equal "First", @repository.commit(@first).message.strip
    assert_equal "first\n", @repository.blob("file.txt", reference: @first)
    assert_git_fsck(@local)
    request = @server.requests.reverse.find { |entry| entry[:method] == "POST" && entry[:body].include?("want #{@first}") }
    assert_includes request[:body], Protocol.packet("want #{@first}\n")
    assert_includes request[:body], Protocol.packet("done\n")
  ensure
    connection&.close
  end

  def test_fetches_from_git_http_backend_protocol_v0
    @server.close
    @server = GitHTTPFixture.new(@directory, protocol: nil)
    connection = Thuban::Remote.open(@server.url)

    refs = connection.refs
    assert_equal @first, refs.find { |ref| ref.name == "refs/heads/main" }.oid
    assert_equal @first, refs.find { |ref| ref.name == "refs/tags/v1" }.peeled
    assert_includes connection.fetch(@repository, wants: [@first]), @first
    assert_equal "first\n", @repository.blob("file.txt", reference: @first)
    refute_includes @server.requests.last[:body], "command=fetch"
    assert_git_fsck(@local)
  ensure
    connection&.close
  end

  def test_sends_haves_and_fetches_only_the_incremental_history
    first_connection = Thuban::Remote.open(@server.url)
    first_connection.fetch(@repository, wants: [@first])
    first_connection.close
    write_source("file.txt", "second\n")
    git_in(@source, "commit", "-qam", "Second")
    second = git_in(@source, "rev-parse", "HEAD").strip
    git_in(@source, "push", "-q", @remote, "main")

    connection = Thuban::Remote.open(@server.url)
    received = connection.fetch(@repository, wants: [second], haves: [@first])
    assert_includes received, second
    assert_equal "second\n", @repository.blob("file.txt", reference: second)
    request = @server.requests.reverse.find { |entry| entry[:body].include?("want #{second}") }
    assert_includes request[:body], Protocol.packet("have #{@first}\n")
    assert_includes request[:body], Protocol.packet("done\n")
    assert_git_fsck(@local)
  ensure
    connection&.close
  end

  def test_protocol_v0_handles_nak_and_sideband_channels
    @server.close
    pack = StringIO.new(+"".b)
    oid = Thuban::ObjectDatabase.hash("blob", "remote blob")
    Thuban::Pack.write(pack, [["blob", "remote blob"]])
    advertisement = service_advertisement("#{oid} refs/heads/main\0side-band-64k no-progress ofs-delta object-format=sha1\n")
    response = Protocol.packet("NAK\n") + Protocol.packet("\2counting objects\n") +
      Protocol.packet("\1#{pack.string.byteslice(0, 10)}") + Protocol.packet("\1#{pack.string.byteslice(10..)}") + Protocol.flush
    @server = HTTPFixture.new do |request|
      request[:method] == "GET" ? [200, "application/x-git-upload-pack-advertisement", advertisement] :
        [200, "application/x-git-upload-pack-result", response]
    end

    have = @repository.write_blob("local blob")
    received = Thuban::Remote.open(@server.url).fetch(@repository, wants: [oid], haves: [have])
    assert_equal [oid], received
    assert_equal ["blob", "remote blob"], @repository.odb.read(oid)
    fetch_request = @server.requests.last[:body]
    assert_includes fetch_request, Protocol.packet("want #{oid} no-progress side-band-64k ofs-delta\n")
    assert_includes fetch_request, Protocol.packet("have #{have}\n")
    assert_includes fetch_request, Protocol.packet("done\n")
  end

  def test_protocol_and_sideband_errors_do_not_install_objects
    [Protocol.packet("ERR denied\n"), Protocol.packet("NAK\n") + Protocol.packet("\3failed\n")].each do |response|
      @server.close
      oid = "b" * 40
      advertisement = service_advertisement("#{oid} refs/heads/main\0side-band-64k object-format=sha1\n")
      @server = HTTPFixture.new do |request|
        request[:method] == "GET" ? [200, "application/x-git-upload-pack-advertisement", advertisement] :
          [200, "application/x-git-upload-pack-result", response]
      end

      assert_raises(Thuban::TransportError) { Thuban::Remote.open(@server.url).fetch(@repository, wants: [oid]) }
      refute @repository.odb.exist?(oid)
    end
  end

  def test_rejects_a_pack_that_does_not_supply_the_wanted_object
    @server.close
    wanted = "b" * 40
    pack = StringIO.new(+"".b)
    Thuban::Pack.write(pack, [["blob", "unrelated"]])
    advertisement = service_advertisement("#{wanted} refs/heads/main\0object-format=sha1\n")
    response = Protocol.packet("NAK\n") + pack.string
    @server = HTTPFixture.new do |request|
      request[:method] == "GET" ? [200, "application/x-git-upload-pack-advertisement", advertisement] :
        [200, "application/x-git-upload-pack-result", response]
    end

    error = assert_raises(Thuban::TransportError) do
      Thuban::Remote.open(@server.url).fetch(@repository, wants: [wanted])
    end
    assert_match(/requested objects/, error.message)
    refute @repository.odb.exist?(wanted)
  end

  def test_validates_negotiation_before_network_or_disk_changes
    connection = Thuban::Remote.open(@server.url)
    assert_raises(ArgumentError) { connection.fetch(@repository, wants: []) }
    assert_raises(Thuban::TransportError) { connection.fetch(@repository, wants: ["f" * 39]) }
    assert_raises(ArgumentError) { connection.fetch(@repository, wants: [@first], haves: ["f" * 40]) }
    assert_raises(ArgumentError) { connection.fetch(@repository, wants: [@first], depth: 1) }
    assert_raises(ArgumentError) { connection.fetch(@repository, wants: [@first], filter: "blob:none") }
    too_many = (0..Thuban::Remote::Connection::MAX_NEGOTIATION_OIDS).lazy.map { |number| format("%040x", number) }
    assert_raises(ArgumentError) { connection.fetch(@repository, wants: too_many) }
    assert_empty @server.requests
  ensure
    connection&.close
  end

  def test_repository_fetch_reads_remote_config_and_updates_tracking_refs
    git_in(@local, "remote", "add", "origin", @server.url)
    assert_equal({"origin" => @server.url}, @repository.remotes)

    advertised = @repository.fetch
    assert_equal @first, advertised.find { |ref| ref.name == "refs/heads/main" }.oid
    assert_equal @first, @repository.resolve("refs/remotes/origin/main")
    assert_equal "first\n", @repository.blob("file.txt", reference: "refs/remotes/origin/main")
    assert_git_fsck(@local)
  end

  def test_repository_fetch_accepts_a_direct_url_without_creating_tracking_refs
    advertised = @repository.fetch(@server.url)

    assert_equal @first, advertised.find { |ref| ref.name == "refs/heads/main" }.oid
    assert_empty @repository.refs
    assert @repository.odb.exist?(@first)
  end

  def test_repository_fetch_validates_refspecs_before_connecting
    git_in(@local, "remote", "add", "origin", @server.url)

    assert_raises(ArgumentError) { @repository.fetch(refspecs: "refs/heads/*:refs/remotes/origin/../*") }
    assert_empty @server.requests
  end

  def test_repository_fetch_does_not_overwrite_a_concurrent_ref_update
    git_in(@local, "remote", "add", "origin", @server.url)
    destination = "refs/remotes/origin/main"
    old = @repository.write_blob("old")
    wanted = @repository.write_blob("wanted")
    concurrent = @repository.write_blob("concurrent")
    @repository.update_ref(destination, old)
    connection = Object.new
    connection.define_singleton_method(:refs) { [Thuban::Ref.new(name: "refs/heads/main", oid: wanted)] }
    connection.define_singleton_method(:fetch) do |repository, **|
      repository.update_ref(destination, concurrent, old_oid: old)
    end
    connection.define_singleton_method(:close) {}

    assert_raises(Thuban::RefLockError) do
      Thuban::Remote.stub(:open, connection) { @repository.fetch }
    end
    assert_equal concurrent, @repository.resolve(destination)
  end

  private

  def service_advertisement(*lines)
    Protocol.packet("# service=git-upload-pack\n") + Protocol.flush + lines.map { |line| Protocol.packet(line) }.join + Protocol.flush
  end

  def write_source(path, contents)
    absolute = File.join(@source, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.binwrite(absolute, contents)
  end

  def git_in(directory, *arguments)
    FileUtils.mkdir_p(directory) unless File.exist?(directory)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end

  def assert_git_fsck(directory)
    output, status = Open3.capture2e("git", "-C", directory, "fsck", "--strict")
    assert status.success?, output
  end
end
