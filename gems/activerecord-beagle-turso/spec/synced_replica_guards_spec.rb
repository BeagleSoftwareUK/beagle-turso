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
    allow(conn).to receive(:synced_replica?).and_return(true)
    conn
  end

  describe "renames (engine bug C)" do
    it "refuses rename_table and raw ALTER TABLE ... RENAME on a synced replica, and does not run them" do
      conn = connect
      conn.create_table(:widgets) { |t| t.string :name }
      pretend_synced(conn)

      expect { conn.rename_table(:widgets, :gadgets) }
        .to raise_error(bt::UnsupportedOnSyncedReplica, /rename_table.*synced replica.*copy the data/m)
      expect { conn.execute("ALTER TABLE widgets RENAME TO gadgets") }.to raise_error(bt::UnsupportedOnSyncedReplica)
      expect { conn.execute(%(/*app*/ ALTER TABLE "widgets" RENAME COLUMN name TO title)) }
        .to raise_error(bt::UnsupportedOnSyncedReplica)
      expect { conn.execute(%(ALTER TABLE "my widgets" RENAME TO gadgets)) }
        .to raise_error(bt::UnsupportedOnSyncedReplica)
      expect(conn.tables).to include("widgets")
      expect(bt::UnsupportedOnSyncedReplica.ancestors).to include(ActiveRecord::ActiveRecordError)
    end

    it "allows rename_column (copy-table in Rails 8.1) on a synced replica" do
      conn = pretend_synced(connect)
      conn.create_table(:widgets) { |t| t.string :name }
      expect { conn.rename_column(:widgets, :name, :title) }.not_to raise_error
      expect(conn.columns(:widgets).map(&:name)).to include("title")
    end

    it "decides synced-ness from config without connecting or disturbing lazy transactions" do
      conn = connect
      expect(conn.synced_replica?).to be(false)
      expect(conn.instance_variable_get(:@raw_connection)).to be_nil
      conn.create_table(:widgets) { |t| t.string :name }
      conn.insert("INSERT INTO widgets (name) VALUES ('a')")
      log = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| log << p[:sql] }
      ActiveRecord::Base.transaction {}
      ActiveSupport::Notifications.unsubscribe(sub)
      expect(log).to eq([])
    end

    it "treats a config as synced only with remote_url and auth_token" do
      klass = ActiveRecord::ConnectionAdapters::BeagleTursoAdapter
      expect(klass.synced_config?(remote_url: "libsql://x", auth_token: "t")).to be(true)
      expect(klass.synced_config?(remote_url: "libsql://x")).to be(false)
      expect(klass.synced_config?(database: "x")).to be(false)
    end

    it "leaves renames working on a local-only connection" do
      conn = connect
      conn.create_table(:widgets) { |t| t.string :name }
      conn.rename_table(:widgets, :gadgets)
      expect(conn.tables).to include("gadgets")
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

    it "rewrites around trailing comments and semicolons, and ignores 'returning' inside data" do
      conn = mvcc_cdc_connection(insert_returning_rowid: true)
      expect(conn.insert("INSERT INTO plain (v) VALUES ('a') -- trailing comment")).to eq(1)
      expect(conn.insert("INSERT INTO plain (v) VALUES ('b'); /* tag */")).to eq(2)
      expect(conn.insert("INSERT INTO plain (v) VALUES ('RETURNING') /* returning */")).to eq(3)
      expect(conn.insert(%(INSERT INTO plain (v) VALUES ('x') -- returning\n))).to eq(4)
      expect(conn.insert("/* returning */ INSERT INTO plain (v) VALUES ('c')")).to eq(5)
      expect(conn.select_values("SELECT v FROM plain")).to include("RETURNING")
    end

    it "rewrites WITH ... INSERT" do
      conn = mvcc_cdc_connection(insert_returning_rowid: true)
      id = conn.insert("WITH src(x) AS (SELECT 'w') INSERT INTO plain (v) SELECT x FROM src")
      expect(id).to eq(1)
    end

    it "leaves an existing RETURNING clause alone (and the word inside data is not one)" do
      conn = mvcc_cdc_connection(insert_returning_rowid: true)
      rows = conn.exec_query("INSERT INTO plain (v) VALUES ('returning') RETURNING v").rows
      expect(rows).to eq([["returning"]])
    end

    it "casts string booleans from database.yml / DATABASE_URL" do
      expect(mvcc_cdc_connection(insert_returning_rowid: "false").send(:insert_returning_rowid?)).to be(false)
      ActiveRecord::Base.remove_connection
      expect(connect(database: @path, insert_returning_rowid: "true").send(:insert_returning_rowid?)).to be(true)
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
    let(:config) do
      double("db_config", name: "primary",
        configuration_hash: { adapter: "beagle_turso", database: "/x/r.db", remote_url: "libsql://x", auth_token: "t" })
    end
    let(:pending) { true }
    let(:exists) { true }

    def seen = events.map(&:to_s)

    before(:each) do
      push_mod.install!
      @old_app = Rake.application
      Rake.application = app
      ev = events
      %w[db:migrate db:prepare db:rollback db:migrate:primary db:rollback:primary db:migrate:up:primary
         db:migrate:other db:schema:load:primary db:seed].each do |n|
        Rake::Task.define_task(n) { ev << n }
      end
      Rake::Task.define_task("db:migrate:redo") do
        ev << "redo"
        Rake::Task["db:migrate"].invoke
      end
      allow(push_mod).to receive(:primary_config).and_return(config)
      allow(push_mod).to receive(:local_database_exists?).and_return(exists)
      allow(push_mod).to receive(:migration_pending?).and_return(pending)
      allow(push_mod).to receive(:connection).and_return(conn)
      allow(::Beagle::Turso::SyncManager).to receive(:push!) { ev << "push" }
      @env = ENV.delete(push_mod::SKIP_ENV)
    end

    after(:each) do
      Rake.application = @old_app
      ENV[push_mod::SKIP_ENV] = @env if @env
    end

    it "pushes before and after db:migrate and db:prepare when a migration is pending" do
      Rake::Task["db:migrate"].invoke
      Rake::Task["db:prepare"].invoke
      expect(seen).to eq(%w[push db:migrate push push db:prepare push])
    end

    it "pushes once around a nested task (redo -> migrate)" do
      Rake::Task["db:migrate:redo"].invoke
      expect(seen).to eq(%w[push redo db:migrate push])
    end

    it "guards the multi-database tasks namespaced with the PRIMARY config name only" do
      %w[db:migrate:primary db:rollback:primary db:migrate:up:primary db:schema:load:primary].each do |t|
        events.clear
        Rake::Task[t].invoke
        expect(seen).to eq(["push", t, "push"]), t
      end
      events.clear
      Rake::Task["db:migrate:other"].invoke
      expect(seen).to eq(["db:migrate:other"])
    end

    it "derives the suffix from the config, not a hard-coded 'primary'" do
      allow(config).to receive(:name).and_return("other")
      Rake::Task["db:migrate:other"].invoke
      expect(seen).to eq(%w[push db:migrate:other push])
      events.clear
      Rake::Task["db:migrate:primary"].invoke
      expect(seen).to eq(["db:migrate:primary"])
    end

    it "does not touch unrelated tasks" do
      Rake::Task["db:seed"].invoke
      expect(seen).to eq(["db:seed"])
    end

    context "with nothing pending" do
      let(:pending) { false }

      it "does no push at all for db:prepare and db:migrate, even if Turso is down" do
        allow(::Beagle::Turso::SyncManager).to receive(:push!).and_raise("Turso is down")
        Rake::Task["db:prepare"].invoke
        Rake::Task["db:migrate"].invoke
        expect(seen).to eq(%w[db:prepare db:migrate])
      end

      it "still pushes around explicit rollbacks" do
        Rake::Task["db:rollback"].invoke
        expect(seen).to eq(%w[push db:rollback push])
      end
    end

    context "when the replica does not exist yet (fresh database)" do
      let(:exists) { false }

      it "skips the pre-push (nothing local) and pushes after" do
        Rake::Task["db:prepare"].invoke
        expect(seen).to eq(%w[db:prepare push])
      end
    end

    it "aborts before migrating, with a redacted message and no cause, when the pre-push fails" do
      allow(::Beagle::Turso::SyncManager).to receive(:push!).and_raise(RuntimeError, "boom libsql://user@secret.example/db?authToken=abc")
      expect { Rake::Task["db:migrate"].invoke }.to raise_error(bt::MigrationPushError) { |e|
        expect(e.message).to match(/could not push pending writes to Turso before migrating \(RuntimeError: .*BEAGLE_TURSO_SKIP_MIGRATION_PUSH=1 to migrate anyway/m)
        expect(e.message).not_to include("authToken=abc")
        expect(e.cause).to be_nil
      }
      expect(events).to eq([])
    end

    it "words an OpenError as failing to open the synced replica" do
      open_error = Class.new(StandardError) { def self.name = "Beagle::Turso::OpenError" }
      allow(::Beagle::Turso::SyncManager).to receive(:push!).and_raise(open_error, "nope")
      expect { Rake::Task["db:migrate"].invoke }.to raise_error(bt::MigrationPushError, /could not open the synced replica: nope/)
    end

    it "retries the post-push once: a spurious first failure only warns" do
      calls = 0
      allow(::Beagle::Turso::SyncManager).to receive(:push!) do
        calls += 1
        events << "push"
        raise "near RP, None" if calls == 2
      end
      expect { Rake::Task["db:migrate"].invoke }.to output(/failed once \(RuntimeError: near RP, None\).*succeeded on retry/m).to_stderr
      expect(seen).to eq(%w[push db:migrate push push])
    end

    it "fails with an accurate message when the retry also fails" do
      calls = 0
      allow(::Beagle::Turso::SyncManager).to receive(:push!) do
        calls += 1
        events << "push"
        raise "net down" if calls > 1
      end
      expect { Rake::Task["db:migrate"].invoke }.to raise_error(bt::MigrationPushError) { |e|
        expect(e.message).to match(/applied to the local replica.*failed twice.*net down.*net down.*check sync/m)
        expect(e.cause).to be_nil
      }
    end

    it "continues with a loud warning, and no push, when BEAGLE_TURSO_SKIP_MIGRATION_PUSH=1" do
      ENV[push_mod::SKIP_ENV] = "1"
      expect { Rake::Task["db:migrate"].invoke }.to output(/WARNING.*SKIP_MIGRATION_PUSH=1.*may be lost/m).to_stderr
      expect(seen).to eq(["db:migrate"])
    end

    it "is a no-op for local-only connections" do
      allow(config).to receive(:configuration_hash).and_return(adapter: "beagle_turso", database: "x.db")
      Rake::Task["db:migrate"].invoke
      expect(seen).to eq(["db:migrate"])
    end

    it "treats only beagle_turso configs with remote_url and auth_token as synced" do
      expect(push_mod.synced_config?(adapter: "beagle_turso", remote_url: "libsql://x", auth_token: "t")).to be(true)
      expect(push_mod.synced_config?(adapter: "beagle_turso", database: "x.db")).to be(false)
      expect(push_mod.synced_config?(adapter: "sqlite3", remote_url: "libsql://x", auth_token: "t")).to be(false)
    end

    it "answers the pending check from the real migration context" do
      allow(push_mod).to receive(:migration_pending?).and_call_original
      allow(push_mod).to receive(:connection).and_call_original
      ActiveRecord::Base.establish_connection(adapter: "beagle_turso", database: ":memory:")
      expect(push_mod.send(:migration_pending?)).to be(false)
    end
  end
end
