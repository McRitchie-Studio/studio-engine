# frozen_string_literal: true

require "socket"
require "json"
require "time"
require "uri"
require "rack/utils"

# A stand-in for the McRitchie Studio hub's agent chat API, served over a real
# socket on 127.0.0.1, so Studio::AgentChat runs its real Net::HTTP path: the
# connect, the timeouts, the status codes. No outside network.
#
#   hub = AgentChatStubHub.start
#   hub.respond { |req| [201, { "turn" => {...} }] }    # status, JSON body (or a String)
#   hub.respond { |req| sleep 2; [200, {}] }             # a slow hub
#   hub.requests.last  # => Request(method, path, query, headers, body, json)
#   hub.stop
class AgentChatStubHub
  Request = Struct.new(:method, :path, :query, :headers, :body, keyword_init: true) do
    def json = body.to_s.empty? ? nil : JSON.parse(body)
  end

  attr_reader :port

  def self.start = new.tap(&:start)

  def initialize
    @handler = ->(_req) { [200, { "turns" => [], "pending" => false }] }
    @recorded = []
    @lock = Mutex.new
  end

  def url = "http://127.0.0.1:#{port}"

  # A hub that holds a conversation, for the browser lane (e2e/boot.rb), in the
  # hub's own shape (hub-agent-chat-api, AgentChat::Turns): one thread per person
  # ({email} or {anon_token}) of message ROWS, each answered as two turns that
  # SHARE the row's id and status, the visitor's ("user") and, once answered, the
  # agent's ("agent"). `after` is a row id (rows with id > after). A row is
  # "pending", "typing" after half of `answer_after` seconds, then "answered"
  # with "You said: <text>". A message containing "[hub-down]" is answered 503,
  # as a hub that is down; it is not stored.
  def converse!(answer_after: 1.5)
    threads = Hash.new { |hash, key| hash[key] = [] }
    seq = 0
    lock = Mutex.new
    turns_of = lambda do |row|
      user = { "id" => row[:id], "role" => "user", "text" => row[:text], "created_at" => row[:at], "status" => row[:status] }
      next [user] unless row[:reply]

      [user, { "id" => row[:id], "role" => "agent", "text" => row[:reply], "created_at" => row[:at], "status" => row[:status] }]
    end
    respond do |request|
      if request.method == "POST"
        body = request.json
        next [503, { "error" => "down" }] if body["text"].to_s.include?("[hub-down]")

        key = body["person"].to_a.sort.to_s
        row = lock.synchronize do
          seq += 1
          { id: seq, text: body["text"], at: Time.now.utc.iso8601, status: "pending", reply: nil }.tap { |r| threads[key] << r }
        end
        Thread.new do
          sleep answer_after / 2.0
          lock.synchronize { row[:status] = "typing" }
          sleep answer_after / 2.0
          lock.synchronize { row.merge!(status: "answered", reply: "You said: #{row[:text]}") }
        end
        [201, { "turn" => lock.synchronize { turns_of.call(row).first } }]
      else
        key = request.query["person"].to_a.sort.to_s
        after = request.query["after"].to_s
        lock.synchronize do
          rows = threads[key]
          shown = after.match?(/\A\d+\z/) ? rows.select { |r| r[:id] > after.to_i } : rows
          [200, { "turns" => shown.flat_map { |r| turns_of.call(r) },
                  "pending" => rows.any? { |r| %w[pending typing].include?(r[:status]) } }]
        end
      end
    end
    self
  end

  def respond(&block)
    @handler = block
  end

  def requests
    @lock.synchronize { @recorded.dup }
  end

  def start
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @thread = Thread.new do
      loop do
        client = @server.accept
        Thread.new(client) { |socket| serve(socket) }
      rescue IOError, Errno::EBADF
        break
      end
    end
    self
  end

  def stop
    @server&.close
    @thread&.join(1)
  end

  private

  def serve(socket)
    line = socket.gets.to_s
    method, target, = line.split(" ", 3)
    headers = {}
    while (header = socket.gets) && header != "\r\n"
      name, value = header.split(":", 2)
      headers[name.strip.downcase] = value.to_s.strip
    end
    body = headers["content-length"] ? socket.read(headers["content-length"].to_i) : nil
    uri = URI.parse(target.to_s)
    request = Request.new(method: method, path: uri.path, query: Rack::Utils.parse_nested_query(uri.query.to_s),
                          headers: headers, body: body)
    @lock.synchronize { @recorded << request }

    status, payload, extra = @handler.call(request)
    text = payload.is_a?(String) ? payload : JSON.generate(payload)
    type = payload.is_a?(String) ? "text/html" : "application/json"
    lines = ["HTTP/1.1 #{status} X", "Content-Type: #{type}", "Content-Length: #{text.bytesize}", "Connection: close"]
    (extra || {}).each { |name, value| lines << "#{name}: #{value}" }
    socket.write(lines.join("\r\n") + "\r\n\r\n" + text)
  rescue StandardError
    nil
  ensure
    socket.close rescue nil
  end
end
