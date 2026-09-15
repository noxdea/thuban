# frozen_string_literal: true

require "open3"
require "rbconfig"
require "securerandom"
require "shellwords"
require "tmpdir"
require_relative "../lib/thuban"

megabytes = Integer(ARGV.find { |argument| !argument.start_with?("-") } || 8)
raise ArgumentError, "size must be between 1 and 128 MiB" unless (1..128).cover?(megabytes)

def git(directory, *arguments)
  output, error, status = Open3.capture3("git", "-C", directory, *arguments, binmode: true)
  raise "git #{arguments.first} failed: #{error}" unless status.success?

  output
end

Dir.mktmpdir("thuban-ssh-bench-") do |directory|
  source = File.join(directory, "source")
  remote = File.join(directory, "remote.git")
  local = File.join(directory, "local")
  fake_ssh = File.join(directory, "ssh.rb")
  FileUtils.mkdir_p(source)
  git(source, "init", "-q", "-b", "main")
  git(source, "config", "user.name", "Benchmark")
  git(source, "config", "user.email", "benchmark@example.invalid")
  File.binwrite(File.join(source, "payload.bin"), SecureRandom.random_bytes(megabytes * 1024 * 1024))
  git(source, "add", ".")
  git(source, "commit", "-qm", "Benchmark")
  head = git(source, "rev-parse", "HEAD").strip
  git(directory, "clone", "-q", "--bare", source, remote)
  FileUtils.mkdir_p(local)
  git(local, "init", "-q", "-b", "main")
  File.binwrite(fake_ssh, <<~'RUBY')
    require "shellwords"
    command = Shellwords.split(ARGV.fetch(-1))
    abort unless command.shift == "git-upload-pack" && command.length == 1
    exec("git-upload-pack", command.first)
  RUBY

  repository = Thuban::Repository.new(local)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  connection = Thuban::Remote.open("bench@localhost:#{remote}", ssh: [RbConfig.ruby, fake_ssh], timeout: 60)
  begin
    connection.refs
    connection.fetch(repository, wants: [head])
  ensure
    connection.close
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  throughput = megabytes / elapsed
  puts "#{megabytes} MiB SSH fetch, #{elapsed.round(3)} s, #{throughput.round(1)} MiB/s input"
  abort "SSH fetch fell below 0.1 MiB/s" if ARGV.include?("--assert") && throughput < 0.1
end
