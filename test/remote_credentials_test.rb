# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/http_fixture"
require "rbconfig"
require "shellwords"
require "stringio"

class AuthenticatedGitHTTPFixture < GitHTTPFixture
  def initialize(project_root, authorization:)
    @authorization = authorization
    super(project_root)
  end

  private

  def call(request)
    return [401, "text/plain", "authentication required"] unless request[:headers]["authorization"] == @authorization

    super
  end
end

class RemoteCredentialsTest < Minitest::Test
  Credentials = Thuban::Remote::Credentials
  Protocol = Thuban::Remote::Protocol

  def setup
    @directory = Dir.mktmpdir("thuban-credentials-")
    @local = File.join(@directory, "local")
    _output, error, status = Open3.capture3("git", "-C", @directory, "init", "-q", "local", binmode: true)
    assert status.success?, error
    @repository = Thuban::Repository.new(@local)
    @oid = Thuban::ObjectDatabase.hash("blob", "authenticated")
    pack = StringIO.new(+"".b)
    Thuban::Pack.write(pack, [["blob", "authenticated"]])
    @pack = pack.string
  end

  def teardown
    @server&.close
    @redirect_target&.close
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
  end

  def test_static_basic_credentials_authenticate_a_fetch
    expected = "Basic #{["reader:basic-secret"].pack("m0")}"
    credential = Credentials.static(username: "reader", password: "basic-secret")

    fetch_with(credential, expected)
    refute_includes credential.inspect, "basic-secret"
  end

  def test_bearer_credentials_authenticate_a_fetch
    credential = Credentials.bearer(token: "bearer-secret")

    fetch_with(credential, "Bearer bearer-secret")
    refute_includes credential.inspect, "bearer-secret"
  end

  def test_callback_resolves_credentials_for_the_remote_url
    credential = nil
    callback = Credentials.callback do |url|
      assert_equal @server.url, url
      credential ||= Credentials.static(username: "callback", password: "callback-secret")
    end
    expected = "Basic #{["callback:callback-secret"].pack("m0")}"

    fetch_with(callback, expected)
  end

  def test_callback_is_resolved_once_for_concurrent_connection_use
    calls = 0
    lock = Mutex.new
    callback = Credentials.callback do
      lock.synchronize { calls += 1 }
      sleep 0.02
      Credentials.bearer(token: "shared-token")
    end
    connection = Thuban::Remote.open("https://example.invalid/repo.git", credentials: callback)

    headers = 10.times.map { Thread.new { connection.send(:authorization) } }.map(&:value)

    assert_equal ["Bearer shared-token"], headers.uniq
    assert_equal 1, calls
  ensure
    connection&.close
  end

  def test_git_credential_helper_authenticates_a_fetch
    expected = "Basic #{["helper:helper-secret"].pack("m0")}"
    start_authenticated_server(expected)
    store = File.join(@directory, "credential-store")
    File.binwrite(store, "#{@server.url.sub("http://", "http://helper:helper-secret@")}\n")

    fetch(Credentials.helper("store --file=#{store}"))
  end

  def test_git_credential_helper_negotiates_bearer_credentials
    source = <<~RUBY
      if ARGV.first == "capability"
        puts "version 0"
        puts "capability authtype"
      elsif ARGV.first == "get"
        puts "capability[]=authtype"
        puts "authtype=Bearer"
        puts "credential=helper-bearer"
      end
    RUBY
    expected = "Bearer helper-bearer"
    start_authenticated_server(expected)

    fetch(Credentials.helper(shell_helper(source)))
  end

  def test_git_credential_helper_formats_ipv6_hosts_once
    helper = Credentials.helper
    input = helper.send(:input_for, URI("https://[::1]:8443/repo.git"))

    assert_includes input, "host=[::1]:8443\n"
    refute_includes input, "host=[[::1]]"
  end

  def test_git_credential_helper_accepts_repeated_array_attributes
    output = "capability[]=authtype\ncapability[]=state\nauthtype=Bearer\ncredential=token\n\n"

    fields = Credentials.helper.send(:parse, output)

    assert_equal %w[authtype state], fields["capability[]"]
    assert_equal "Bearer", fields["authtype"]
  end

  def test_credentials_authenticate_a_real_git_http_backend_fetch
    source = File.join(@directory, "source")
    remote = File.join(@directory, "remote.git")
    git_in(source, "init", "-q", "-b", "main")
    git_in(source, "config", "user.name", "Fixture")
    git_in(source, "config", "user.email", "fixture@example.invalid")
    File.binwrite(File.join(source, "file.txt"), "authenticated backend\n")
    git_in(source, "add", ".")
    git_in(source, "commit", "-qm", "Authenticated")
    oid = git_in(source, "rev-parse", "HEAD").strip
    git_in(@directory, "clone", "-q", "--bare", source, remote)
    @server = AuthenticatedGitHTTPFixture.new(@directory, authorization: "Bearer backend-token")
    connection = Thuban::Remote.open(@server.url, credentials: Credentials.bearer(token: "backend-token"))

    assert_equal oid, connection.refs.find { |ref| ref.name == "refs/heads/main" }.oid
    assert_includes connection.fetch(@repository, wants: [oid]), oid
    assert_equal "authenticated backend\n", @repository.blob("file.txt", reference: oid)
  ensure
    connection&.close
  end

  def test_missing_credentials_and_rejected_credentials_do_not_expose_secrets
    start_authenticated_server("Bearer accepted")
    error = assert_raises(Thuban::AuthenticationError) { Thuban::Remote.open(@server.url).refs }
    refute_includes error.full_message, "server-secret"

    wrong = Credentials.static(username: "reader", password: "client-secret")
    error = assert_raises(Thuban::AuthenticationError) { Thuban::Remote.open(@server.url, credentials: wrong).refs }
    refute_includes error.full_message, "client-secret"
    refute_includes error.full_message, "server-secret"
  end

  def test_callback_and_helper_failures_are_redacted
    callback = Credentials.callback { raise "callback-secret" }
    error = assert_raises(Thuban::AuthenticationError) { Thuban::Remote.open("http://127.0.0.1/repo.git", credentials: callback).refs }
    assert_nil error.cause
    refute_includes error.full_message, "callback-secret"

    helper = Credentials.helper(shell_helper('STDERR.write("helper-secret"); exit 1'))
    error = assert_raises(Thuban::AuthenticationError) { Thuban::Remote.open("http://127.0.0.1/repo.git", credentials: helper).refs }
    assert_equal "credential helper failed", error.message
    assert_nil error.cause
    refute_includes error.full_message, "helper-secret"
  end

  def test_credential_helper_output_is_bounded
    output = StringIO.new("x" * (Credentials::MAX_HELPER_OUTPUT + 1))
    error = assert_raises(Thuban::AuthenticationError) { Credentials.helper.send(:read_bounded, output) }

    assert_equal "credential helper output exceeds size limit", error.message
    assert_nil error.cause
  end

  def test_callback_accepts_nil_and_rejects_other_results
    connection = Thuban::Remote.open("https://example.invalid/repo.git", credentials: Credentials.callback { nil })
    assert_nil connection.send(:authorization)
    connection.close

    callback = Credentials.callback { Object.new }
    error = assert_raises(Thuban::AuthenticationError) do
      Thuban::Remote.open("https://example.invalid/repo.git", credentials: callback).send(:authorization)
    end
    assert_equal "credential callback returned an invalid value", error.message
    assert_nil error.cause
  end

  def test_credential_helper_timeout_is_bounded
    helper = Credentials.helper(shell_helper("sleep 2"))
    error = assert_raises(Thuban::AuthenticationError) do
      Thuban::Remote.open("http://127.0.0.1/repo.git", credentials: helper, timeout: 0.05).refs
    end

    assert_equal "credential helper timed out", error.message
    assert_nil error.cause
  end

  def test_redirect_does_not_forward_authorization
    @redirect_target = HTTPFixture.new { [200, "text/plain", "unexpected"] }
    @server = HTTPFixture.new do
      [302, "text/plain", "redirect-secret", {"Location" => @redirect_target.url}]
    end
    credential = Credentials.bearer(token: "client-secret")

    error = assert_raises(Thuban::TransportError) do
      Thuban::Remote.open(@server.url, credentials: credential).refs
    end

    assert_equal "HTTP redirects are not supported", error.message
    assert_equal "Bearer client-secret", @server.requests.first[:headers]["authorization"]
    assert_empty @redirect_target.requests
    refute_includes error.full_message, "client-secret"
    refute_includes error.full_message, "redirect-secret"
    refute_includes error.full_message, @redirect_target.url
  end

  private

  def fetch_with(credential, expected)
    start_authenticated_server(expected)
    fetch(credential)
  end

  def fetch(credential)
    connection = Thuban::Remote.open(@server.url, credentials: credential)
    assert_equal @oid, connection.refs.find { |ref| ref.name == "refs/heads/main" }.oid
    assert_includes connection.fetch(@repository, wants: [@oid]), @oid
    assert_equal ["blob", "authenticated"], @repository.odb.read(@oid)
    assert @server.requests.all? { |request| request[:headers]["authorization"] }
  ensure
    connection&.close
  end

  def start_authenticated_server(expected)
    @server&.close
    advertisement = Protocol.packet("# service=git-upload-pack\n") + Protocol.flush +
      Protocol.packet("#{@oid} refs/heads/main\0side-band-64k object-format=sha1\n") + Protocol.flush
    @server = HTTPFixture.new do |request|
      if request[:headers]["authorization"] != expected
        [401, "text/plain", "server-secret"]
      elsif request[:method] == "GET"
        [200, "application/x-git-upload-pack-advertisement", advertisement]
      else
        [200, "application/x-git-upload-pack-result", Protocol.packet("NAK\n") + @pack]
      end
    end
  end

  def shell_helper(source)
    script = File.join(@directory, "credential-helper.rb")
    File.binwrite(script, source)
    "!#{Shellwords.join([RbConfig.ruby, script])}"
  end

  def git_in(directory, *arguments)
    FileUtils.mkdir_p(directory) unless File.exist?(directory)
    output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
    assert status.success?, "git #{arguments.join(' ')}: #{error}"
    output
  end
end
