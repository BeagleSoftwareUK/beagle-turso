RSpec.describe "Sequel::BeagleTurso schema handling" do
  let(:db) { Sequel.connect(adapter: :beagle_turso, database: tmp_db) }
  after { db.close_replica }

  it "reports implicit-primary-key foreign keys with no key columns" do
    db.create_table(:p) { primary_key :id }
    db.create_table(:c) { primary_key :id; foreign_key :p_id, :p }
    fk = db.foreign_key_list(:c).first
    expect(fk[:columns]).to eq([:p_id])
    expect(fk[:table]).to eq(:p)
    expect(fk[:key]).to be_nil
  end

  it "alters a table with an implicit-PK foreign key and keeps the constraint working" do
    db.create_table(:p) { primary_key :id }
    db.create_table(:c) { primary_key :id; foreign_key :p_id, :p; String :note }
    db.alter_table(:c) { set_column_allow_null :note, false; set_column_default :note, "x" }
    db[:p].insert
    db[:c].insert(p_id: 1)
    expect { db[:c].insert(p_id: 99) }.to raise_error(Sequel::ForeignKeyConstraintViolation)
  end

  it "hides the engine's internal bookkeeping tables" do
    db.create_table(:a) { primary_key :id } # AUTOINCREMENT creates __turso_internal_* tables
    expect(db.tables).to eq([:a])
    expect(db.tables.any? { |t| t.to_s.start_with?("__turso_internal_") }).to be(false)
  end

  it "parses schema and indexes" do
    db.create_table(:s) { primary_key :id; String :name, null: false; index :name, unique: true }
    sch = db.schema(:s).to_h
    expect(sch[:id][:primary_key]).to be(true)
    expect(sch[:name][:allow_null]).to be(false)
    expect(sch[:name][:type]).to eq(:string)
    expect(db.indexes(:s).values.first).to include(columns: [:name], unique: true)
  end

  it "does not offer WITHOUT ROWID (unsupported by the engine)" do
    expect(db.send(:support_without_rowid?)).to be(false)
  end

  # Sequel integration: "Database schema modifiers ... foreign key table
  # constraints" leaves a self-referencing row; every later drop of the table
  # failed. The engine checks self-references row by row when dropping.
  it "drops a self-referencing table that has rows" do
    db.create_table(:t) { primary_key :id; foreign_key :parent_id, :t }
    db[:t].insert(id: 1, parent_id: 1)
    db[:t].insert(id: 2, parent_id: 1)
    db.drop_table(:t)
    expect(db.table_exists?(:t)).to be(false)
    expect(db.fetch("PRAGMA foreign_keys").single_value).to eq(1)
  end

  it "still refuses to drop a table whose rows another table references" do
    db.create_table(:t) { primary_key :id; foreign_key :parent_id, :t }
    db.create_table(:c) { primary_key :id; foreign_key :t_id, :t }
    db[:t].insert(id: 1, parent_id: 1)
    db[:c].insert(t_id: 1)
    expect { db.drop_table(:t) }.to raise_error(Sequel::ForeignKeyConstraintViolation)
    expect(db.table_exists?(:t)).to be(true)
  end

  # Sequel integration: "Database schema parser ... should parse defaults from
  # the schema properly" and "Database schema modifiers ... should handle
  # combination of default, unique, and not null". Sequel writes DEFAULT (0);
  # SQLite reports "0", the engine "(0)".
  it "parses parenthesised column defaults like SQLite does" do
    db.create_table(:d) do
      Integer :n, default: 0
      String :s, default: "blah"
      Integer :plain
    end
    sch = db.schema(:d).to_h
    expect(sch[:n].values_at(:default, :ruby_default)).to eq(["0", 0])
    expect(sch[:s].values_at(:default, :ruby_default)).to eq(["'blah'", "blah"])
    expect(sch[:plain][:default]).to be_nil
    db.run("CREATE TABLE r (x integer DEFAULT ((1)))")
    expect(db.schema(:r).first.last[:default]).to eq("(1)") # SQLite strips one pair only
  end

  # Sequel integration: "Database foreign key parsing ... should parse foreign
  # key information into an array of hashes". The engine ignores
  # legacy_alter_table, so Sequel's rename-to-backup rebuild pointed other
  # tables' foreign keys at the dropped backup table.
  it "keeps other tables' foreign keys pointing at a table that alter_table rebuilds" do
    db.create_table(:a) { primary_key :id; Integer :n; index :n }
    db.create_table(:b) { primary_key :id; foreign_key :a_id, :a }
    db.create_view(:v, db[:a])
    db[:a].insert(id: 1, n: 5)
    db[:b].insert(a_id: 1)
    db.alter_table(:a) { set_column_not_null :n }
    expect(db.foreign_key_list(:b).map { |fk| fk[:table] }).to eq([:a])
    expect(db.tables.sort).to eq([:a, :b])
    expect(db.indexes(:a).values.map { |i| i[:columns] }).to eq([[:n]])
    expect(db[:v].all).to eq([{ id: 1, n: 5 }])
    expect(db.schema(:a, reload: true).to_h[:n][:allow_null]).to be(false)
    db[:b].insert(a_id: 1)
    expect { db[:b].insert(a_id: 99) }.to raise_error(Sequel::ForeignKeyConstraintViolation)
  end
end
