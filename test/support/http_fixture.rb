# frozen_string_literal: true

require "socket"
require "uri"

class HTTPFixture
  attr_reader :url, :requests

  def initialize(path: "/repo.git", &handler)
    @handler = handler
    @requests = []
    @socket = TCPServer.new("127.0.0.1", 0)
    @url = "http://127.0.0.1:#{@socket.local_address.ip_port}#{path}"
    @thread = Thread.new { serve }
  end

  def close
    @socket.close unless @socket.closed?
    @thread.join
    raise @error if @error
  end

  private

  def call(request) = @handler.call(request)

  def serve
    client = nil
    loop do
      client = @socket.accept
      request_line = client.gets("\r\n")
      next client.close unless request_line

      method, path, = request_line.split(" ")
      headers = {}
      while (line = client.gets("\r\n")) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      body = client.read(headers.fetch("content-length", "0").to_i)
      request = {method: method, path: path, headers: headers, body: body}
      @requests << request
      status, type, response, extra = call(request)
      reason = status == 200 ? "OK" : "Response"
      response_headers = {"Content-Type" => type, "Content-Length" => response.bytesize, "Connection" => "close"}.merge(extra || {})
      client.write("HTTP/1.1 #{status} #{reason}\r\n")
      response_headers.each { |name, value| client.write("#{name}: #{value}\r\n") }
      client.write("\r\n")
      client.write(response)
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::EPIPE, Errno::ECONNRESET
    nil
  rescue StandardError => error
    @error = error
  ensure
    client&.close unless client&.closed?
  end
end

class GitHTTPFixture < HTTPFixture
  def initialize(project_root, protocol: :request)
    @project_root = project_root
    @protocol = protocol
    super(path: "/remote.git")
  end

  private

  def call(request)
    uri = URI.parse(request[:path])
    env = {
      "GIT_PROJECT_ROOT" => @project_root,
      "GIT_HTTP_EXPORT_ALL" => "1",
      "REQUEST_METHOD" => request[:method],
      "PATH_INFO" => uri.path,
      "QUERY_STRING" => uri.query.to_s,
      "CONTENT_TYPE" => request[:headers]["content-type"].to_s,
      "CONTENT_LENGTH" => request[:body].bytesize.to_s,
      "REMOTE_ADDR" => "127.0.0.1"
    }
    env["HTTP_GIT_PROTOCOL"] = request[:headers]["git-protocol"].to_s if @protocol == :request
    output, error, status = Open3.capture3(env, "git", "http-backend", stdin_data: request[:body], binmode: true)
    raise "git http-backend failed: #{error}" unless status.success?

    ending = output.index("\r\n\r\n")
    separator = 4
    unless ending
      ending = output.index("\n\n")
      separator = 2
    end
    raise "git http-backend omitted CGI headers" unless ending

    headers = output.byteslice(0, ending).lines.to_h do |line|
      name, value = line.chomp.split(":", 2)
      [name.downcase, value.to_s.strip]
    end
    code = headers.fetch("status", "200").split.first.to_i
    [code, headers.fetch("content-type"), output.byteslice(ending + separator..).to_s.b]
  end
end
