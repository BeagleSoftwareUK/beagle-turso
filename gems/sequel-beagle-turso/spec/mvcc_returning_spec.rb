require "logger"
require "stringio"

# Bug B: on a replica in MVCC journal mode with change data capture on (every
# synced replica of a --tursodb remote) the engine's last_insert_rowid is the
# CDC change id, not the inserted rowid (tursodatabase/turso#9551). Both
# pragmas are per connection, so they're set by wrapping Database#connect.
RSpec.describe "inserts on an MVCC replica with CDC" do
  let(:db) do
    d = Sequel.connect(adapter: :beagle_turso, database: tmp_db)
    # journal_mode returns a row, which connection_pragmas (execute_batch)
    # rejects, so wrap connect and run both through query.
    d.singleton_class.send(:define_method, :connect) do |server|
      conn = super(server)
      conn.query("PRAGMA journal_mode = mvcc", [])
      conn.query("PRAGMA unstable_capture_data_changes_conn('full')", [])
      conn
    end
    d.disconnect # the connection made by Sequel.connect predates the hook
    d.create_table(:t) { primary_key :id; String :v; String :u, unique: true }
    d
  end
  after { db.close_replica }

  it "reproduces the engine bug (guards the premise of the specs below)" do
    db[:t].insert(v: "x")
    raw = db.synchronize { |c| c.last_insert_rowid }
    expect(raw).not_to eq(1)
  end

  it "returns the real rowid for several inserts and after an update" do
    expect(db[:t].insert(v: "a")).to eq(1)
    expect(db[:t].insert(v: "b")).to eq(2)
    db[:t].where(id: 1).update(v: "z")
    expect(db[:t].insert(v: "c")).to eq(3)
    db[:t].where(id: 2).delete
    expect(db[:t].insert(v: "d")).to eq(4)
  end

  it "returns the last id of a multi-row insert" do
    expect(db.execute_insert("INSERT INTO t (v) VALUES ('s'), ('u')")).to eq(db[:t].max(:id))
    expect(db.execute_insert("INSERT INTO t (v) SELECT v FROM t WHERE id <= 2;  \n")).to eq(db[:t].max(:id))
  end

  it "returns nil when nothing was inserted" do
    db[:t].insert(v: "a", u: "k")
    expect(db[:t].insert_ignore.insert(v: "b", u: "k")).to be_nil
    expect(db.execute_insert("INSERT INTO t (v, u) VALUES ('c', 'k') ON CONFLICT DO NOTHING")).to be_nil
    expect(db[:t].count).to eq(1)
  end

  it "supports a ROM-style create read-back" do
    ds = db[:t]
    row = ds.where(id: ds.insert(v: "a")).first
    expect(row).to include(v: "a")
    ds.where(id: 1).update(v: "b")
    row = ds.where(id: ds.insert(v: "c")).first
    expect(row).to include(id: 2, v: "c")
  end

  it "leaves an insert that already has RETURNING working, with the real id" do
    expect(db.execute_insert("INSERT INTO t (v) VALUES ('a') RETURNING id")).to eq(1)
    expect(db[:t].returning(:id).insert(v: "b")).to eq([{ id: 2 }])
  end

  it "keeps the original SQL in the log" do
    log = StringIO.new
    db.loggers << Logger.new(log)
    db[:t].insert(v: "a")
    expect(log.string).to include("INSERT INTO `t` (`v`) VALUES ('a')")
    expect(log.string).not_to include("RETURNING")
  end
end

RSpec.describe "execute_insert RETURNING suffix" do
  it "survives a trailing line comment (sql_comments extension)" do
    db = Sequel.connect(adapter: :beagle_turso)
    db.create_table(:t) { primary_key :id; Integer :n }
    ds = db[:t].extension(:sql_comments).comment("a\nb")
    expect(ds.insert(n: 1)).to eq(1)
    expect(ds.insert(n: 2)).to eq(2)
    db.close_replica
  end
end

RSpec.describe "execute_insert on a WAL replica" do
  let(:db) do
    d = Sequel.connect(adapter: :beagle_turso, database: tmp_db)
    d.create_table(:t) { primary_key :id; String :v; String :u, unique: true }
    d
  end
  after { db.close_replica }

  it "returns nil for an ignored insert and the updated row's rowid for an upsert" do
    db[:t].insert(v: "a", u: "k")
    db[:t].insert(v: "b", u: "m")
    expect(db[:t].insert_ignore.insert(v: "x", u: "k")).to be_nil
    expect(db[:t].insert_conflict(target: :u, update: { v: "up" }).insert(v: "x", u: "m")).to eq(2)
    expect(db[:t].where(u: "m").get(:v)).to eq("up")
  end

  it "is not fooled by RETURNING inside literals, identifiers or comments" do
    expect(db[:t].insert(v: "Returning customer")).to eq(1)
    expect(db[:t].insert(v: "the RETURNING word 'it''s'")).to eq(2)
    expect(db[:t].insert(v: "x -- RETURNING")).to eq(3)
    expect(db.execute_insert('INSERT INTO t (v) VALUES (\'a\') /* RETURNING */')).to eq(4)
    expect(db.execute_insert("INSERT INTO t (v) VALUES ('b'); -- RETURNING\n")).to eq(5)
    expect(db.execute_insert("INSERT INTO t (v) VALUES ('c') ;  ")).to eq(6)
    db.create_table(:returning) { primary_key :id; String :"RETURNING" }
    expect(db[:returning].insert("RETURNING": "z")).to eq(1)
    expect(db[:t].count).to eq(6)
  end
end
