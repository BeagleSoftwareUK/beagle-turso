require "beagle/turso"

RSpec.describe "Database identity" do
  def tmp = "/tmp/bt_id_#{Process.pid}_#{rand(1_000_000)}.db"

  it "is not synced when opened local-only" do
    db = Beagle::Turso::Database.open_local(":memory:")
    expect(db.synced?).to be(false)
    expect(db.remote_host).to be_nil
  end

  it "is not synced when remote_url is given without auth_token (the engine opens it local)" do
    db = Beagle::Turso::Database.open(local_path: tmp, remote_url: "libsql://db-acme.turso.io")
    expect(db.synced?).to be(false)
    expect(db.remote_host).to be_nil
  end

  it "exposes nothing that contains the token" do
    db = Beagle::Turso::Database.open(local_path: ":memory:")
    expect(db.inspect).not_to include("authToken")
  end

  describe "against a real remote" do
    let(:url) { ENV["TURSO_DATABASE_URL"] }
    let(:token) { ENV["TURSO_AUTH_TOKEN"] }
    before { skip "no TURSO creds" if url.to_s.empty? || token.to_s.empty? }

    it "is synced and reports only the host" do
      db = Beagle::Turso::Database.open(local_path: tmp, remote_url: url, auth_token: token)
      expect(db.synced?).to be(true)
      expect(db.remote_host).to eq(Beagle::Turso::Redaction.host(url))
      expect(db.remote_host).not_to include("://")
      expect(db.remote_host.include?(token)).to be(false)
      db.close
    end
  end
end
