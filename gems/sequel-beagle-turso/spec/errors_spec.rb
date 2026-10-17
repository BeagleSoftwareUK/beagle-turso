RSpec.describe "Sequel::BeagleTurso error classification" do
  let(:db) { Sequel.connect(adapter: :beagle_turso, database: tmp_db) }
  after { db.close_replica }

  before do
    db.create_table(:p) { primary_key :id; String :name, unique: true, null: false }
    db.create_table(:c) do
      primary_key :id
      foreign_key :p_id, :p
      Integer :n
      constraint(:n_positive) { n > 0 }
    end
  end

  it "maps UNIQUE, NOT NULL, FOREIGN KEY and CHECK violations to Sequel's classes" do
    db[:p].insert(name: "a")
    expect { db[:p].insert(name: "a") }.to raise_error(Sequel::UniqueConstraintViolation)
    expect { db[:p].insert(name: nil) }.to raise_error(Sequel::NotNullConstraintViolation)
    expect { db[:c].insert(p_id: 999, n: 1) }.to raise_error(Sequel::ForeignKeyConstraintViolation)
    expect { db[:c].insert(p_id: 1, n: -1) }.to raise_error(Sequel::CheckConstraintViolation)
  end

  it "maps a busy writer to DatabaseLockTimeout once retries are exhausted" do
    holder = db.turso_database.connect
    holder.execute_batch("BEGIN IMMEDIATE")
    fast = Sequel.connect(adapter: :beagle_turso, turso_database: db.turso_database, timeout: 50)
    expect { fast[:p].insert(name: "x") }.to raise_error(Sequel::DatabaseLockTimeout)
    holder.execute_batch("ROLLBACK")
    holder.close
    fast.disconnect
  end

  it "treats a closed connection as a disconnect" do
    db.synchronize { |conn| conn.close }
    expect { db.get(Sequel.lit("1")) }.to raise_error(Sequel::DatabaseDisconnectError)
    expect(db.get(Sequel.lit("1"))).to eq(1) # the pool dropped the dead connection
  end
end
