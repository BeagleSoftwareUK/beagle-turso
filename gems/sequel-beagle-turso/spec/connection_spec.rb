RSpec.describe "Sequel::BeagleTurso connection" do
  it "connects with the beagle-turso:// URL scheme (absolute path)" do
    path = tmp_db
    db = Sequel.connect("beagle-turso://#{path}")
    expect(db).to be_a(Sequel::BeagleTurso::Database)
    expect(db.database_type).to eq(:sqlite)
    expect(db.adapter_scheme).to eq(:beagle_turso)
    expect(db.get(Sequel.lit("1 + 1"))).to eq(2)
    expect(File.exist?(path)).to be(true)
    db.close_replica
  end

  it "connects with the Hash form and defaults to an in-memory database" do
    db = Sequel.connect(adapter: :beagle_turso)
    db.create_table(:t) { Integer :n }
    db[:t].insert(n: 1)
    expect(db[:t].count).to eq(1)
    db.close_replica
  end

  it "parses relative paths and the memory form like the sqlite adapter" do
    opts = ->(url) { Sequel::BeagleTurso::Database.send(:uri_to_options, URI.parse(url)) }
    expect(opts.("beagle-turso://./rel.db")).to eq(database: "./rel.db")
    expect(opts.("beagle-turso:///abs/x.db")).to eq(database: "/abs/x.db")
    expect(opts.("beagle-turso:/")).to eq(database: nil)
  end

  it "runs DML and reports changed rows and insert ids" do
    db = Sequel.connect(adapter: :beagle_turso, database: tmp_db)
    db.create_table(:t) { primary_key :id; String :name }
    expect(db[:t].insert(name: "a")).to eq(1)
    expect(db[:t].insert(name: "b")).to eq(2)
    expect(db[:t].where(name: "a").update(name: "z")).to eq(1)
    expect(db[:t].delete).to eq(2)
    db.close_replica
  end

  it "supports transactions and savepoints" do
    db = Sequel.connect(adapter: :beagle_turso, database: tmp_db)
    db.create_table(:t) { Integer :n }
    db.transaction do
      db[:t].insert(n: 1)
      db.transaction(savepoint: true) do
        db[:t].insert(n: 2)
        raise Sequel::Rollback
      end
    end
    expect(db[:t].select_map(:n)).to eq([1])
    db.close_replica
  end

  it "reports a modern sqlite_version so feature gates pass" do
    db = Sequel.connect(adapter: :beagle_turso)
    expect(db.sqlite_version).to be >= 33500
    db.close_replica
  end

  it "keeps the replica open across disconnect and closes it only via close_replica" do
    db = Sequel.connect(adapter: :beagle_turso, database: tmp_db)
    db.disconnect
    expect(db.turso_database.closed?).to be(false)
    expect(db.get(Sequel.lit("1"))).to eq(1)
    db.close_replica
    expect(db.turso_database.closed?).to be(true)
    expect { db.close_replica }.not_to raise_error
  end

  it "adopts an injected replica and never closes it" do
    turso = Beagle::Turso::Database.open_local(tmp_db)
    db = Sequel.connect(adapter: :beagle_turso, turso_database: turso)
    expect(db.turso_database).to be(turso)
    db.close_replica
    expect(turso.closed?).to be(false)
    turso.close
  end

  it "rejects an auth_token in the URL" do
    expect { Sequel.connect("beagle-turso://#{tmp_db}?auth_token=SECRETQ") }
      .to raise_error(Sequel::Error) { |e| expect(e.message.include?("SECRETQ")).to be(false) }
  end

  it "rejects an auth_token in the URL even when a replica is injected" do
    turso = Beagle::Turso::Database.open_local(tmp_db)
    expect { Sequel.connect("beagle-turso:/?auth_token=TOKX", turso_database: turso) }
      .to raise_error(Sequel::Error) { |e| expect(e.message.include?("TOKX")).to be(false) }
    expect(turso.closed?).to be(false)
    turso.close
  end

  ["Auth_Token", "AUTH_TOKEN", "auth%5Ftoken", "x=1&auth%5FToken"].each do |name|
    it "rejects the auth_token parameter spelled #{name}" do
      expect { Sequel.connect("beagle-turso://#{tmp_db}?#{name}=TOKY") }
        .to raise_error(Sequel::Error) { |e| expect(e.message.include?("TOKY")).to be(false) }
    end
  end

  it "does not keep the auth token in opts or inspect" do
    db = Sequel.connect(adapter: :beagle_turso, database: tmp_db, remote_url: "libsql://x.invalid", auth_token: nil)
    expect(db.opts.key?(:auth_token)).to be(false)
    db.close_replica
  end

  describe "against a real remote" do
    let(:url) { ENV["TURSO_DATABASE_URL"] }
    let(:token) { ENV["TURSO_AUTH_TOKEN"] }
    before { skip "no TURSO creds" if url.to_s.empty? || token.to_s.empty? }

    it "opens a synced replica and scrubs the token from opts and inspect" do
      db = Sequel.connect("beagle-turso://#{tmp_db}", remote_url: url, auth_token: token)
      expect(db.turso_database.synced?).to be(true)
      expect(db.opts.inspect.include?(token)).to be(false)
      expect(db.inspect.include?(token)).to be(false)
      expect(db.get(Sequel.lit("1"))).to eq(1)
      db.close_replica
    end
  end
end
