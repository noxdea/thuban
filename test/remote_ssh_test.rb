# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "rbconfig"
require "shellwords"
require "timeout"

class RemoteSSHTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("thuban-ssh-")
    @source = File.join(@directory, "source")
    @remote = File.join(@directory, "remote.git")
    @local = File.join(@directory, "local")
    @log = File.join(@directory, "ssh.log")
    @fake_ssh = File.join(@directory, "fake_ssh.rb")
    git_in(@source, "init", "-q", "-b", "main")
    git_in(@source, "config", "user.name", "Fixture")
    git_in(@source, "config", "user.email", "fixture@example.invalid")
    File.binwrite(File.join(@source, "file.txt"), "through ssh\n")
    git_in(@source, "add", ".")
    git_in(@source, "commit", "-qm", "SSH fixture")
    @head = git_in(@source, "rev-parse", "HEAD").strip
    git_in(@directory, "clone", "-q", "--bare", @source, @remote)
    git_in(@local, "init", "-q", "-b", "main")
    @repository = Thuban::Repository.new(@local)
    write_fake_ssh
    @previous_log = ENV["THUBAN_SSH_LOG"]
    ENV["THUBAN_SSH_LOG"] = @log
  end

  def teardown
    ENV["THUBAN_SSH_LOG"] = @previous_log
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
  end

  def test_scp_like_remote_discovers_refs_and_fetches_with_upload_pack
    connection = Thuban::Remote.open("fixture@localhost:#{@remote}", ssh: ruby_fake_ssh)
    refs = connection.refs

    assert_equal @head, refs.find { |ref| ref.name == "refs/heads/main" }.oid
    assert_includes connection.fetch(@repository, wants: [@head]), @head
    assert_equal "through ssh\n", @repository.blob("file.txt", reference: @head)
    assert_git_fsck(@local)

    invocations = File.readlines(@log, chomp: true).map { |line| JSON.parse(line) }
    assert_equal 2, invocations.length
    invocations.each do |arguments|
      assert_equal ["-o", "BatchMode=yes", "--", "fixture@localhost"], arguments[0, 4]
      assert_equal ["git-upload-pack", @remote], Shellwords.split(arguments.fetch(4))
    end
  ensure
    connection&.close
  end

  def test_ssh_fetch_negotiates_shallow_and_partial_history
    File.binwrite(File.join(@source, "file.txt"), "newer\n")
    git_in(@source, "commit", "-qam", "Newer")
    head = git_in(@source, "rev-parse", "HEAD").strip
    parent = git_in(@source, "rev-parse", "HEAD^").strip
    blob = git_in(@source, "rev-parse", "HEAD:file.txt").strip
    git_in(@source, "push", "-q", @remote, "main")
    git_in(@remote, "config", "uploadpack.allowFilter", "true")
    connection = Thuban::Remote.open("fixture@localhost:#{@remote}", ssh: ruby_fake_ssh)

    connection.fetch(@repository, wants: [head], depth: 1, filter: "blob:none")

    assert @repository.odb.exist?(head)
    refute @repository.odb.exist?(parent)
    refute @repository.odb.exist?(blob)
    assert_equal "#{head}\n", File.binread(File.join(@repository.common_dir, "shallow"))
  ensure
    connection&.close
  end

  def test_ssh_uri_passes_user_host_and_port_as_separate_arguments
    connection = Thuban::Remote.open(ssh_uri(port: 2222), ssh: ruby_fake_ssh)
    assert_equal @head, connection.refs.find { |ref| ref.name == "refs/heads/main" }.oid

    arguments = JSON.parse(File.readlines(@log, chomp: true).last)
    assert_equal ["-o", "BatchMode=yes", "-p", "2222", "--", "fixture@localhost"], arguments[0, 6]
    assert_equal ["git-upload-pack", ssh_uri_path], Shellwords.split(arguments.fetch(6))
  ensure
    connection&.close
  end

  def test_ssh_uri_scheme_is_case_insensitive
    connection = Thuban::Remote.open(ssh_uri(scheme: "SSH"), ssh: ruby_fake_ssh)

    assert_equal @head, connection.refs.find { |ref| ref.name == "refs/heads/main" }.oid
  ensure
    connection&.close
  end

  def test_uses_shell_parsed_git_ssh_command_without_running_a_shell
    previous = ENV["GIT_SSH_COMMAND"]
    ENV["GIT_SSH_COMMAND"] = ruby_fake_ssh.map { |part| Shellwords.escape(part) }.join(" ")
    connection = Thuban::Remote.open("localhost:#{@remote}")

    assert_equal @head, connection.refs.find { |ref| ref.name == "refs/heads/main" }.oid
  ensure
    connection&.close
    ENV["GIT_SSH_COMMAND"] = previous
  end

  def test_repository_fetch_accepts_a_direct_ssh_url
    previous = ENV["GIT_SSH_COMMAND"]
    ENV["GIT_SSH_COMMAND"] = ruby_fake_ssh.map { |part| Shellwords.escape(part) }.join(" ")

    refs = @repository.fetch("fixture@localhost:#{@remote}")

    assert_equal @head, refs.find { |ref| ref.name == "refs/heads/main" }.oid
    assert @repository.odb.exist?(@head)
    assert_empty @repository.refs
  ensure
    ENV["GIT_SSH_COMMAND"] = previous
  end

  def test_copies_explicit_ssh_arguments_before_use
    command = ruby_fake_ssh.map(&:dup)
    connection = Thuban::Remote.open("localhost:#{@remote}", ssh: command)
    command.first.replace("missing-ssh")

    assert_equal @head, connection.refs.find { |ref| ref.name == "refs/heads/main" }.oid
  ensure
    connection&.close
  end

  def test_rejects_url_and_command_injection_before_starting_ssh
    invalid = [
      "bad;host:repo.git",
      "host:repo;touch",
      "-host:repo.git",
      "ssh://-host/repo.git",
      "ssh://host/repo%0Atouch",
      "ssh://host/repo.git?option=value",
      "ssh://host/repo.git#fragment",
      "ssh://host:65536/repo.git"
    ]
    invalid.each { |url| assert_raises(Thuban::TransportError) { Thuban::Remote.open(url, ssh: ruby_fake_ssh) } }
    assert_raises(Thuban::AuthenticationError) do
      Thuban::Remote.open("ssh://user:very-secret@host/repo.git", ssh: ruby_fake_ssh)
    end
    assert_raises(Thuban::TransportError) do
      Thuban::Remote.open("host:repo.git", ssh: "#{RbConfig.ruby} 'unterminated")
    end
    refute File.exist?(@log)
  end

  def test_bounds_runtime_kills_the_process_group_and_redacts_errors
    sleeper = File.join(@directory, "sleeper.rb")
    child_pid = File.join(@directory, "child.pid")
    File.binwrite(sleeper, <<~RUBY)
      unless Gem.win_platform?
        child = spawn(#{RbConfig.ruby.dump}, "-e", "sleep 30")
        File.write(#{child_pid.dump}, child)
      end
      sleep 30
    RUBY
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Thuban::TransportError) do
      Thuban::Remote.open("host:repo.git", ssh: [RbConfig.ruby, sleeper], timeout: 0.2).refs
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 2
    assert_equal "SSH transport timed out", error.message
    unless Gem.win_platform?
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      sleep 0.01 until File.exist?(child_pid) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      assert File.exist?(child_pid), "sleeper did not start its child"
      assert_process_exited(Integer(File.read(child_pid)))
    end

    missing = File.join(@directory, "secret-missing-ssh")
    error = assert_raises(Thuban::TransportError) do
      Thuban::Remote.open("host:repo.git", ssh: [missing]).refs
    end
    assert_equal "SSH executable not found", error.message
    refute_includes error.message, missing

    noisy = File.join(@directory, "noisy.rb")
    File.binwrite(noisy, <<~'RUBY')
      STDOUT.binmode
      warn "stderr-secret"
      payload = "ERR ssh://user@host/secret.git\n"
      STDOUT.write(format("%04x", payload.bytesize + 4) + payload + "0000")
      STDOUT.flush
      sleep 30
    RUBY
    error = assert_raises(Thuban::TransportError) do
      Thuban::Remote.open("host:repo.git", ssh: [RbConfig.ruby, noisy]).refs
    end
    assert_equal "remote reported an error", error.message
    refute_includes error.message, "secret"
    refute_includes error.message, "host:repo.git"
  end

  def test_close_cancels_an_active_ssh_process
    ready = File.join(@directory, "ready")
    sleeper = File.join(@directory, "cancel-sleeper.rb")
    File.binwrite(sleeper, "File.write(#{ready.dump}, \"ready\")\nsleep 30\n")
    connection = Thuban::Remote.open("host:repo.git", ssh: [RbConfig.ruby, sleeper])
    operation = Thread.new do
      connection.refs
    rescue Thuban::TransportError => error
      error
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    sleep 0.01 until File.exist?(ready) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    connection.close
    error = operation.value

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_instance_of Thuban::TransportError, error
  ensure
    connection&.close
  end

  def test_high_level_cancellation_stops_a_blocked_ssh_fetch
    ready = File.join(@directory, "high-level-ready")
    sleeper = File.join(@directory, "high-level-cancel.rb")
    File.binwrite(sleeper, "File.write(#{ready.dump}, \"ready\")\nsleep 30\n")
    cancelled = false
    operation = Thread.new do
      @repository.fetch("host:repo.git", ssh: [RbConfig.ruby, sleeper], cancelled: -> { cancelled })
    rescue StandardError => error
      error
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until File.exist?(ready) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    assert File.exist?(ready), "SSH process did not start"
    cancelled = true

    error = Timeout.timeout(2) { operation.value }

    assert_instance_of Thuban::Cancelled, error
    assert_empty @repository.refs
  ensure
    operation&.join(2)
  end

  def test_close_is_idempotent_and_http_authentication_stays_separate
    connection = Thuban::Remote.open("host:repo.git", ssh: ruby_fake_ssh)
    assert_nil connection.close
    assert_nil connection.close
    assert_raises(Thuban::TransportError) { connection.refs }
    assert_raises(ArgumentError) { Thuban::Remote.open("https://example.invalid/repo.git", ssh: ruby_fake_ssh) }

    credential = Thuban::Remote::Credentials.bearer(token: "http-token")
    assert_instance_of Thuban::Remote::Connection,
      Thuban::Remote.open("https://example.invalid/repo.git", credentials: credential)
    assert_raises(Thuban::AuthenticationError) do
      Thuban::Remote.open("host:repo.git", credentials: credential, ssh: ruby_fake_ssh)
    end
    assert_raises(Thuban::AuthenticationError) do
      Thuban::Remote.open("host:repo.git", credentials: false, ssh: ruby_fake_ssh)
    end
  end

  private

  def ruby_fake_ssh = [RbConfig.ruby, @fake_ssh]

  def ssh_uri(port: nil, scheme: "ssh")
    "#{scheme}://fixture@localhost#{":#{port}" if port}#{ssh_uri_path}"
  end

  def ssh_uri_path
    path = @remote.tr("\\", "/")
    path.start_with?("/") ? path : "/#{path}"
  end

  def write_fake_ssh
    File.binwrite(@fake_ssh, <<~'RUBY')
      require "json"
      require "shellwords"

      File.open(ENV.fetch("THUBAN_SSH_LOG"), "a") { |file| file.puts(JSON.generate(ARGV)) }
      command = Shellwords.split(ARGV.fetch(-1))
      abort "unexpected command" unless command.length == 2 && command.first == "git-upload-pack"
      path = command.last
      path = path.delete_prefix("/") if Gem.win_platform? && path.match?(/\A\/[A-Za-z]:\//)
      exec("git-upload-pack", path)
    RUBY
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

  def assert_process_exited(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
    loop do
      Process.kill(0, pid)
      raise "SSH process group was not terminated" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    rescue Errno::ESRCH
      return
    end
  end
end
