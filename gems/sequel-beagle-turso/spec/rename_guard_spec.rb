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

  it "refuses rename_column when synced, and renames nothing" do
    pretend_synced(db)
    expect { db.alter_table(:t) { rename_column :name, :label } }.to raise_error(Sequel::Error, /synced replica/)
    expect(db[:t].columns).to eq(%i[id name])
  end

  it "refuses alter_table operations that rebuild the table through a rename" do
    pretend_synced(db)
    expect { db.alter_table(:t) { set_column_allow_null :name, false } }.to raise_error(Sequel::Error, /synced replica/)
    expect(db.tables).to eq([:t])
  end

  it "still allows add_column and drop_column when synced" do
    pretend_synced(db)
    db.alter_table(:t) { add_column :extra, String }
    db.alter_table(:t) { drop_column :extra }
    expect(db[:t].columns).to eq(%i[id name])
  end

  describe "against a real remote" do
    let(:url) { ENV["TURSO_DATABASE_URL"] }
    let(:token) { ENV["TURSO_AUTH_TOKEN"] }
    before { skip "no TURSO creds" if url.to_s.empty? || token.to_s.empty? }

    it "raises on a real synced replica and renames nothing" do
      synced = Sequel.connect("beagle-turso://#{tmp_db}", remote_url: url, auth_token: token)
      begin
        synced.create_table(:sbt_rename_probe) { primary_key :id; String :name }
        expect(synced.turso_database.synced?).to be(true)
        expect { synced.rename_table(:sbt_rename_probe, :sbt_rename_probe2) }.to raise_error(Sequel::Error, /synced replica/)
        expect { synced.alter_table(:sbt_rename_probe) { rename_column :name, :label } }.to raise_error(Sequel::Error, /synced replica/)
        expect(synced.tables.map(&:to_s)).to include("sbt_rename_probe")
        expect(synced.tables.map(&:to_s)).not_to include("sbt_rename_probe2")
        expect(synced[:sbt_rename_probe].columns).to eq(%i[id name])
      ensure
        begin
          synced.drop_table?(:sbt_rename_probe)
          synced.turso_database.push
        ensure
          synced.close_replica
        end
      end
    end
  end
end
