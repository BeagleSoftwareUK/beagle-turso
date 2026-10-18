require "logger"
require "securerandom"
require "stringio"

# Bug C: the sync engine doesn't capture ALTER TABLE ... RENAME TO / RENAME
# COLUMN, so on a synced replica the remote never sees them.
RSpec.describe "renames on a synced replica" do
  let(:db) { Sequel.connect(adapter: :beagle_turso, database: tmp_db) }
  after { db.close_replica }

  before { db.create_table(:t) { primary_key :id; String :name } }

  def pretend_synced(db)
    allow(db.turso_database).to receive(:synced?).and_return(true)
  end

  it "still renames tables and columns on a local-only replica" do
    db[:t].insert(name: "a")
    db.rename_table(:t, :t2)
    db.alter_table(:t2) { rename_column :name, :label }
    expect(db[:t2].all).to eq([{ id: 1, label: "a" }])
  end

  it "refuses rename_table when synced, and renames nothing" do
    pretend_synced(db)
    expect { db.rename_table(:t, :t2) }.to raise_error(Sequel::Error, /synced replica.*RENAME/m)
    expect(db.tables).to eq([:t])
  end

  def capture_sql(db)
    io = StringIO.new
    db.loggers << Logger.new(io)
    yield
    io.string
  end

  it "rebuilds for rename_column when synced, with no RENAME" do
    db[:t].insert(name: "a")
    pretend_synced(db)
    sql = capture_sql(db) { db.alter_table(:t) { rename_column :name, :label } }
    expect(sql).not_to match(/RENAME/i)
    expect(db[:t].all).to eq([{ id: 1, label: "a" }])
  end

  it "rebuilds for drop_column when synced (no native DROP COLUMN), keeping rows" do
    db.alter_table(:t) { add_column :extra, String }
    db[:t].insert(name: "a", extra: "x")
    pretend_synced(db)
    sql = capture_sql(db) { db.alter_table(:t) { drop_column :extra } }
    expect(sql).not_to match(/RENAME|DROP COLUMN/i)
    expect(db[:t].all).to eq([{ id: 1, name: "a" }])
  end

  it "issues no RENAME for other rebuilds when synced, keeping rows and indexes" do
    db.alter_table(:t) { add_index :name }
    db[:t].insert(name: "a")
    pretend_synced(db)
    sql = capture_sql(db) do
      db.alter_table(:t) { set_column_allow_null :name, false }
      db.alter_table(:t) { set_column_type :name, :text }
    end
    expect(sql).not_to match(/RENAME/i)
    expect(db[:t].all).to eq([{ id: 1, name: "a" }])
    expect(db.indexes(:t).values.map { |i| i[:columns] }).to eq([[:name]])
    expect(db.tables).to eq([:t])
  end

  it "rebuilds without RENAME on a local-only replica too" do
    db[:t].insert(name: "a")
    sql = capture_sql(db) { db.alter_table(:t) { set_column_allow_null :name, false } }
    expect(sql).not_to match(/RENAME/i)
    expect(db[:t].all).to eq([{ id: 1, name: "a" }])
  end

  it "still allows add_column when synced" do
    pretend_synced(db)
    db.alter_table(:t) { add_column :extra, String }
    expect(db[:t].columns).to eq(%i[id name extra])
  end

  describe "against a real remote" do
    let(:url) { ENV["TURSO_DATABASE_URL"] }
    let(:token) { ENV["TURSO_AUTH_TOKEN"] }
    before { skip "no TURSO creds" if url.to_s.empty? || token.to_s.empty? }

    def replica
      Sequel.connect("beagle-turso://#{tmp_db}", remote_url: url, auth_token: token)
    end

    # The first push after a rebuild may raise once (engine bug A); the next converges.
    def push_converged(db)
      2.times do
        db.turso_database.push
        return
      rescue Beagle::Turso::SyncError
        nil
      end
      db.turso_database.push
    end

    it "refuses rename_table on a real synced replica and renames nothing" do
      synced = replica
      t = :"sbt_ren_#{SecureRandom.hex(3)}"
      begin
        synced.create_table(t) { primary_key :id; String :name }
        expect(synced.turso_database.synced?).to be(true)
        expect { synced.rename_table(t, :"#{t}_2") }.to raise_error(Sequel::Error, /synced replica/)
        expect(synced.tables.map(&:to_s)).to include(t.to_s)
        expect(synced.tables.map(&:to_s)).not_to include("#{t}_2")
      ensure
        begin
          synced.drop_table?(t)
          synced.turso_database.push
        ensure
          synced.close_replica
        end
      end
    end

    {
      "set_column_allow_null" => ->(db, t) { db.alter_table(t) { set_column_allow_null :name, false } },
      "set_column_type after an unpushed insert" => lambda { |db, t|
        db[t].insert(name: "unpushed", n: 3)
        db.alter_table(t) { set_column_type :n, String }
      },
      "drop_column after an unpushed insert" => lambda { |db, t|
        db[t].insert(name: "unpushed", n: 3)
        db.alter_table(t) { drop_column :n }
      },
      "rename_column" => ->(db, t) { db.alter_table(t) { rename_column :name, :label } }
    }.each do |label, op|
      it "converges the remote with local after #{label}" do
        t = :"sbt_rb_#{SecureRandom.hex(3)}"
        db = replica
        begin
          db.create_table(t) { primary_key :id; String :name; Integer :n, index: true }
          db[t].insert(name: "a", n: 1)
          db.turso_database.push
          op.(db, t)
          local = db[t].order(:id).all
          push_converged(db)

          fresh = replica
          begin
            fresh.turso_database.pull
            expect(fresh[t].order(:id).all).to eq(local)
            expect(fresh.schema(t, reload: true).map(&:first)).to eq(db.schema(t, reload: true).map(&:first))
            expect(fresh.tables.map(&:to_s).grep(/\A#{t}/)).to eq([t.to_s])
          ensure
            fresh.close_replica
          end
        ensure
          begin
            db.tables.map(&:to_s).grep(/\A#{t}/).each { |x| db.drop_table?(x) }
            push_converged(db)
          ensure
            db.close_replica
          end
        end
      end
    end
  end
end
