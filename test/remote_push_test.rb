# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/http_fixture"
require "json"
require "rbconfig"
require "shellwords"
require "timeout"
require "uri"

class RemotePushTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-push-")
    @source = File.join(@directory, "source")
    @remote = File.join(@directory, "remote.git")
    git_in(@source, "init", "-q", "-b", "main")
    git_in(@source, "config", "user.name", "Fixture")
    git_in(@source, "config", "user.email", "fixture@example.invalid")
    commit("first\n", "First")
    @first = git_in(@source, "rev-parse", "HEAD").strip
    git_in(@remote, "init", "-q", "--bare")
    @repository = Thuban::Repository.new(@source)
  end

  def teardown
    @server&.close
    ENV["THUBAN_SSH_LOG"] = @previous_log if defined?(@previous_log)
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
  end

  def test_pushes_to_local_and_file_remotes_with_progress
    git_in(@source, "remote", "add", "origin", @remote)
    progress = []
    result = @repository.push("origin", refspecs: "refs/heads/main:refs/heads/main") { |event| progress << event }

    assert_equal [["refs/heads/main", @first]], result.map { |ref| [ref.name, ref.oid] }
    assert_equal @first, git_in(@remote, "rev-parse", "refs/heads/main").strip
    assert_includes progress.map(&:phase), :pack
    assert_includes progress.map(&:phase), :push
    assert_git_fsck(@remote)

    second_remote = File.join(@directory, "second.git")
    git_in(second_remote, "init", "-q", "--bare")
    url = file_url(second_remote)
    @repository.push(url, refspecs: "refs/heads/main:refs/heads/copied")
    assert_equal @first, git_in(second_remote, "rev-parse", "refs/heads/copied").strip
    assert_git_fsck(second_remote)

    local = Thuban::Remote.open(File.join(@directory, "remote:with-colon.git"))
    assert_instance_of Thuban::Remote::LocalConnection, local
    local.close
    assert_raises(ArgumentError) { Thuban::Remote.open(@remote, timeout: 0) }
  end

  def test_pushes_pack_and_refspec_over_smart_http
    git_in(@remote, "config", "http.receivepack", "true")
    @server = GitHTTPFixture.new(@directory)

    @repository.push(@server.url, refspecs: "refs/heads/main:refs/heads/topic")

    assert_equal @first, git_in(@remote, "rev-parse", "refs/heads/topic").strip
    request = @server.requests.find { |entry| entry[:path] == "/remote.git/git-receive-pack" }
    assert_equal "POST", request[:method]
    assert_equal "application/x-git-receive-pack-request", request[:headers]["content-type"]
    assert_includes request[:body], "refs/heads/topic"
    assert_includes request[:body], "PACK"
    assert_git_fsck(@remote)
  end

  def test_sends_an_empty_pack_when_the_remote_already_has_the_objects
    @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/main")

    @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/copied")

    assert_equal @first, git_in(@remote, "rev-parse", "refs/heads/copied").strip
  end

  def test_negotiates_and_accepts_report_status_v2_options
    advertisement = Thuban::Remote::Protocol.packet("# service=git-receive-pack\n") +
      Thuban::Remote::Protocol.flush + Thuban::Remote::Protocol.packet(
        "#{"0" * 40} capabilities^{}\0report-status report-status-v2 delete-refs object-format=sha1\n"
      ) + Thuban::Remote::Protocol.flush
    result = %W[unpack\ ok ok\ refs/for/main option\ refname\ refs/heads/main
      option\ old-oid\ #{"0" * 40} option\ new-oid\ #{@first}].map do |line|
      Thuban::Remote::Protocol.packet("#{line}\n")
    end.join + Thuban::Remote::Protocol.flush
    @server = HTTPFixture.new do |request|
      if request[:method] == "GET"
        [200, "application/x-git-receive-pack-advertisement", advertisement]
      else
        assert_includes request[:body], "\0report-status-v2"
        [200, "application/x-git-receive-pack-result", result]
      end
    end

    pushed = @repository.push(@server.url, refspecs: "refs/heads/main:refs/for/main")

    assert_equal [["refs/for/main", @first]], pushed.map { |ref| [ref.name, ref.oid] }
  end

  def test_smart_http_push_uses_explicit_credentials_without_leaking_them
    git_in(@remote, "config", "http.receivepack", "true")
    @server = AuthGitHTTPFixture.new(@directory, "Basic #{["user:secret"].pack("m0")}")
    credentials = Thuban::Remote::Credentials.static(username: "user", password: "secret")
    connection = Thuban::Remote.open(@server.url, credentials: credentials)

    connection.push(@repository, [["refs/heads/main", "0" * 40, @first]])

    assert_equal @first, git_in(@remote, "rev-parse", "refs/heads/main").strip
    assert @server.requests.all? { |request| request[:headers]["authorization"] == "Basic #{["user:secret"].pack("m0")}" }
    refute_includes credentials.inspect, "secret"
  ensure
    connection&.close
  end

  def test_close_cancels_push_discovery
    started = Queue.new
    release = Queue.new
    advertisement = Thuban::Remote::Protocol.packet("# service=git-receive-pack\n") +
      Thuban::Remote::Protocol.flush + Thuban::Remote::Protocol.packet(
        "#{"0" * 40} capabilities^{}\0report-status delete-refs object-format=sha1\n"
      ) + Thuban::Remote::Protocol.flush
    @server = HTTPFixture.new do |_request|
      started << true
      release.pop
      [200, "application/x-git-receive-pack-advertisement", advertisement]
    end
    connection = Thuban::Remote.open(@server.url)
    operation = Thread.new do
      connection.push(@repository, [["refs/heads/main", "0" * 40, @first]])
    rescue Thuban::TransportError => error
      error
    end
    started.pop

    Timeout.timeout(2) { connection.close }
    error = Timeout.timeout(2) { operation.value }

    assert_instance_of Thuban::TransportError, error
  ensure
    release&.push(true)
    connection&.close
  end

  def test_pushes_over_ssh_receive_pack_without_a_local_shell
    log = File.join(@directory, "ssh.log")
    fake = File.join(@directory, "fake-ssh.rb")
    File.binwrite(fake, <<~'RUBY')
      require "json"
      require "shellwords"
      File.open(ENV.fetch("THUBAN_SSH_LOG"), "a") { |file| file.puts(JSON.generate(ARGV)) }
      service, path = Shellwords.split(ARGV.fetch(-1))
      path = path.delete_prefix("/") if Gem.win_platform? && path.match?(/\A\/[A-Za-z]:\//)
      abort "unexpected service" unless %w[git-upload-pack git-receive-pack].include?(service)
      exec(service, path)
    RUBY
    @previous_log = ENV["THUBAN_SSH_LOG"]
    ENV["THUBAN_SSH_LOG"] = log

    connection = Thuban::Remote.open("fixture@localhost:#{@remote}", ssh: [RbConfig.ruby, fake])
    connection.push(@repository, [["refs/heads/main", "0" * 40, @first]])

    assert_equal @first, git_in(@remote, "rev-parse", "refs/heads/main").strip
    invocations = File.readlines(log, chomp: true).map { |line| JSON.parse(line) }
    assert_equal 2, invocations.length
    assert invocations.all? { |arguments| Shellwords.split(arguments.last) == ["git-receive-pack", @remote] }
  ensure
    connection&.close
  end

  def test_reuses_a_connection_after_refreshing_receive_refs
    connection = Thuban::Remote.open(@remote)
    connection.push(@repository, [["refs/heads/main", nil, @first]])
    commit("second\n", "Second")
    second = git_in(@source, "rev-parse", "HEAD").strip

    connection.push(@repository, [["refs/heads/main", nil, second]])

    assert_equal second, git_in(@remote, "rev-parse", "refs/heads/main").strip
  ensure
    connection&.close
  end

  def test_push_discovery_does_not_replace_fetch_protocol_state
    git_in(@remote, "config", "http.receivepack", "true")
    @server = GitHTTPFixture.new(@directory)
    connection = Thuban::Remote.open(@server.url)
    connection.push(@repository, [["refs/heads/main", "0" * 40, @first]])

    connection.fetch(@repository, wants: [@first], haves: [@first])

    assert @server.requests.any? { |request| request[:path].include?("service=git-upload-pack") }
  ensure
    connection&.close
  end

  def test_rejects_non_fast_forward_and_honors_force_with_lease
    @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/main")
    commit("second\n", "Second")
    second = git_in(@source, "rev-parse", "HEAD").strip
    @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/main")
    git_in(@source, "reset", "--hard", "-q", @first)
    commit("diverged\n", "Diverged")
    diverged = git_in(@source, "rev-parse", "HEAD").strip

    error = assert_raises(Thuban::TransportError) do
      @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/main")
    end
    assert_match(/non-fast-forward/, error.message)
    assert_equal second, git_in(@remote, "rev-parse", "refs/heads/main").strip

    @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/main", lease: second)
    assert_equal diverged, git_in(@remote, "rev-parse", "refs/heads/main").strip
    assert_raises(Thuban::TransportError) do
      @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/main", lease: second)
    end
    assert_equal diverged, git_in(@remote, "rev-parse", "refs/heads/main").strip
  end

  def test_atomic_push_leaves_every_ref_unchanged_on_rejection
    @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/main")
    commit("second\n", "Second")
    second = git_in(@source, "rev-parse", "HEAD").strip
    hook = File.join(@remote, "hooks", "update")
    File.binwrite(hook, "#!/bin/sh\ncase \"$1\" in refs/heads/rejected) exit 1;; esac\n")
    File.chmod(0o755, hook)

    assert_raises(Thuban::TransportError) do
      @repository.push(@remote, atomic: true, refspecs: [
        "refs/heads/main:refs/heads/main",
        "refs/heads/main:refs/heads/rejected"
      ])
    end
    assert_equal @first, git_in(@remote, "rev-parse", "refs/heads/main").strip
    _output, _error, status = Open3.capture3("git", "-C", @remote, "rev-parse", "--verify", "refs/heads/rejected")
    refute status.success?
    assert @repository.odb.exist?(second)
  end

  def test_deletes_refs_and_validates_updates_before_connecting
    @repository.push(@remote, refspecs: "refs/heads/main:refs/heads/topic")
    @repository.push(@remote, refspecs: ":refs/heads/topic")
    _output, _error, status = Open3.capture3("git", "-C", @remote, "rev-parse", "--verify", "refs/heads/topic")
    refute status.success?

    connection = Thuban::Remote.open(@remote)
    assert_raises(ArgumentError) { connection.push(@repository, []) }
    assert_raises(ArgumentError) { connection.push(@repository, [["refs/heads/main", nil, "f" * 40]]) }
    assert_raises(Thuban::TransportError) do
      connection.push(@repository, [["refs/heads/../bad", nil, @first]])
    end
  ensure
    connection&.close
  end

  def test_rejects_truncated_or_malformed_push_status
    connection = Thuban::Remote.open("http://example.invalid/repository.git")
    updates = [{ref: "refs/heads/main", old: "0" * 40, new: @first}]
    responses = [
      Thuban::Remote::Protocol.packet("unpack ok\n") +
        Thuban::Remote::Protocol.packet("ok refs/heads/main\n"),
      Thuban::Remote::Protocol.packet("unpack ok\n") +
        Thuban::Remote::Protocol.packet("ok refs/heads/main unexpected\n") +
        Thuban::Remote::Protocol.flush,
      Thuban::Remote::Protocol.packet("unpack ok\n") +
        Thuban::Remote::Protocol.packet("ok refs/heads/main\n") +
        Thuban::Remote::Protocol.packet("ok refs/heads/other\n") +
        Thuban::Remote::Protocol.flush
    ]

    responses.each do |body|
      assert_raises(Thuban::TransportError) do
        connection.send(:parse_push_response, body, updates, []) {}
      end
    end
  ensure
    connection&.close
  end

  private

  def commit(contents, message)
    File.binwrite(File.join(@source, "file.txt"), contents)
    git_in(@source, "add", ".")
    git_in(@source, "commit", "-qm", message)
  end

  def file_url(path)
    normalized = File.expand_path(path).tr("\\", "/")
    normalized = "/#{normalized}" if normalized.match?(/\A[A-Za-z]:\//)
    URI::Generic.build(scheme: "file", path: normalized).to_s
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

  class AuthGitHTTPFixture < GitHTTPFixture
    def initialize(root, authorization)
      @authorization = authorization
      super(root)
    end

    private

    def call(request)
      return [401, "text/plain", "authentication required", {"WWW-Authenticate" => "Basic"}] unless request[:headers]["authorization"] == @authorization

      super
    end
  end
end
