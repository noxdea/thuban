# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/http_fixture"
require "stringio"
require "timeout"

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
    progress = []
    received = Thuban::Remote.open(@server.url).fetch(@repository, wants: [oid], haves: [have]) { |event| progress << event }
    assert_equal [oid], received
    assert_equal ["blob", "remote blob"], @repository.odb.read(oid)
    assert_includes progress.map(&:phase), :remote
    assert_includes progress.map(&:phase), :pack
    assert progress.select { |event| event.phase == :remote }.all? { |event| event.bytes <= Protocol::MAX_PACKET_SIZE }
    assert progress.select { |event| event.phase == :pack }.all? { |event| event.bytes <= Thuban::Pack::MAX_PACK_SIZE }
    fetch_request = @server.requests.last[:body]
    assert_includes fetch_request, Protocol.packet("want #{oid} side-band-64k ofs-delta\n")
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
    [-1, 0, 2_147_483_648, 1.0, "1"].each do |depth|
      assert_raises(ArgumentError) { connection.fetch(@repository, wants: [@first], depth: depth) }
    end
    ["blob:limit=1", "tree:0", :blob_none].each do |filter|
      assert_raises(ArgumentError) { connection.fetch(@repository, wants: [@first], filter: filter) }
    end
    too_many = (0..Thuban::Remote::Connection::MAX_NEGOTIATION_OIDS).lazy.map { |number| format("%040x", number) }
    assert_raises(ArgumentError) { connection.fetch(@repository, wants: too_many) }
    assert_empty @server.requests
  ensure
    connection&.close
  end

  def test_fetches_shallow_history_and_persists_git_compatible_boundary
    head, parent = add_remote_history
    connection = Thuban::Remote.open(@server.url)
    progress = []

    received = connection.fetch(@repository, wants: [head], depth: 1) { |event| progress << event }

    assert_includes received, head
    assert @repository.odb.exist?(head)
    refute @repository.odb.exist?(parent)
    assert_equal "#{head}\n", File.binread(File.join(@repository.common_dir, "shallow"))
    assert_equal "true\n", git_in(@local, "rev-parse", "--is-shallow-repository")
    assert_includes progress.map(&:phase), :pack
    request = @server.requests.reverse.find { |entry| entry[:method] == "POST" }
    assert_includes request[:body], Protocol.packet("deepen 1\n")
  ensure
    connection&.close
  end

  def test_deepens_and_updates_an_existing_shallow_boundary
    head, parent = add_remote_history
    connection = Thuban::Remote.open(@server.url)
    connection.fetch(@repository, wants: [head], depth: 1)
    connection.close
    connection = Thuban::Remote.open(@server.url)

    connection.fetch(@repository, wants: [head], haves: [head], depth: 2)

    assert @repository.odb.exist?(parent)
    assert_equal "#{parent}\n", File.binread(File.join(@repository.common_dir, "shallow"))
    request = @server.requests.reverse.find { |entry| entry[:method] == "POST" }
    assert_includes request[:body], Protocol.packet("shallow #{head}\n")
    assert_includes request[:body], Protocol.packet("deepen 2\n")
  ensure
    connection&.close
  end

  def test_removes_the_shallow_file_when_the_server_unshallows_every_boundary
    head, parent = add_remote_history
    connection = Thuban::Remote.open(@server.url)
    connection.fetch(@repository, wants: [head], depth: 1)
    connection.close
    connection = Thuban::Remote.open(@server.url)

    connection.fetch(@repository, wants: [head], haves: [head], depth: 2_147_483_647)

    assert @repository.odb.exist?(parent)
    refute File.exist?(File.join(@repository.common_dir, "shallow"))
    assert_equal "false\n", git_in(@local, "rev-parse", "--is-shallow-repository")
  ensure
    connection&.close
  end

  def test_protocol_v2_rejects_a_missing_section_delimiter
    connection = Thuban::Remote::Connection.allocate
    connection.instance_variable_set(:@closed, false)
    connection.instance_variable_set(:@protocol_version, 2)
    oid = "a" * 40
    response = Protocol.packet("shallow-info\n") + Protocol.packet("shallow #{oid}\n") +
      Protocol.packet("packfile\n") + Protocol.packet("\1PACK") + Protocol.flush

    error = assert_raises(Thuban::TransportError) do
      connection.send(:extract_fetch_response, StringIO.new(response), StringIO.new(+"".b), allow_shallow: true)
    end
    assert_equal "invalid fetch response section", error.message
  end

  def test_protocol_v2_rejects_data_after_the_response_terminator
    connection = Thuban::Remote::Connection.allocate
    connection.instance_variable_set(:@closed, false)
    connection.instance_variable_set(:@protocol_version, 2)
    pack = StringIO.new(+"".b)
    Thuban::Pack.write(pack, [["blob", "remote blob"]])
    response = Protocol.packet("packfile\n") + Protocol.packet("\1#{pack.string}") + Protocol.flush +
      Protocol.packet("trailing\n")

    error = assert_raises(Thuban::TransportError) do
      connection.send(:extract_fetch_response, StringIO.new(response), StringIO.new(+"".b))
    end
    assert_equal "fetch response continued after its terminator", error.message
  end

  def test_rejects_a_non_file_shallow_boundary_store
    FileUtils.mkdir_p(File.join(@repository.common_dir, "shallow"))
    connection = Thuban::Remote::Connection.allocate

    error = assert_raises(Thuban::CorruptObject) { connection.send(:read_shallow, @repository) }
    assert_equal "unsafe shallow file", error.message
  end

  def test_fetches_blobless_history_and_records_promisor_remote
    head, = add_remote_history
    blob = git_in(@source, "rev-parse", "#{head}:file.txt").strip
    git_in(@remote, "config", "uploadpack.allowFilter", "true")
    git_in(@local, "remote", "add", "origin", @server.url)
    config = File.join(@repository.common_dir, "config")
    File.binwrite(config, File.binread(config).chomp)
    File.chmod(0o600, config)
    progress = []

    @repository.fetch(filter: "blob:none") { |event| progress << event }

    assert @repository.odb.exist?(head)
    refute @repository.odb.exist?(blob)
    assert_raises(KeyError) { @repository.odb.read(blob) }
    assert_equal "true\n", git_in(@local, "config", "--get", "remote.origin.promisor")
    assert_equal "blob:none\n", git_in(@local, "config", "--get", "remote.origin.partialclonefilter")
    assert_equal 0o600, File.stat(config).mode & 0o777 unless Gem.win_platform?
    assert_includes progress.map(&:phase), :pack
    request = @server.requests.reverse.find { |entry| entry[:method] == "POST" }
    assert_includes request[:body], Protocol.packet("filter blob:none\n")
    assert_equal "third\n", git_in(@local, "cat-file", "-p", blob)
    assert @repository.odb.exist?(blob)
  end

  def test_protocol_v0_negotiates_shallow_and_partial_fetch
    head, parent = add_remote_history
    blob = git_in(@source, "rev-parse", "#{head}:file.txt").strip
    git_in(@remote, "config", "uploadpack.allowFilter", "true")
    @server.close
    @server = GitHTTPFixture.new(@directory, protocol: nil)
    connection = Thuban::Remote.open(@server.url)

    connection.fetch(@repository, wants: [head], depth: 1, filter: "blob:none")

    refute @repository.odb.exist?(parent)
    refute @repository.odb.exist?(blob)
    assert_equal "#{head}\n", File.binread(File.join(@repository.common_dir, "shallow"))
    request = @server.requests.reverse.find { |entry| entry[:method] == "POST" }
    assert_includes request[:body], " filter\n"
    assert_includes request[:body], Protocol.packet("deepen 1\n")
    assert_includes request[:body], Protocol.packet("filter blob:none\n")
  ensure
    connection&.close
  end

  def test_rejects_unadvertised_fetch_features_and_malformed_shallow_info
    @server.close
    oid = "b" * 40
    advertisement = service_advertisement("#{oid} refs/heads/main\0side-band-64k object-format=sha1\n")
    @server = HTTPFixture.new do |request|
      [200, request[:method] == "GET" ? "application/x-git-upload-pack-advertisement" :
        "application/x-git-upload-pack-result", advertisement]
    end
    connection = Thuban::Remote.open(@server.url)
    connection.refs

    assert_raises(Thuban::TransportError) { connection.fetch(@repository, wants: [oid], depth: 1) }
    assert_raises(Thuban::TransportError) { connection.fetch(@repository, wants: [oid], filter: "blob:none") }
    assert_equal 1, @server.requests.length

    @server.close
    pack = StringIO.new(+"".b)
    Thuban::Pack.write(pack, [["blob", "remote blob"]])
    advertisement = service_advertisement("#{oid} refs/heads/main\0shallow object-format=sha1\n")
    response = Protocol.packet("shallow not-an-oid\n") + Protocol.flush + Protocol.packet("NAK\n") + pack.string
    @server = HTTPFixture.new do |request|
      request[:method] == "GET" ? [200, "application/x-git-upload-pack-advertisement", advertisement] :
        [200, "application/x-git-upload-pack-result", response]
    end
    assert_raises(Thuban::TransportError) do
      Thuban::Remote.open(@server.url).fetch(@repository, wants: [oid], depth: 1)
    end
    refute File.exist?(File.join(@repository.common_dir, "shallow"))
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

  def test_repository_fetch_accepts_direct_local_and_file_remotes
    path = File.expand_path(@remote).tr("\\", "/")
    path = "/#{path}" if path.match?(/\A[A-Za-z]:\//)
    [@remote, URI::Generic.build(scheme: "file", path: path).to_s].each_with_index do |remote, index|
      local = File.join(@directory, "direct-#{index}")
      git_in(local, "init", "-q", "-b", "main")
      repository = Thuban::Repository.new(local)

      refs = repository.fetch(remote)

      assert_equal @first, refs.find { |ref| ref.name == "refs/heads/main" }.oid
      assert repository.odb.exist?(@first)
      assert_empty repository.refs
    end
  end

  def test_repository_fetch_resolves_relative_local_remotes_from_the_repository
    refs = @repository.fetch("../remote.git")

    assert_equal @first, refs.find { |ref| ref.name == "refs/heads/main" }.oid
    assert @repository.odb.exist?(@first)
  end

  def test_partial_fetch_does_not_publish_a_ref_without_promisor_configuration
    git_in(@local, "remote", "add", "origin", @server.url)
    wanted = @repository.write_blob("wanted")
    connection = Object.new
    connection.define_singleton_method(:refs) { [Thuban::Ref.new(name: "refs/heads/main", oid: wanted)] }
    connection.define_singleton_method(:fetch) { |*, **| [] }
    connection.define_singleton_method(:close) {}
    lock = File.join(@repository.common_dir, "config.lock")
    File.binwrite(lock, "held")

    assert_raises(Thuban::RefLockError) do
      Thuban::Remote.stub(:open, connection) { @repository.fetch(filter: "blob:none") }
    end
    assert_nil @repository.resolve("refs/remotes/origin/main")
    assert_equal "held", File.binread(lock)
  ensure
    File.unlink(lock) if lock && File.exist?(lock)
  end

  def test_partial_fetch_does_not_publish_a_ref_after_remote_configuration_changes
    git_in(@local, "remote", "add", "origin", @server.url)
    wanted = @repository.write_blob("wanted")
    local = @local
    connection = Object.new
    connection.define_singleton_method(:refs) { [Thuban::Ref.new(name: "refs/heads/main", oid: wanted)] }
    connection.define_singleton_method(:fetch) do |*, **|
      system("git", "-C", local, "config", "--remove-section", "remote.origin") || raise("config update failed")
      []
    end
    connection.define_singleton_method(:close) {}

    error = assert_raises(Thuban::RefLockError) do
      Thuban::Remote.stub(:open, connection) { @repository.fetch(filter: "blob:none") }
    end
    assert_equal "remote configuration changed during fetch", error.message
    assert_nil @repository.resolve("refs/remotes/origin/main")
    refute File.exist?(File.join(@repository.common_dir, "config.lock"))
  end

  def test_cancel_at_the_end_of_pack_ingestion_prevents_shallow_state_update
    head, = add_remote_history
    connection = Thuban::Remote.open(@server.url)

    error = assert_raises(Thuban::TransportError) do
      connection.fetch(@repository, wants: [head], depth: 1) do |event|
        connection.close if event.phase == :pack && event.current == event.total
      end
    end

    assert_equal "connection is closed", error.message
    refute File.exist?(File.join(@repository.common_dir, "shallow"))
  ensure
    connection&.close
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

  def test_repository_fetch_forwards_transfer_controls_and_closes
    git_in(@local, "remote", "add", "origin", @server.url)
    wanted = @repository.write_blob("wanted")
    events = []
    connection = Object.new
    connection.define_singleton_method(:refs) { [Thuban::Ref.new(name: "refs/heads/main", oid: wanted)] }
    connection.define_singleton_method(:fetch) do |repository, **options, &progress|
      events << [repository, options]
      progress.call(Thuban::Progress.new(phase: :pack, current: 1, total: 1, bytes: 1))
      []
    end
    connection.define_singleton_method(:close) { events << :closed }
    credentials = Object.new
    opened = nil
    opener = lambda do |url, **options|
      opened = [url, options]
      connection
    end

    Thuban::Remote.stub(:open, opener) do
      @repository.fetch(credentials: credentials, ssh: ["ssh", "-F", "safe"], timeout: 7) { |event| events << event }
    end

    assert_equal [@server.url, {credentials: credentials, ssh: ["ssh", "-F", "safe"], timeout: 7}], opened
    assert_equal({wants: [wanted], haves: [], depth: nil, filter: nil}, events[0][1])
    assert_instance_of Thuban::Progress, events[1]
    assert_equal :closed, events.last
  end

  def test_cancelled_final_progress_does_not_publish_config_or_refs
    git_in(@local, "remote", "add", "origin", @server.url)
    original_config = File.binread(File.join(@repository.common_dir, "config"))
    wanted = @repository.write_blob("wanted")
    cancelled = false
    closes = 0
    connection = Object.new
    connection.define_singleton_method(:refs) { [Thuban::Ref.new(name: "refs/heads/main", oid: wanted)] }
    connection.define_singleton_method(:fetch) do |*, **, &progress|
      progress.call(Thuban::Progress.new(phase: :pack, current: 1, total: 1, bytes: 1))
      []
    end
    connection.define_singleton_method(:close) { closes += 1 }

    error = assert_raises(Thuban::Cancelled) do
      Thuban::Remote.stub(:open, connection) do
        @repository.fetch(filter: "blob:none", cancelled: -> { cancelled }) { cancelled = true }
      end
    end

    assert_equal "transfer cancelled", error.message
    assert_equal 1, closes
    assert_nil @repository.resolve("refs/remotes/origin/main")
    assert_equal original_config, File.binread(File.join(@repository.common_dir, "config"))
  end

  def test_cancelled_blocked_http_fetch_is_bounded_and_does_not_publish
    started = Queue.new
    release = Queue.new
    blocked = HTTPFixture.new do |_request|
      started << true
      release.pop
      [500, "text/plain", "released"]
    end
    original_config = File.binread(File.join(@repository.common_dir, "config"))
    cancelled = false
    operation = Thread.new do
      @repository.fetch(blocked.url, filter: "blob:none", cancelled: -> { cancelled })
    rescue StandardError => error
      error
    end
    Timeout.timeout(2) { started.pop }
    cancelled = true

    error = Timeout.timeout(2) { operation.value }

    assert_instance_of Thuban::Cancelled, error
    assert_nil @repository.resolve("refs/remotes/origin/main")
    assert_equal original_config, File.binread(File.join(@repository.common_dir, "config"))
  ensure
    release&.push(true)
    operation&.join(2)
    blocked&.close
  end

  def test_repository_fetch_validates_cancellation_before_opening
    opened = false
    opener = ->(*) { opened = true }

    assert_raises(TypeError) { @repository.fetch(@server.url, cancelled: Object.new) }
    assert_raises(Thuban::Cancelled) do
      Thuban::Remote.stub(:open, opener) { @repository.fetch(@server.url, cancelled: -> { true }) }
    end
    refute opened
  end

  def test_cancellation_after_transport_close_does_not_publish_local_state
    git_in(@local, "remote", "add", "origin", @server.url)
    original_config = File.binread(File.join(@repository.common_dir, "config"))
    wanted = @repository.write_blob("wanted")
    cancelled = false
    connection = Object.new
    connection.define_singleton_method(:refs) { [Thuban::Ref.new(name: "refs/heads/main", oid: wanted)] }
    connection.define_singleton_method(:fetch) { |*, **| [] }
    connection.define_singleton_method(:close) { cancelled = true }

    assert_raises(Thuban::Cancelled) do
      Thuban::Remote.stub(:open, connection) do
        @repository.fetch(filter: "blob:none", cancelled: -> { cancelled })
      end
    end

    assert_nil @repository.resolve("refs/remotes/origin/main")
    assert_equal original_config, File.binread(File.join(@repository.common_dir, "config"))
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

  def add_remote_history
    write_source("file.txt", "second\n")
    git_in(@source, "commit", "-qam", "Second")
    parent = git_in(@source, "rev-parse", "HEAD").strip
    write_source("file.txt", "third\n")
    git_in(@source, "commit", "-qam", "Third")
    head = git_in(@source, "rev-parse", "HEAD").strip
    git_in(@source, "push", "-q", @remote, "main")
    [head, parent]
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
