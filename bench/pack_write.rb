# frozen_string_literal: true

require "tempfile"
require_relative "../lib/thuban"

megabytes = Integer(ARGV.find { |argument| !argument.start_with?("-") } || 32)
raise ArgumentError, "size must be between 1 and 512 MiB" unless (1..512).cover?(megabytes)

chunk_size = 128 * 1024
count = (megabytes * 1024 * 1024).fdiv(chunk_size).ceil
payload = ("0123456789abcdef" * (chunk_size / 16)).b
objects = Array.new(count) { |index| ["blob", "#{index}:".b + payload] }
elapsed = nil
bytes = nil
Tempfile.create("thuban-pack-bench") do |file|
  file.binmode
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Thuban::Pack.write(file, objects)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  bytes = file.size
end
throughput = objects.sum { |_, data| data.bytesize } / elapsed / (1024 * 1024)
puts "#{objects.length} objects, #{bytes} packed bytes, #{elapsed.round(3)} s, #{throughput.round(1)} MiB/s input"
abort "pack writing fell below 5 MiB/s" if ARGV.include?("--assert") && throughput < 5
