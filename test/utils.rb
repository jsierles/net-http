require 'webrick'
begin
  require "webrick/https"
rescue LoadError
  # SSL features cannot be tested
end
require 'webrick/httpservlet/abstract'
require 'zlib'
require "test/unit"

require 'net2/http'
Net = Net2

class String
  def encoding_aware?
    respond_to? :encoding
  end
end

module TestNetHTTPUtils
  def self.force_encoding(string, encoding)
    if string.respond_to?(:force_encoding)
      string.force_encoding(encoding)
    end
  end

  def start(&block)
    new().start(&block)
  end

  def new
    klass = Net2::HTTP::Proxy(config('proxy_host'), config('proxy_port'))
    http = klass.new(config('host'), config('port'))
    http.set_debug_output logfile()
    http
  end

  def config(key)
    self.class::CONFIG[key]
  end

  def chunked?
    config("chunked")
  end

  def gzip?
    config("gzip")
  end

  def logfile
    $DEBUG ? $stderr : NullWriter.new
  end

  def setup
    spawn_server
  end

  def teardown
    @server.shutdown
    until @server.status == :Stop
      sleep 0.1
    end
    # resume global state
    Net::HTTP.version_1_2
  end

  def spawn_server
    server_config = {
      :BindAddress => config('host'),
      :Port => config('port'),
      :Logger => WEBrick::Log.new(NullWriter.new),
      :AccessLog => [],
      :ShutdownSocketWithoutClose => true,
      :ServerType => Thread,
    }
    server_config[:OutputBufferSize] = 4 if config('chunked')
    if defined?(OpenSSL) and config('ssl_enable')
      server_config.update({
        :SSLEnable      => true,
        :SSLCertificate => config('ssl_certificate'),
        :SSLPrivateKey  => config('ssl_private_key'),
      })
    end
    @server = WEBrick::HTTPServer.new(server_config)
    @server.mount('/', Servlet, config('chunked'), config("gzip"))
    @server.start
    n_try_max = 5
    begin
      TCPSocket.open(config('host'), config('port')).close
    rescue Errno::ECONNREFUSED
      sleep 0.2
      n_try_max -= 1
      raise 'cannot spawn server; give up' if n_try_max < 0
      retry
    end
  end

  $test_net_http = nil
  $test_net_http_data = (0...256).to_a.map {|i| i.chr }.join('') * 64
  force_encoding($test_net_http_data, "ASCII-8BIT")
  $test_net_http_data_type = 'application/octet-stream'

  class Servlet < WEBrick::HTTPServlet::AbstractServlet
    def initialize(this, chunked = false, gzip = false)
      @chunked = chunked
      @gzip = gzip
    end

    def do_GET(req, res)
      res['Content-Type'] = $test_net_http_data_type
      res.chunked = @chunked

      raw_body = $test_net_http_data

      if @gzip
        res['Content-Encoding'] = 'gzip'
        io = StringIO.new
        io.set_encoding "BINARY" if io.respond_to?(:set_encoding)
        gz = Zlib::GzipWriter.new(io)
        gz.write raw_body
        gz.close

        body = io.string
      end

      res.body = body || raw_body
    end

    # echo server
    def do_POST(req, res)
      res['Content-Type'] = req['Content-Type']
      res.body = req.body
      res.chunked = @chunked
    end

    def do_PATCH(req, res)
      res['Content-Type'] = req['Content-Type']
      res.body = req.body
      res.chunked = @chunked
    end
  end

  class NullWriter
    def <<(s) end
    def puts(*args) end
    def print(*args) end
    def printf(*args) end
  end
end
