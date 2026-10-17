require "rbconfig"

# A TCP server in a *subprocess* that accepts connections, says nothing, and
# closes each one after STALL seconds. Living in another process, it keeps
# time even when this process's GVL is held, so a blocked native call always
# ends and the spec cannot hang.
module StalledRemote
  STALL = 1.0
  SERVER = <<~RUBY
    require "socket"
    s = TCPServer.new("127.0.0.1", 0)
    $stdout.puts s.addr[1]
    $stdout.flush
    loop { c = s.accept; Thread.new(c) { |x| sleep #{STALL}; x.close rescue nil } }
  RUBY

  def self.url
    io = IO.popen([RbConfig.ruby, "-e", SERVER])
    port = Integer(io.gets)
    yield "http://127.0.0.1:#{port}"
  ensure
    if io
      Process.kill(:TERM, io.pid) rescue nil
      io.close
    end
  end

  def self.tmp_path
    "/tmp/bt_gvl_#{Process.pid}_#{rand(1_000_000)}.db"
  end

  def self.open_against(url)
    Beagle::Turso::Database.open(local_path: tmp_path, remote_url: url, auth_token: "t")
  rescue Beagle::Turso::Error => e
    e
  end
end
