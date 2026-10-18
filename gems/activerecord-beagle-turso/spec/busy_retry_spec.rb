# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The engine never waits for a busy write lock (from beagle-turso 0.4.0 it
# raises BusyError at once), so the adapter waits instead, for database.yml's
# `timeout:`, as the sqlite3 gem's busy handler does for the stock adapter.
RSpec.describe "beagle_turso busy retry" do
  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def connect(**config)
    ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: @path, pool: 4, **config)
    ActiveRecord::Base.connection.execute("CREATE TABLE IF NOT EXISTS gadgets (id INTEGER PRIMARY KEY, name TEXT)")
  end

  let(:model) { Class.new(ActiveRecord::Base) { self.table_name = "gadgets" } }

  around do |example|
    Dir.mktmpdir("ar_busy") do |dir|
      @path = File.join(dir, "busy.db")
      example.run
    ensure
      ActiveRecord::Base.remove_connection
    end
  end

  # Holds a write transaction on another pooled connection for +hold+ seconds.
  def hold_write_lock(hold)
    ready = Queue.new
    thread = Thread.new do
      model.transaction do
        model.create!(name: "holder")
        ready << true
        sleep hold
      end
    end
    ready.pop
    thread
  end

  it "makes a transaction wait at BEGIN for one in flight" do
    connect(timeout: 5000)
    holder = hold_write_lock(0.3)

    started = now
    model.transaction { model.create!(name: "waiter") }
    waited = now - started
    holder.join

    expect(waited).to be >= 0.2
    expect(model.order(:id).pluck(:name)).to eq(%w[holder waiter])
  end

  it "makes a statement outside a transaction wait" do
    connect(timeout: 5000)
    holder = hold_write_lock(0.3)

    started = now
    ActiveRecord::Base.connection.execute("INSERT INTO gadgets (name) VALUES ('waiter')")
    waited = now - started
    holder.join

    expect(waited).to be >= 0.2
    expect(model.count).to eq(2)
  end

  it "raises BusyError once the timeout has passed" do
    connect(timeout: 200)
    holder = hold_write_lock(1.0)

    started = now
    expect { model.transaction { model.create!(name: "waiter") } }.to raise_error(Beagle::Turso::BusyError)
    expect(now - started).to be_between(0.1, 0.8)
    holder.join
  end

  it "raises BusyError at once without a timeout" do
    connect
    holder = hold_write_lock(0.5)

    started = now
    expect { model.transaction { model.create!(name: "waiter") } }.to raise_error(Beagle::Turso::BusyError)
    expect(now - started).to be < 0.2
    holder.join
  end

  describe ActiveRecord::ConnectionAdapters::BeagleTursoAdapter::Client do
    let(:client) { described_class.new(Beagle::Turso::Database.open_local(":memory:")) }

    after { client.close }

    it "retries until the block succeeds" do
      client.busy_handler_timeout = 1000
      attempts = 0
      result = client.retry_busy do
        attempts += 1
        raise Beagle::Turso::BusyError, "database is busy: database is locked" if attempts < 3
        :done
      end
      expect([result, attempts]).to eq([:done, 3])
    end

    it "never retries a stale snapshot" do
      client.busy_handler_timeout = 1000
      attempts = 0
      expect do
        client.retry_busy do
          attempts += 1
          raise Beagle::Turso::BusyError, "database is busy: snapshot is stale"
        end
      end.to raise_error(Beagle::Turso::BusyError)
      expect(attempts).to eq(1)
    end

    it "does not retry when the timeout is 0" do
      client.busy_handler_timeout = 0
      attempts = 0
      expect do
        client.retry_busy { attempts += 1; raise Beagle::Turso::BusyError, "database is busy: database is locked" }
      end.to raise_error(Beagle::Turso::BusyError)
      expect(attempts).to eq(1)
    end
  end

  # Opening a synced replica while another connection syncs it fails with
  # "database tape error: database is busy", as an OpenError or ConnectError.
  describe "opening a connection" do
    let(:adapter) { ActiveRecord::ConnectionAdapters::BeagleTursoAdapter }
    let(:tape_busy) { "sync engine operation failed: database tape error: database is busy" }

    # Database stand-in whose connect fails with +errors+ in turn, then
    # connects to a real in-memory database. Records whether it was closed.
    def flaky_database(*errors)
      real = Beagle::Turso::Database.open_local(":memory:")
      Struct.new(:errors, :real, :closed) do
        def connect = errors.empty? ? real.connect : raise(errors.shift)
        def close = self.closed = true
      end.new(errors, real, false)
    end

    it "retries an open that finds the replica busy" do
      attempts = 0
      allow(adapter).to receive(:open_database) do
        attempts += 1
        raise Beagle::Turso::OpenError, "open failed: #{tape_busy}" if attempts < 3
        Beagle::Turso::Database.open_local(":memory:")
      end

      client = adapter.new_client(database: ":memory:", timeout: 1000)
      expect(attempts).to eq(3)
      expect(client.closed?).to be(false)
      client.close
    end

    it "retries a busy connect, closing the database it opened" do
      busy = flaky_database(Beagle::Turso::ConnectError.new("connect failed: #{tape_busy}"))
      opened = [busy]
      allow(adapter).to receive(:open_database) { opened.shift || Beagle::Turso::Database.open_local(":memory:") }

      client = adapter.new_client(database: ":memory:", timeout: 1000)
      expect(busy.closed).to be(true)
      client.close
    end

    it "does not retry an open that fails for another reason" do
      attempts = 0
      allow(adapter).to receive(:open_database) do
        attempts += 1
        raise Beagle::Turso::OpenError, "open failed: File is locked by another process"
      end

      expect { adapter.new_client(database: ":memory:", timeout: 1000) }.to raise_error(Beagle::Turso::OpenError)
      expect(attempts).to eq(1)
    end

    it "retries an open that read the replica's metadata mid-rewrite" do
      File.write("#{@path}-info", "{}")
      attempts = 0
      allow(adapter).to receive(:open_database) do
        attempts += 1
        raise Beagle::Turso::OpenError, "open failed: database sync engine error: meta must be initialized before open" if attempts < 2
        Beagle::Turso::Database.open_local(":memory:")
      end

      adapter.new_client(database: @path, timeout: 1000).close
      expect(attempts).to eq(2)
    end

    it "does not retry missing metadata on a replica that was never initialised" do
      attempts = 0
      allow(adapter).to receive(:open_database) do
        attempts += 1
        raise Beagle::Turso::OpenError, "open failed: database sync engine error: meta must be initialized before open"
      end

      expect { adapter.new_client(database: @path, timeout: 1000) }.to raise_error(Beagle::Turso::OpenError, /meta must be initialized/)
      expect(attempts).to eq(1)
    end

    it "raises a busy open at once without a timeout" do
      attempts = 0
      allow(adapter).to receive(:open_database) do
        attempts += 1
        raise Beagle::Turso::OpenError, "open failed: #{tape_busy}"
      end

      expect { adapter.new_client(database: ":memory:") }.to raise_error(Beagle::Turso::OpenError, /database is busy/)
      expect(attempts).to eq(1)
    end

    # The failure old_bridge_inn's SyncJob hit: the pool opens connections
    # to a synced replica while another connection writes and pushes.
    it "opens connections to a synced replica while another pushes" do
      url = ENV["TURSO_DATABASE_URL"]
      token = ENV["TURSO_AUTH_TOKEN"]
      skip "no TURSO creds (TURSO_DATABASE_URL/TURSO_AUTH_TOKEN unset)" if url.to_s.empty? || token.to_s.empty?

      config = { database: @path, remote_url: url, auth_token: token, timeout: 5000 }
      seed = adapter.new_client(config)
      seed.busy_handler_timeout = 5000
      seed.execute("CREATE TABLE IF NOT EXISTS open_busy_probe (x INTEGER)", [])
      errors = Queue.new
      push_errors = Queue.new
      stop = false
      pusher = Thread.new do
        i = 0
        until stop
          seed.retry_busy { seed.execute("INSERT INTO open_busy_probe VALUES (?)", [i += 1]) }
          begin; seed.push; rescue Beagle::Turso::Error => e; push_errors << "#{e.class}: #{e.message}"; end
        end
      end

      openers = Array.new(6) do
        Thread.new do
          8.times do
            client = adapter.new_client(config.merge(bootstrap_if_empty: false))
            client.query_result("SELECT count(*) FROM open_busy_probe", [])
            client.close
          rescue Beagle::Turso::Error => e
            errors << "#{e.class}: #{e.message}"
          end
        end
      end
      openers.each(&:join)
      stop = true
      pusher.join
      seed.execute("DROP TABLE open_busy_probe", [])
      seed.push
      seed.close

      all = Array.new(errors.size) { errors.pop }
      warn "push errors: #{Array.new(push_errors.size) { push_errors.pop }.tally}" unless push_errors.empty?
      warn all.tally.map { |k, v| "#{v} x #{k[0, 200]}" }.join("\n") unless all.empty?
      expect(all).to eq([])
    end
  end
end
