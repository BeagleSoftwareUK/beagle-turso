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
end
