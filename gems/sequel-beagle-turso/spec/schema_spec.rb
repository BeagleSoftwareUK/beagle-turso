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
end
