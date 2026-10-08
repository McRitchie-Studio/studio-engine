# frozen_string_literal: true

require "socket"
require "timeout"
require "net/http"

# A listener on 127.0.0.1 for the recording fetch tests, and the seam that
# sends the fetch's pinned connections to it in plain HTTP. NO REAL DNS, NO
# OUTSIDE NETWORK: names resolve through an injected resolver, and what the
# `connection` seam was ASKED for is recorded in @asked, which is what the
# pinning assertions read. Every host and path is invented.
#
# The including test saves and restores Studio::KnowledgeRecording.connection
# (`remember_connection!` in setup, `restore_connection!` in teardown).
module KnowledgeRecordingListener
  PUBLIC_V4 = "93.184.216.34"
  OTHER_V4 = "93.184.216.35"
  DEAD_V4 = "93.184.216.99"

  def remember_connection!
    @asked = []
    @original_connection = Studio::KnowledgeRecording.method(:connection)
  end

  def restore_connection!
    Studio::KnowledgeRecording.define_singleton_method(:connection, @original_connection)
  end

  # Serves `routes` (request path => a lambda handed the socket), one request
  # per connection, and records each request head.
  def with_listener(routes, limit = 20)
    server = TCPServer.new("127.0.0.1", 0)
    heads = Queue.new
    thread = Thread.new do
      loop do
        client = server.accept
        Thread.new(client) do |socket|
          head = +""
          head << socket.readpartial(4096) until head.include?("\r\n\r\n")
          heads << head
          routes.fetch(head[/\AGET (\S+)/, 1]).call(socket)
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError, KeyError
          nil
        ensure
          socket.close unless socket.closed?
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
    port = server.addr[1]
    asked = @asked
    Studio::KnowledgeRecording.define_singleton_method(:connection) do |uri, address|
      asked << [uri.to_s, address]
      raise Errno::ECONNREFUSED, "refused #{address}" if address == DEAD_V4

      http = Net::HTTP.new("127.0.0.1", port, nil)
      http.open_timeout = 2
      http.read_timeout = 2
      http
    end
    Timeout.timeout(limit) { yield heads }
  ensure
    server&.close
    thread&.join(2)
  end

  def respond(status, headers = {}, body = "")
    lambda do |socket|
      lines = ["HTTP/1.1 #{status} X", "Connection: close"]
      lines << "Content-Length: #{body.bytesize}" unless headers.key?("Content-Length") || headers.key?("Transfer-Encoding")
      headers.each { |name, value| lines << "#{name}: #{value}" }
      socket.write("#{lines.join("\r\n")}\r\n\r\n")
      socket.write(body)
    end
  end

  # Writes `head` once, then `block` until the peer hangs up, pausing `every`
  # seconds between writes. `sent` receives each block's size.
  def endless_raw(head, block, sent, every: 0)
    lambda do |socket|
      socket.write(head)
      loop do
        socket.write(block)
        sent << block.bytesize
        sleep every if every.positive?
      end
    end
  end

  # A response whose BODY never ends.
  def endless(status, headers, sent, block:)
    endless_raw("HTTP/1.1 #{status} X\r\nConnection: close\r\n#{headers.map { |n, v| "#{n}: #{v}\r\n" }.join}\r\n", block, sent)
  end

  def total(queue)
    sum = 0
    sum += queue.pop until queue.empty?
    sum
  end

  def dns(map = {})
    known = { "files.example.com" => [PUBLIC_V4], "cdn.example.net" => [OTHER_V4] }.merge(map)
    ->(host) { known.fetch(host) }
  end

  def rss_megabytes
    `ps -o rss= -p #{Process.pid}`.to_i / 1024
  end
end
