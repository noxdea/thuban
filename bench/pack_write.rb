# frozen_string_literal: true

require "tempfile"
require "tmpdir"
require_relative "../lib/thuban"

megabytes = Integer(ARGV.find { |argument| !argument.start_with?("-") } || 32)
raise ArgumentError, "size must be between 1 and 512 MiB" unless (1..512).cover?(megabytes)

chunk_size = 128 * 1024
count = (megabytes * 1024 * 1024).fdiv(chunk_size).ceil
payload = ("0123456789abcdef" * (chunk_size / 16)).b
objects = Array.new(count) { |index| ["blob", "#{index}:".b + payload] }
elapsed = nil
read_elapsed = nil
bytes = nil
Tempfile.create("thuban-pack-bench") do |file|
  file.binmode
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Thuban::Pack.write(file, objects)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  bytes = file.size
  Dir.mktmpdir("thuban-pack-read-bench") do |directory|
    odb = Thuban::ObjectDatabase.new(directory)
    file.rewind
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    received = Thuban::Pack.read_stream(file, odb)
    read_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise "pack object count mismatch" unless received.length == objects.length
  end
end
input_bytes = objects.sum { |_, data| data.bytesize }
throughput = input_bytes / elapsed / (1024 * 1024)
read_throughput = input_bytes / read_elapsed / (1024 * 1024)
puts "#{objects.length} objects, #{bytes} packed bytes, #{elapsed.round(3)} s, #{throughput.round(1)} MiB/s input"
puts "expanded in #{read_elapsed.round(3)} s, #{read_throughput.round(1)} MiB/s output"
if ARGV.include?("--assert")
  abort "pack writing fell below 5 MiB/s" if throughput < 5
  abort "pack reading fell below 2 MiB/s" if read_throughput < 2
end
