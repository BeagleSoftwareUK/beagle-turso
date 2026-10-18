# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "rake"

# Guards for the sync-engine bugs documented upstream: renames are not
# replicated (C), last_insert_rowid is the CDC change id on MVCC replicas
# (B, tursodatabase/turso#9551), and pending row writes are lost when a
# migration alters their table before the next push (A).
RSpec.describe "beagle_turso adapter: synced replica guards" do
  after(:each) { ActiveRecord::Base.remove_connection if ActiveRecord::Base.connected? }

  let(:bt) { ActiveRecord::ConnectionAdapters::BeagleTurso }

  def connect(**config)
    ActiveRecord::Base.establish_connection({ adapter: "beagle_turso", database: ":memory:" }.merge(config))
    ActiveRecord::Base.connection
  end

  # A local connection that behaves as a synced replica for the guards, without
  # a remote: Client#synced? is the single switch the adapter consults.
  def pretend_synced(conn)
    allow(conn.raw_connection).to receive(:synced?).and_return(true)
    conn
  end

  describe "renames (engine bug C)" do
    it "refuses rename_table and rename_column on a synced replica, and does not run them" do
      conn = connect
      conn.create_table(:widgets) { |t| t.string :name }
      pretend_synced(conn)

      expect { conn.rename_table(:widgets, :gadgets) }
        .to raise_error(bt::UnsupportedOnSyncedReplica, /rename_table.*synced replica.*copy the data/m)
      expect { conn.rename_column(:widgets, :name, :title) }
        .to raise_error(bt::UnsupportedOnSyncedReplica, /rename_column/)
      expect { conn.execute("ALTER TABLE widgets RENAME TO gadgets") }.to raise_error(bt::UnsupportedOnSyncedReplica)
      expect { conn.execute(%(/*app*/ ALTER TABLE "widgets" RENAME COLUMN name TO title)) }
        .to raise_error(bt::UnsupportedOnSyncedReplica)
      expect(conn.tables).to include("widgets")
      expect(conn.columns(:widgets).map(&:name)).to include("name")
      expect(bt::UnsupportedOnSyncedReplica.ancestors).to include(ActiveRecord::ActiveRecordError)
    end

    it "refuses even when the adapter has not connected yet (lazy connect)" do
      allow_any_instance_of(ActiveRecord::ConnectionAdapters::BeagleTursoAdapter::Client)
        .to receive(:synced?).and_return(true)
      conn = connect
      expect(conn.instance_variable_get(:@raw_connection)).to be_nil
      expect { conn.rename_table(:widgets, :gadgets) }.to raise_error(bt::UnsupportedOnSyncedReplica)
    end

    it "leaves renames working on a local-only connection" do
      conn = connect
      conn.create_table(:widgets) { |t| t.string :name }
      conn.rename_column(:widgets, :name, :title)
      conn.rename_table(:widgets, :gadgets)
      expect(conn.tables).to include("gadgets")
      expect(conn.columns(:gadgets).map(&:name)).to include("title")
    end

    it "does not treat rename-looking text in data as a rename" do
      conn = pretend_synced(connect)
      conn.create_table(:notes) { |t| t.string :body }
      expect { conn.execute("INSERT INTO notes (body) VALUES ('ALTER TABLE x RENAME TO y')") }.not_to raise_error
    end
  end

  describe "insert ids (engine bug B)" do
    around(:each) do |example|
      Dir.mktmpdir("ar-mvcc") do |dir|
        @path = File.join(dir, "mvcc.db")
        example.run
      end
    end

    # What a synced replica of a --tursodb remote looks like: MVCC journal
    # mode with change data capture on.
    def mvcc_cdc_connection(**config)
      conn = connect(database: @path, **config)
      conn.raw_connection.connection.query("PRAGMA journal_mode = mvcc", [])
      conn.raw_connection.connection.query("PRAGMA unstable_capture_data_changes_conn('full')", [])
      conn.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, v TEXT)")
      # No named primary key: Rails cannot add its own RETURNING "<pk>", so
      # connection.insert/exec_insert depend on the adapter's rowid fallback.
      conn.execute("CREATE TABLE plain (v TEXT)")
      conn
    end

    it "reproduces the engine bug: last_insert_rowid is not the row id" do
      conn = mvcc_cdc_connection(insert_returning_rowid: false)
      conn.execute("INSERT INTO plain (v) VALUES ('a')")
      expect(conn.raw_connection.last_insert_rowid).not_to eq(1)
      conn.insert("INSERT INTO plain (v) VALUES ('b')")
      expect(conn.send(:last_inserted_id, ActiveRecord::Result.empty)).not_to eq(2)
    end

    it "returns the real id from connection.insert and exec_insert" do
      conn = mvcc_cdc_connection(insert_returning_rowid: true)
      ids = 3.times.map { |i| conn.insert("INSERT INTO plain (v) VALUES ('v#{i}')") }
      expect(ids).to eq([1, 2, 3])

      id = conn.exec_insert("INSERT INTO plain (v) VALUES (?)", "SQL", [ActiveRecord::Relation::QueryAttribute.new("v", "x", ActiveRecord::Type::String.new)])
      expect(conn.send(:last_inserted_id, id)).to eq(4)

      conn.execute("UPDATE plain SET v = 'u' WHERE rowid = 1")
      expect(conn.insert("INSERT INTO plain (v) VALUES ('after update')")).to eq(5)
      expect(conn.select_value("SELECT count(*) FROM plain")).to eq(5)
    end

    it "reports affected rows for a multi-row insert and keeps the last id" do
      conn = mvcc_cdc_connection(insert_returning_rowid: true)
      expect(conn.insert("INSERT INTO plain (v) VALUES ('a'), ('b'), ('c') ")).to eq(3)
      expect(conn.insert("INSERT INTO plain (v) VALUES ('d');")).to eq(4)
    end

    it "keeps model create and INSERT ... RETURNING correct" do
      conn = mvcc_cdc_connection(insert_returning_rowid: true)
      klass = Class.new(ActiveRecord::Base) { self.table_name = "items" }
      expect(3.times.map { |i| klass.create!(v: "m#{i}").id }).to eq([1, 2, 3])
      expect(conn.exec_query("INSERT INTO items (v) VALUES ('z') RETURNING id").rows).to eq([[4]])
      expect(conn.insert("INSERT INTO items (v) VALUES ('y')")).to eq(5) # Rails adds RETURNING "id"
      expect(klass.create!(v: "n").id).to eq(6)
    end

    it "defaults on for synced replicas and off for local connections" do
      conn = connect
      expect(conn.send(:insert_returning_rowid?)).to be(false)
      pretend_synced(conn)
      expect(conn.send(:insert_returning_rowid?)).to be(true)
    end
  end

  describe "migration push (engine bug A)" do
    let(:push_mod) { bt::MigrationPush }
    let(:app) { Rake::Application.new }
    let(:events) { [] }
    let(:conn) { double("connection") }

    before(:each) do
      push_mod.install!
      @old_app = Rake.application
      Rake.application = app
      ev = events
      Rake::Task.define_task("db:migrate") { ev << :migrate }
      Rake::Task.define_task("db:prepare") { ev << :prepare }
      Rake::Task.define_task("db:migrate:redo") do
        ev << :redo
        Rake::Task["db:migrate"].invoke
      end
      Rake::Task.define_task("db:seed") { ev << :seed }
      allow(push_mod).to receive(:synced_connection).and_return(conn)
      allow(::Beagle::Turso::SyncManager).to receive(:push!) { ev << :push }
      @env = ENV.delete(push_mod::SKIP_ENV)
    end

    after(:each) do
      Rake.application = @old_app
      ENV[push_mod::SKIP_ENV] = @env if @env
    end

    it "pushes before and after db:migrate and db:prepare" do
      Rake::Task["db:migrate"].invoke
      Rake::Task["db:prepare"].invoke
      expect(events).to eq(%i[push migrate push push prepare push])
    end

    it "pushes once around a nested task (redo -> migrate)" do
      Rake::Task["db:migrate:redo"].invoke
      expect(events).to eq(%i[push redo migrate push])
    end

    it "does not touch unrelated tasks" do
      Rake::Task["db:seed"].invoke
      expect(events).to eq([:seed])
    end

    it "aborts before migrating, with a redacted message, when the pre-push fails" do
      allow(::Beagle::Turso::SyncManager).to receive(:push!).and_raise(RuntimeError, "boom https://user@secret.example/db?authToken=abc")
      expect { Rake::Task["db:migrate"].invoke }
        .to raise_error(bt::MigrationPushError, /could not push pending writes to Turso before migrating \(RuntimeError: .*BEAGLE_TURSO_SKIP_MIGRATION_PUSH=1 to migrate anyway/m)
      expect(events).to eq([])
    end

    it "fails with a clear message when the post-push fails (schema applied locally)" do
      calls = 0
      allow(::Beagle::Turso::SyncManager).to receive(:push!) { (calls += 1) == 2 ? raise("net down") : events << :push }
      expect { Rake::Task["db:migrate"].invoke }
        .to raise_error(bt::MigrationPushError, /applied to the local replica but could not be pushed.*net down/m)
      expect(events).to eq(%i[push migrate])
    end

    it "continues with a loud warning, and no push, when BEAGLE_TURSO_SKIP_MIGRATION_PUSH=1" do
      ENV[push_mod::SKIP_ENV] = "1"
      expect { Rake::Task["db:migrate"].invoke }.to output(/WARNING.*SKIP_MIGRATION_PUSH=1.*may be lost/m).to_stderr
      expect(events).to eq([:migrate])
    end

    it "is a no-op for local-only connections" do
      allow(push_mod).to receive(:synced_connection).and_return(nil)
      Rake::Task["db:migrate"].invoke
      expect(events).to eq([:migrate])
    end

    it "treats only beagle_turso configs with remote_url and auth_token as synced" do
      expect(push_mod.synced_config?(adapter: "beagle_turso", remote_url: "libsql://x", auth_token: "t")).to be(true)
      expect(push_mod.synced_config?(adapter: "beagle_turso", database: "x.db")).to be(false)
      expect(push_mod.synced_config?(adapter: "sqlite3", remote_url: "libsql://x", auth_token: "t")).to be(false)
    end

    it "resolves to nil for a local-only primary config" do
      allow(push_mod).to receive(:synced_connection).and_call_original
      ActiveRecord::Base.configurations = { (ENV["RAILS_ENV"] || "development") => { adapter: "beagle_turso", database: ":memory:" } }
      expect(push_mod.synced_connection).to be_nil
    end
  end
end
